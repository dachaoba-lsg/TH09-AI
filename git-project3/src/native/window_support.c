#define WIN32_LEAN_AND_MEAN
#include "window_resize.h"
#include "practice_patches.h"
#include "laser_sensor.h"
#include "player_sensor.h"
#include "enemy_sensor.h"
#include "ai_side_config.h"
#include "ai_input_patches.h"
#include <stdio.h>
#include <string.h>

static HMODULE g_module;
static wchar_t g_ini[MAX_PATH];
static wchar_t g_log[MAX_PATH];

static void native_log(const char *message)
{
    HANDLE file;
    DWORD written;
    char line[768];
    SYSTEMTIME now;
    GetLocalTime(&now);
    sprintf(line, "%04u-%02u-%02u %02u:%02u:%02u.%03u %s\r\n",
        now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute,
        now.wSecond, now.wMilliseconds, message);
    file = CreateFileW(g_log, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
        NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file != INVALID_HANDLE_VALUE) {
        WriteFile(file, line, (DWORD)strlen(line), &written, NULL);
        CloseHandle(file);
    }
}

static BOOL CALLBACK find_window(HWND window, LPARAM result)
{
    DWORD process;
    char class_name[64];
    GetWindowThreadProcessId(window, &process);
    if (process == GetCurrentProcessId() && IsWindowVisible(window) &&
        GetWindow(window, GW_OWNER) == NULL &&
        (GetWindowLongA(window, GWL_STYLE) & WS_CAPTION) &&
        GetClassNameA(window, class_name, sizeof(class_name)) &&
        strcmp(class_name, "BASE") == 0) {
        *(HWND *)result = window;
        return FALSE;
    }
    return TRUE;
}

/* Detect an INI change or mismatched launcher before permitting execution.
 * The human side must still have the upstream OR instruction. */
static BOOL ai_input_matches_side(int ai_side)
{
    HMODULE module = GetModuleHandleW(L"inject.dll");
    unsigned char actual[7];
    SIZE_T count;
    int i;
    if (!module) return FALSE;
    for (i = 0; i < 2; ++i) {
        const Th09AiInputPatch *p = &th09_ai_input_patches[i];
        const unsigned char *expected = i == ai_side - 1 ? p->after : p->before;
        if (!ReadProcessMemory(GetCurrentProcess(), (unsigned char *)module + p->rva,
            actual, p->length, &count) || count != p->length || memcmp(actual, expected, count))
            return FALSE;
    }
    return TRUE;
}

static DWORD WINAPI window_worker(void *unused)
{
    wchar_t *slash;
    HWND window, candidate = NULL, installed = NULL, failed_window = NULL;
    int width, height, resizable, keep_aspect, stable_samples = 0, missing_samples = 0;
    DWORD last_error = 0;
    Th09ResizeStats stats;
    char text[200];
    wchar_t event_name[96];
    HANDLE ready, failed;
    BOOL practice_ok = FALSE, sensor_ok = FALSE, player_sensor_ok = FALSE, enemy_sensor_ok = FALSE;
    int no_damage, invincible, ai_side;
    (void)unused;
    wsprintfW(event_name, L"Local\\TH09AI-Support-%lu-Ready", GetCurrentProcessId());
    ready = OpenEventW(EVENT_MODIFY_STATE, FALSE, event_name);
    wsprintfW(event_name, L"Local\\TH09AI-Support-%lu-Failed", GetCurrentProcessId());
    failed = OpenEventW(EVENT_MODIFY_STATE, FALSE, event_name);
    if (!GetModuleFileNameW(g_module, g_ini, MAX_PATH)) goto initialized;
    slash = wcsrchr(g_ini, L'\\');
    if (!slash || slash - g_ini > MAX_PATH - 32) goto initialized;
    slash[1] = 0;
    wcscpy(g_log, g_ini);
    wcscat(g_log, L"native-window.log");
    wcscat(g_ini, L"ka_ai_duka.ini");
    ai_side = Th09ReadAiSide(g_ini);
    if (!ai_side || !ai_input_matches_side(ai_side)) {
        native_log("ai-input: invalid side configuration or selected-side patch mismatch");
        goto initialized;
    }
    sprintf(text, "ai-input: verified AI=%dP exclusive; human=%dP unchanged", ai_side, 3 - ai_side);
    native_log(text);
    no_damage = GetPrivateProfileIntW(L"practice", L"player1_no_damage", 0, g_ini);
    invincible = GetPrivateProfileIntW(L"practice", L"player1_invincible", 0, g_ini);
    if (ai_side == 1) {
        no_damage = 0;
        invincible = 0;
        native_log("practice: AI=1P; player-1 practice forced off; no protection transferred to 2P");
    }
    /* Do not install gameplay gates into an already-running host. Our native
       launcher provides the handshake while the main thread is suspended. */
    if ((no_damage || invincible) && (!ready || !failed)) {
        native_log("practice: refused enabled practice without suspended-launch handshake");
        goto initialized;
    }
    /* Sensor correction also requires our suspended-launch handshake: never
       modify a host that manually loaded this helper while already running. */
    if (!ready || !failed) {
        native_log("laser-sensor: refused installation without suspended-launch handshake");
        goto initialized;
    }
    sensor_ok = Th09LaserSensorInstall(native_log);
    if (!sensor_ok) goto initialized;
    player_sensor_ok = Th09PlayerSensorInstall(native_log);
    if (!player_sensor_ok) goto initialized;
    enemy_sensor_ok = Th09EnemySensorInstall(native_log);
    if (!enemy_sensor_ok) goto initialized;
    practice_ok = Th09PracticeInstall(no_damage != 0, invincible != 0, native_log);
initialized:
    if (practice_ok && sensor_ok && player_sensor_ok && enemy_sensor_ok) { if (ready) SetEvent(ready); }
    else { if (failed) SetEvent(failed); }
    if (ready) CloseHandle(ready);
    if (failed) CloseHandle(failed);
    if (!practice_ok || !sensor_ok || !player_sensor_ok || !enemy_sensor_ok) return 1;
    if (!GetPrivateProfileIntW(L"window", L"enabled", 1, g_ini)) {
        native_log("Native window resizing is disabled by configuration.");
        return 0;
    }
    width = GetPrivateProfileIntW(L"window", L"width", 960, g_ini);
    height = GetPrivateProfileIntW(L"window", L"height", 720, g_ini);
    resizable = GetPrivateProfileIntW(L"window", L"resizable", 1, g_ini);
    keep_aspect = GetPrivateProfileIntW(L"window", L"keep_aspect", 1, g_ini);
    if (width < 320 || width > 8192 || height < 240 || height > 8192) {
        native_log("Invalid initial window size; using 960x720.");
        width = 960;
        height = 720;
    }
    native_log("Native window support loaded; monitoring stable game windows every 500 ms.");
    for (;;) {
        window = NULL;
        EnumWindows(find_window, (LPARAM)&window);
        Th09WindowResizeGetStats(&stats);
        if (installed && (!IsWindow(installed) || !stats.installed)) {
            native_log("Previous game window is gone; looking for its replacement.");
            installed = NULL;
            candidate = NULL;
            stable_samples = 0;
        }
        if (window == installed && installed) {
            /* Never restore initial size on an already-installed HWND: keep
             * the dimensions chosen by the user's edge/corner dragging. */
            Sleep(500);
            continue;
        }
        if (!window) {
            candidate = NULL;
            stable_samples = 0;
            if (++missing_samples == 60)
                native_log("No windowed BASE window yet; continuing to watch for creation or fullscreen exit.");
            Sleep(500);
            continue;
        }
        missing_samples = 0;
        if (window != candidate) {
            candidate = window;
            stable_samples = 1;
        } else if (stable_samples < 3) {
            ++stable_samples;
        }
        /* TH09 may destroy its first HWND during D3D setup. Require three
         * consecutive observations, and keep monitoring after attachment. */
        if (stable_samples >= 3) {
            if (Th09WindowResizeInstall(window, width, height, resizable != 0,
                keep_aspect != 0, native_log)) {
                installed = window;
                failed_window = NULL;
                last_error = 0;
            } else {
                DWORD error = GetLastError();
                if (failed_window != window || last_error != error) {
                    sprintf(text, "Native resize install deferred: hwnd=%p Win32 error %lu; will rediscover and retry.",
                        (void *)window, error);
                    native_log(text);
                    failed_window = window;
                    last_error = error;
                }
                candidate = NULL;
                stable_samples = 0;
            }
        }
        Sleep(500);
    }
}

/* Cdecl export is undecorated in the bundled TCC toolchain. */
__declspec(dllexport) void GetWindowResizeStats(Th09ResizeStats *stats)
{
    Th09WindowResizeGetStats(stats);
}

__declspec(dllexport) void GetPracticeStats(Th09PracticeStats *stats)
{
    Th09PracticeGetStats(stats);
}

BOOL WINAPI DllMain(HINSTANCE module, DWORD reason, LPVOID reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        HANDLE thread;
        g_module = module;
        DisableThreadLibraryCalls(module);
        thread = CreateThread(NULL, 0, window_worker, NULL, 0, NULL);
        if (!thread) return FALSE;
        CloseHandle(thread);
    }
    return TRUE;
}
