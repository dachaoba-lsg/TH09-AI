/* This executable owns every window it sends messages to. It does not locate,
 * inject, focus, or otherwise interact with a running game. */
#define WIN32_LEAN_AND_MEAN
#include "window_resize.h"
#include <stdio.h>
#include <stdlib.h>

#ifdef TH09_WINDOW_TEST_DLL
static BOOL (*install_from_dll)(HWND, int, int, BOOL, BOOL, Th09ResizeLogFn);
static void (*stats_from_dll)(Th09ResizeStats *);
#define Th09WindowResizeInstall install_from_dll
#define Th09WindowResizeGetStats stats_from_dll
#endif

static HWND test_window;
static HANDLE installed_event;
static BOOL install_ok;
static int failures;
static BOOL destroy_during_resize;

static void check(BOOL condition, const char *description)
{
    printf("%s: %s\n", condition ? "PASS" : "FAIL", description);
    if (!condition) ++failures;
}

static LRESULT CALLBACK restrictive_proc(HWND window, UINT msg, WPARAM wp, LPARAM lp)
{
    if (msg == WM_WINDOWPOSCHANGING && destroy_during_resize) {
        destroy_during_resize = FALSE;
        DestroyWindow(window);
        return 0;
    }
    if (msg == WM_SETCURSOR) return 1;
    if (msg == WM_NCHITTEST) return HTCLIENT;
    if (msg == WM_SIZING) return 0;
    if (msg == WM_KEYDOWN) return 0x1234;
    if (msg == WM_GETMINMAXINFO) {
        MINMAXINFO *info = (MINMAXINFO *)lp;
        info->ptMinTrackSize.x = info->ptMaxTrackSize.x = 640;
        info->ptMinTrackSize.y = info->ptMaxTrackSize.y = 480;
        return 0;
    }
    return DefWindowProcA(window, msg, wp, lp);
}

static DWORD WINAPI install_worker(void *unused)
{
    (void)unused;
    install_ok = Th09WindowResizeInstall(test_window, 800, 600, TRUE, TRUE, NULL);
    if (!install_ok) printf("Install error: %lu\n", GetLastError());
    SetEvent(installed_event);
    return 0;
}

int main(int argc, char **argv)
{
    WNDCLASSA wc = { 0 };
    DWORD gui_thread = GetCurrentThreadId();
    DWORD wait_result;
    MSG msg;
    HANDLE worker;
    RECT outer, client, frame = { 0, 0, 0, 0 }, sizing;
    MINMAXINFO info = { 0 };
    Th09ResizeStats stats;
    int fw, fh, k, x, y, expected[8] = {
        HTTOPLEFT, HTTOP, HTTOPRIGHT, HTRIGHT,
        HTBOTTOMRIGHT, HTBOTTOM, HTBOTTOMLEFT, HTLEFT
    };
#ifdef TH09_WINDOW_TEST_DLL
    HMODULE test_module = LoadLibraryA(argc > 1 ? argv[1] : "window_resize_test.dll");
    check(test_module != NULL, "loaded the native subclass from a real DLL module");
    if (!test_module) return 1;
    install_from_dll = (void *)GetProcAddress(test_module, "Th09WindowResizeInstall");
    stats_from_dll = (void *)GetProcAddress(test_module, "Th09WindowResizeGetStats");
    check(install_from_dll && stats_from_dll, "resolved native test DLL entry points");
    if (!install_from_dll || !stats_from_dll) return 1;
#else
    (void)argc;
    (void)argv;
#endif
    wc.lpfnWndProc = restrictive_proc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "Th09AiOwnedResizeTest";
    RegisterClassA(&wc);
    test_window = CreateWindowExA(0, wc.lpszClassName, "Hidden TH09-AI resize test",
        WS_CAPTION | WS_SYSMENU, 100, 100, 640, 480, NULL, NULL, wc.hInstance, NULL);
    check(test_window != NULL, "created only an owned hidden test window");
    installed_event = CreateEventA(NULL, TRUE, FALSE, NULL);
    worker = CreateThread(NULL, 0, install_worker, NULL, 0, NULL);
    for (;;) {
        wait_result = MsgWaitForMultipleObjects(1, &installed_event, FALSE, 7000, QS_ALLINPUT);
        if (wait_result == WAIT_OBJECT_0) break;
        if (wait_result != WAIT_OBJECT_0 + 1) {
            check(FALSE, "worker install completed within seven seconds");
            return 1;
        }
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageA(&msg);
        }
    }
    check(install_ok, "worker-thread request installed the native subclass");
    Th09WindowResizeGetStats(&stats);
    check(stats.installed && stats.install_thread != (LONG)gui_thread,
        "same-process worker publishes the subclass without a message-hook handshake");
    check((GetWindowLongA(test_window, GWL_STYLE) & WS_THICKFRAME) != 0,
        "native sizing frame is enabled");
    GetClientRect(test_window, &client);
    check(client.right == 800 && client.bottom == 600, "initial client size is exactly 800 x 600");
    GetWindowRect(test_window, &outer);
    for (k = 0; k < 8; ++k) {
        x = (outer.left + outer.right) / 2;
        y = (outer.top + outer.bottom) / 2;
        if (k == 0 || k == 6 || k == 7) x = outer.left + 2;
        if (k == 2 || k == 3 || k == 4) x = outer.right - 2;
        if (k == 0 || k == 1 || k == 2) y = outer.top + 2;
        if (k == 4 || k == 5 || k == 6) y = outer.bottom - 2;
        check(SendMessageA(test_window, WM_NCHITTEST, 0, MAKELPARAM(x, y)) == expected[k],
            "native hit test exposes the expected resize edge/corner");
    }
    SendMessageA(test_window, WM_GETMINMAXINFO, 0, (LPARAM)&info);
    AdjustWindowRectEx(&frame, (DWORD)GetWindowLongA(test_window, GWL_STYLE), FALSE, 0);
    fw = frame.right - frame.left;
    fh = frame.bottom - frame.top;
    check(info.ptMinTrackSize.x == 320 + fw && info.ptMinTrackSize.y == 240 + fh &&
        info.ptMaxTrackSize.x > 640, "fixed-size original min/max constraints are bypassed");
    for (k = WMSZ_LEFT; k <= WMSZ_BOTTOMRIGHT; ++k) {
        sizing.left = 100; sizing.top = 100;
        sizing.right = 1100 + fw; sizing.bottom = 620 + fh;
        check(SendMessageA(test_window, WM_SIZING, k, (LPARAM)&sizing) == TRUE,
            "all eight sizing directions are handled");
        check(abs((sizing.right - sizing.left - fw) * 3 - (sizing.bottom - sizing.top - fh) * 4) <= 2,
            "client area keeps 4:3 while resizing");
    }
    check(SendMessageA(test_window, WM_KEYDOWN, 'Z', 0) == 0x1234,
        "game keyboard messages still reach the original window procedure");
    Th09WindowResizeGetStats(&stats);
    check(stats.edge_hits >= 8 && stats.sizing_events == 8,
        "diagnostics distinguish real edge hits and sizing events");
    DestroyWindow(test_window);
    Th09WindowResizeGetStats(&stats);
    check(!stats.installed, "window destruction clears diagnostic installed status");
    test_window = CreateWindowExA(0, wc.lpszClassName, "Hidden free-size test",
        WS_CAPTION | WS_SYSMENU, 100, 100, 640, 480, NULL, NULL, wc.hInstance, NULL);
    check(Th09WindowResizeInstall(test_window, 800, 600, TRUE, FALSE, NULL),
        "a new owned window supports optional unlocked aspect ratio");
    sizing.left = 100; sizing.top = 100; sizing.right = 900; sizing.bottom = 620;
    SendMessageA(test_window, WM_SIZING, WMSZ_BOTTOMRIGHT, (LPARAM)&sizing);
    check(sizing.right == 900 && sizing.bottom == 620,
        "unlocked sizing keeps the user's independent width and height");
    DestroyWindow(test_window);
    test_window = CreateWindowExA(0, wc.lpszClassName, "Hidden fixed-size test",
        WS_CAPTION | WS_SYSMENU, 100, 100, 640, 480, NULL, NULL, wc.hInstance, NULL);
    check(Th09WindowResizeInstall(test_window, 800, 600, FALSE, FALSE, NULL) &&
        !(GetWindowLongA(test_window, GWL_STYLE) & WS_THICKFRAME),
        "resizable=false keeps a fixed frame when explicitly configured");
    DestroyWindow(test_window);
    test_window = CreateWindowExA(0, wc.lpszClassName, "Hidden startup replacement test",
        WS_CAPTION | WS_SYSMENU, 100, 100, 640, 480, NULL, NULL, wc.hInstance, NULL);
    destroy_during_resize = TRUE;
    check(!Th09WindowResizeInstall(test_window, 800, 600, TRUE, TRUE, NULL) &&
        !IsWindow(test_window), "window destruction during installation fails safely");
    test_window = CreateWindowExA(0, wc.lpszClassName, "Hidden replacement HWND",
        WS_CAPTION | WS_SYSMENU, 100, 100, 640, 480, NULL, NULL, wc.hInstance, NULL);
    check(Th09WindowResizeInstall(test_window, 800, 600, TRUE, TRUE, NULL),
        "a replacement HWND installs after a destroyed-window failure");
    SetWindowPos(test_window, NULL, 0, 0, 720 + fw, 540 + fh, SWP_NOMOVE | SWP_NOZORDER);
    check(Th09WindowResizeInstall(test_window, 800, 600, TRUE, TRUE, NULL),
        "rechecking the installed HWND is idempotent");
    GetClientRect(test_window, &client);
    check(client.right == 720 && client.bottom == 540,
        "rechecking an installed HWND preserves the user's changed dimensions");
    DestroyWindow(test_window);
    WaitForSingleObject(worker, 1000);
    CloseHandle(worker);
    CloseHandle(installed_event);
    printf("Result: %d failures. No running game was accessed.\n", failures);
    return failures ? 1 : 0;
}
