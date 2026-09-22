#define WIN32_LEAN_AND_MEAN
#include "window_resize.h"
#include <stdio.h>
#include <string.h>

static HWND g_window;
static WNDPROC g_original;
static BOOL g_resizable;
static BOOL g_keep_aspect;
static Th09ResizeLogFn g_logger;
static Th09ResizeStats g_stats = { sizeof(Th09ResizeStats) };

static void log_text(const char *message)
{
    if (g_logger) g_logger(message);
}

static BOOL is_resize_hit(LRESULT hit)
{
    return hit >= HTLEFT && hit <= HTBOTTOMRIGHT;
}

static void frame_extent(HWND window, int *width, int *height)
{
    RECT rect = { 0, 0, 0, 0 };
    AdjustWindowRectEx(&rect, (DWORD)GetWindowLongA(window, GWL_STYLE),
        GetMenu(window) != NULL, (DWORD)GetWindowLongA(window, GWL_EXSTYLE));
    *width = rect.right - rect.left;
    *height = rect.bottom - rect.top;
}

static void update_dimensions(HWND window)
{
    RECT rect;
    if (GetClientRect(window, &rect)) {
        g_stats.client_width = rect.right - rect.left;
        g_stats.client_height = rect.bottom - rect.top;
    }
}

static void constrain_sizing(HWND window, WPARAM edge, RECT *rect)
{
    int fw, fh, width, height;
    frame_extent(window, &fw, &fh);
    width = rect->right - rect->left - fw;
    height = rect->bottom - rect->top - fh;
    if (width < 320) width = 320;
    if (height < 240) height = 240;
    if (g_keep_aspect) {
        if (edge == WMSZ_TOP || edge == WMSZ_BOTTOM) {
            width = (height * 4 + 1) / 3;
        } else {
            height = (width * 3 + 2) / 4;
        }
    }
    if (edge == WMSZ_LEFT || edge == WMSZ_TOPLEFT || edge == WMSZ_BOTTOMLEFT)
        rect->left = rect->right - width - fw;
    else
        rect->right = rect->left + width + fw;
    if (edge == WMSZ_TOP || edge == WMSZ_TOPLEFT || edge == WMSZ_TOPRIGHT)
        rect->top = rect->bottom - height - fh;
    else
        rect->bottom = rect->top + height + fh;
}

static LRESULT CALLBACK resize_proc(HWND window, UINT message, WPARAM wp, LPARAM lp)
{
    /* Keep the chain target valid if another thread rolls back the install
     * while this message is already executing. */
    WNDPROC original = g_original;
    if (g_resizable) {
        switch (message) {
        case WM_NCHITTEST: {
            /* TH09 has an ANSI window class. Let Windows calculate DWM/DPI-aware
             * frame hit regions instead of using hardcoded screen coordinates. */
            LRESULT hit = DefWindowProcA(window, message, wp, lp);
            InterlockedIncrement(&g_stats.hit_tests);
            g_stats.last_hit = (LONG)hit;
            if (is_resize_hit(hit)) InterlockedIncrement(&g_stats.edge_hits);
            return hit;
        }
        case WM_SETCURSOR:
            /* TH09's original WndProc always consumes this message and hides or
             * replaces the pointer. Preserve that behavior inside the playfield,
             * but allow the OS resize cursor over the native frame. */
            if ((short)LOWORD(lp) != HTCLIENT)
                return DefWindowProcA(window, message, wp, lp);
            break;
        case WM_NCLBUTTONDOWN:
        case WM_NCLBUTTONDBLCLK:
            if (is_resize_hit((LRESULT)wp))
                return DefWindowProcA(window, message, wp, lp);
            break;
        case WM_SYSCOMMAND:
            if ((wp & 0xfff0) == SC_SIZE) {
                InterlockedIncrement(&g_stats.size_commands);
                return DefWindowProcA(window, message, wp, lp);
            }
            break;
        case WM_GETMINMAXINFO: {
            MINMAXINFO *info = (MINMAXINFO *)lp;
            int fw, fh;
            DefWindowProcA(window, message, wp, lp);
            frame_extent(window, &fw, &fh);
            info->ptMinTrackSize.x = 320 + fw;
            info->ptMinTrackSize.y = 240 + fh;
            if (info->ptMaxTrackSize.x < GetSystemMetrics(SM_CXVIRTUALSCREEN) + fw)
                info->ptMaxTrackSize.x = GetSystemMetrics(SM_CXVIRTUALSCREEN) + fw;
            if (info->ptMaxTrackSize.y < GetSystemMetrics(SM_CYVIRTUALSCREEN) + fh)
                info->ptMaxTrackSize.y = GetSystemMetrics(SM_CYVIRTUALSCREEN) + fh;
            return 0;
        }
        case WM_SIZING:
            InterlockedIncrement(&g_stats.sizing_events);
            constrain_sizing(window, wp, (RECT *)lp);
            return TRUE;
        case WM_ENTERSIZEMOVE:
            log_text("Native resize/move loop entered.");
            break;
        case WM_EXITSIZEMOVE: {
            char text[192];
            update_dimensions(window);
            InterlockedIncrement(&g_stats.completed_drags);
            sprintf(text, "Native resize/move completed: client=%ldx%ld sizing_events=%ld edge_hits=%ld.",
                g_stats.client_width, g_stats.client_height,
                g_stats.sizing_events, g_stats.edge_hits);
            log_text(text);
            break;
        }
        }
    }
    if (message == WM_SIZE) update_dimensions(window);
    if (message == WM_NCDESTROY) {
        LRESULT result = original ? CallWindowProcA(original, window, message, wp, lp)
            : DefWindowProcA(window, message, wp, lp);
        if (g_window == window) {
            InterlockedExchange(&g_stats.installed, 0);
            g_window = NULL;
            g_original = NULL;
        }
        log_text("Game window destroyed; waiting to attach to its replacement.");
        return result;
    }
    return original ? CallWindowProcA(original, window, message, wp, lp)
        : DefWindowProcA(window, message, wp, lp);
}

static BOOL install_native_subclass(HWND window, int width, int height)
{
    LONG style, desired;
    RECT rect, outer;
    MONITORINFO monitor;
    int fw, fh, x, y, max_width, max_height;
    WNDPROC original;
    char text[320];
    if (g_window && !IsWindow(g_window)) {
        g_window = NULL;
        g_original = NULL;
        InterlockedExchange(&g_stats.installed, 0);
    }
    if (g_window) {
        if (g_window == window && g_stats.installed) return TRUE;
        SetLastError(ERROR_BUSY);
        return FALSE;
    }
    if (!(GetWindowLongA(window, GWL_STYLE) & WS_CAPTION)) {
        SetLastError(ERROR_INVALID_WINDOW_HANDLE);
        return FALSE;
    }
    style = GetWindowLongA(window, GWL_STYLE);
    g_window = window;
    g_original = (WNDPROC)(LONG_PTR)GetWindowLongPtrA(window, GWLP_WNDPROC);
    original = g_original;
    if (!g_original) {
        g_window = NULL;
        SetLastError(ERROR_INVALID_WINDOW_HANDLE);
        return FALSE;
    }
    /* SetWindowLongPtr supports another thread's window in this same process.
     * Publish the original callback and other state before changing WNDPROC:
     * the GUI thread can immediately invoke the new callback. */
    SetLastError(0);
    if (!SetWindowLongPtrA(window, GWLP_WNDPROC, (LONG_PTR)resize_proc) && GetLastError()) {
        g_window = NULL;
        g_original = NULL;
        return FALSE;
    }
    if ((WNDPROC)(LONG_PTR)GetWindowLongPtrA(window, GWLP_WNDPROC) != resize_proc) {
        SetLastError(IsWindow(window) ? ERROR_INVALID_FUNCTION : ERROR_INVALID_WINDOW_HANDLE);
        goto failed;
    }
    sprintf(text, "Native WndProc published: hwnd=%p install_thread=%lu owner_thread=%lu original=%p callback=%p.",
        (void *)window, GetCurrentThreadId(), GetWindowThreadProcessId(window, NULL),
        (void *)g_original, (void *)resize_proc);
    log_text(text);
    desired = g_resizable ? style | WS_THICKFRAME : style & ~WS_THICKFRAME;
    SetLastError(0);
    if (!SetWindowLongA(window, GWL_STYLE, desired) && GetLastError()) goto failed;
    if (!SetWindowPos(window, NULL, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED)) goto failed;
    frame_extent(window, &fw, &fh);
    if (!GetWindowRect(window, &outer)) goto failed;
    ZeroMemory(&monitor, sizeof(monitor));
    monitor.cbSize = sizeof(monitor);
    if (!GetMonitorInfoA(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor)) goto failed;
    max_width = monitor.rcWork.right - monitor.rcWork.left - fw;
    max_height = monitor.rcWork.bottom - monitor.rcWork.top - fh;
    if (width < 320) width = 320;
    if (height < 240) height = 240;
    if (width > max_width) { height = height * max_width / width; width = max_width; }
    if (height > max_height) { width = width * max_height / height; height = max_height; }
    x = outer.left;
    y = outer.top;
    if (x + width + fw > monitor.rcWork.right) x = monitor.rcWork.right - width - fw;
    if (y + height + fh > monitor.rcWork.bottom) y = monitor.rcWork.bottom - height - fh;
    if (x < monitor.rcWork.left) x = monitor.rcWork.left;
    if (y < monitor.rcWork.top) y = monitor.rcWork.top;
    if (!SetWindowPos(window, NULL, x, y, width + fw, height + fh,
        SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED)) goto failed;
    if (!GetClientRect(window, &rect)) goto failed;
    if (g_window != window || (WNDPROC)(LONG_PTR)GetWindowLongPtrA(window, GWLP_WNDPROC) != resize_proc) {
        SetLastError(ERROR_INVALID_WINDOW_HANDLE);
        goto failed;
    }
    g_stats.client_width = rect.right - rect.left;
    g_stats.client_height = rect.bottom - rect.top;
    g_stats.install_thread = (LONG)GetCurrentThreadId();
    InterlockedExchange(&g_stats.installed, 1);
    sprintf(text, "Installed native WndProc: hwnd=%p client=%ldx%ld resizable=%d keep_aspect=%d install_thread=%lu owner_thread=%lu.",
        (void *)window, g_stats.client_width, g_stats.client_height,
        g_resizable, g_keep_aspect, GetCurrentThreadId(), GetWindowThreadProcessId(window, NULL));
    log_text(text);
    return TRUE;
failed:
    {
        DWORD error = GetLastError();
        /* The game can destroy and replace HWND during startup. Restore only
         * this still-live HWND, using the saved original, never a cleared
         * global or the new window discovered by the monitor. */
        if (IsWindow(window) && g_window == window &&
            (WNDPROC)(LONG_PTR)GetWindowLongPtrA(window, GWLP_WNDPROC) == resize_proc) {
            SetWindowLongPtrA(window, GWLP_WNDPROC, (LONG_PTR)original);
            SetWindowLongA(window, GWL_STYLE, style);
        }
        if (g_window == window) {
            g_window = NULL;
            g_original = NULL;
            InterlockedExchange(&g_stats.installed, 0);
        }
        SetLastError(error);
        return FALSE;
    }
}

BOOL Th09WindowResizeInstall(HWND window, int width, int height,
    BOOL resizable, BOOL keep_aspect, Th09ResizeLogFn logger)
{
    DWORD process, thread;
    g_logger = logger;
    thread = GetWindowThreadProcessId(window, &process);
    if (!thread || process != GetCurrentProcessId()) {
        SetLastError(ERROR_INVALID_WINDOW_HANDLE);
        return FALSE;
    }
    g_resizable = resizable;
    g_keep_aspect = keep_aspect;
    return install_native_subclass(window, width, height);
}

void Th09WindowResizeGetStats(Th09ResizeStats *stats)
{
    if (stats) memcpy(stats, &g_stats, sizeof(*stats));
}
