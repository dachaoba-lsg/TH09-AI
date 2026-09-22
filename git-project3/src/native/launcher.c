/* TH09-AI x86 launcher: all patches are checked and applied to this newly
 * created suspended process only. The game and upstream DLL files stay intact.
 * Build with TinyCC win32: tcc launcher.c -o th09ai-launcher.exe -lshell32
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#include "input_patches.h"
#include "ai_side_config.h"
#include "ai_input_patches.h"
__declspec(dllimport) wchar_t ** WINAPI CommandLineToArgvW(const wchar_t *, int *);

static int read_equal(HANDLE process, DWORD address, const unsigned char *expected, SIZE_T length) {
    unsigned char actual[64]; SIZE_T count = 0;
    if (length > sizeof(actual)) return 0;
    return ReadProcessMemory(process, (void *)address, actual, length, &count)
        && count == length && memcmp(actual, expected, length) == 0;
}

static int patch_memory(HANDLE process, DWORD address, const unsigned char *data, SIZE_T length) {
    DWORD previous, unused; SIZE_T count = 0; BOOL ok;
    if (!VirtualProtectEx(process, (void *)address, length, PAGE_EXECUTE_READWRITE, &previous)) return 0;
    ok = WriteProcessMemory(process, (void *)address, data, length, &count) && count == length;
    if (!FlushInstructionCache(process, (void *)address, length)) ok = FALSE;
    if (!VirtualProtectEx(process, (void *)address, length, previous, &unused)) ok = FALSE;
    return ok && read_equal(process, address, data, length);
}

static DWORD load_dll(HANDLE process, const wchar_t *path) {
    SIZE_T size = (wcslen(path) + 1) * sizeof(wchar_t), written = 0;
    void *remote = VirtualAllocEx(process, NULL, size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    HANDLE thread = NULL; DWORD module = 0;
    if (!remote) return 0;
    if (!WriteProcessMemory(process, remote, path, size, &written) || written != size) goto cleanup;
    thread = CreateRemoteThread(process, NULL, 0,
        (LPTHREAD_START_ROUTINE)GetProcAddress(GetModuleHandleA("kernel32.dll"), "LoadLibraryW"),
        remote, 0, NULL);
    if (!thread) goto cleanup;
    if (WaitForSingleObject(thread, 15000) != WAIT_OBJECT_0) goto cleanup;
    if (!GetExitCodeThread(thread, &module) || module == STILL_ACTIVE) module = 0;
cleanup:
    if (thread) CloseHandle(thread);
    /* On a timed-out loader the caller terminates this suspended test launch;
       leave the allocation until then so the loader cannot access freed data. */
    if (module) VirtualFreeEx(process, remote, 0, MEM_RELEASE);
    return module;
}

int main(void) {
    wchar_t **argv, *slash;
    wchar_t directory[MAX_PATH], game_dir[MAX_PATH], command[MAX_PATH + 4];
    wchar_t ai_dll[MAX_PATH], window_dll[MAX_PATH], ini[MAX_PATH];
    int argc, i, ai_side, success = 0, verify_only = 0;
    const Th09AiInputPatch *ai_patch;
    DWORD ai_module;
    HANDLE support_events[2] = {NULL, NULL};
    wchar_t event_name[96];
    STARTUPINFOW startup;
    PROCESS_INFORMATION process;
    argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv || (argc != 2 && argc != 3) || wcslen(argv[1]) >= MAX_PATH - 4) {
        fprintf(stderr, "Usage: th09ai-launcher.exe <absolute path to th09.exe>\n");
        return 2;
    }
    if (argc == 3) {
        if (wcscmp(argv[2], L"--verify-suspended") != 0) return 2;
        verify_only = 1;
    }
    if (!GetModuleFileNameW(NULL, directory, MAX_PATH)) return 3;
    slash = wcsrchr(directory, L'\\');
    if (!slash) return 3;
    *slash = 0;
    if (wcslen(directory) > MAX_PATH - 32) return 3;
    wcscpy(ai_dll, directory); wcscat(ai_dll, L"\\inject.dll");
    wcscpy(window_dll, directory); wcscat(window_dll, L"\\window_support.dll");
    wcscpy(ini, directory); wcscat(ini, L"\\ka_ai_duka.ini");
    ai_side = Th09ReadAiSide(ini);
    if (!ai_side) {
        fprintf(stderr, "Invalid AI side configuration: enable exactly one of 1P/2P with its script_path; disable and clear the other.\n");
        LocalFree(argv);
        return 3;
    }
    ai_patch = &th09_ai_input_patches[ai_side - 1];
    wcscpy(game_dir, argv[1]); slash = wcsrchr(game_dir, L'\\');
    if (!slash || _wcsicmp(slash + 1, L"th09.exe") != 0) return 3;
    *slash = 0;
    wcscpy(command, L"\""); wcscat(command, argv[1]); wcscat(command, L"\"");
    memset(&startup, 0, sizeof(startup)); startup.cb = sizeof(startup);
    memset(&process, 0, sizeof(process));
    if (!CreateProcessW(argv[1], command, NULL, NULL, FALSE, CREATE_SUSPENDED, NULL,
        game_dir, &startup, &process)) {
        fprintf(stderr, "CreateProcess failed: %lu\n", GetLastError());
        return 4;
    }
    /* Practice gates must be fully installed before the game executes any
       main-thread code. A worker created by DllMain runs after loader unlock. */
    for (i = 0; i < 2; ++i) {
        wsprintfW(event_name, L"Local\\TH09AI-Support-%lu-%s", process.dwProcessId,
            i == 0 ? L"Ready" : L"Failed");
        support_events[i] = CreateEventW(NULL, TRUE, FALSE, event_name);
        if (!support_events[i] || GetLastError() == ERROR_ALREADY_EXISTS) {
            fprintf(stderr, "Could not create a fresh support initialization event.\n");
            goto cleanup;
        }
    }
    /* Validate every original game instruction before changing anything. */
    for (i = 0; i < TH09_INPUT_PATCH_COUNT; ++i) {
        const Th09InputPatch *p = &th09_input_patches[i];
        if (!read_equal(process.hProcess, p->address, p->before, p->length)) {
            fprintf(stderr, "Unsupported game input bytes at %08lX.\n", p->address);
            goto cleanup;
        }
    }
    ai_module = load_dll(process.hProcess, ai_dll);
    if (!ai_module) { fprintf(stderr, "AI injection failed: %lu\n", GetLastError()); goto cleanup; }
    for (i = 0; i < 2; ++i) {
        const Th09AiInputPatch *p = &th09_ai_input_patches[i];
        if (!read_equal(process.hProcess, ai_module + p->rva, p->before, p->length)) {
            fprintf(stderr, "Unsupported upstream %dP input instruction.\n", i + 1); goto cleanup;
        }
    }
    if (!patch_memory(process.hProcess, ai_module + ai_patch->rva, ai_patch->after, ai_patch->length)) {
        fprintf(stderr, "Could not isolate %dP AI input.\n", ai_side); goto cleanup;
    }
    for (i = 0; i < TH09_INPUT_PATCH_COUNT; ++i) {
        const Th09InputPatch *p = &th09_input_patches[i];
        if (!patch_memory(process.hProcess, p->address, p->after, p->length)) {
            fprintf(stderr, "Input patch failed at %08lX.\n", p->address); goto cleanup;
        }
    }
    if (!load_dll(process.hProcess, window_dll)) {
        fprintf(stderr, "Window module injection failed: %lu\n", GetLastError()); goto cleanup;
    }
    if (WaitForMultipleObjects(2, support_events, FALSE, 10000) != WAIT_OBJECT_0) {
        fprintf(stderr, "Support/laser-sensor/practice initialization failed or timed out; see native-window.log.\n");
        goto cleanup;
    }
    if (verify_only) {
        printf("PASS: AI=%dP suspended-only input, laser-sensor and practice initialization verification; no game window or input.\n", ai_side);
        success = 1;
        goto cleanup;
    }
    if (ResumeThread(process.hThread) == (DWORD)-1) goto cleanup;
    printf("TH09-AI ready. PID=%lu; AI=%dP; physical mappings unchanged; selected AI battle input is exclusive.\n", process.dwProcessId, ai_side);
    success = 1;
cleanup:
    if (!success || verify_only) {
        /* This process was created suspended here and has never been handed
           to the player. Do not let an incompletely patched game run. */
        TerminateProcess(process.hProcess, 10);
    }
    CloseHandle(process.hThread); CloseHandle(process.hProcess);
    for (i = 0; i < 2; ++i) if (support_events[i]) CloseHandle(support_events[i]);
    LocalFree(argv);
    return success ? 0 : 10;
}
