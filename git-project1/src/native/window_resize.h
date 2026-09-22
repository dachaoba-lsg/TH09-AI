#ifndef TH09_WINDOW_RESIZE_H
#define TH09_WINDOW_RESIZE_H

#include <windows.h>

typedef void (*Th09ResizeLogFn)(const char *message);

typedef struct Th09ResizeStats {
    DWORD struct_size;
    LONG installed;
    LONG hit_tests;
    LONG edge_hits;
    LONG sizing_events;
    LONG size_commands;
    LONG completed_drags;
    LONG client_width;
    LONG client_height;
    LONG last_hit;
    LONG install_thread;
} Th09ResizeStats;

/* Call once, from any thread in the owning process, after window creation.
 * SetWindowLongPtr publishes the subclass directly in this process; window
 * callbacks still execute on the window's owning GUI thread.
 * This library must remain loaded for the window's lifetime. */
#ifdef TH09_WINDOW_TEST_EXPORT
__declspec(dllexport)
#endif
BOOL Th09WindowResizeInstall(HWND window, int width, int height,
    BOOL resizable, BOOL keep_aspect, Th09ResizeLogFn logger);
#ifdef TH09_WINDOW_TEST_EXPORT
__declspec(dllexport)
#endif
void Th09WindowResizeGetStats(Th09ResizeStats *stats);

#endif
