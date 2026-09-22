# Optional window helper

Historical notes for 0.1.3 only. As of 0.1.4 this helper is no longer started
or distributed: native window_support.dll handles the complete resize message
path. See src/native/README.md. The implementation below only changed styles
and initial size and did not establish actual in-game drag behavior.

`window-helper.ps1` adds a resize border and sets the client area once, then exits.
It locates TH09 by the full executable path and can restrict the match to a PID
and launch timestamp. It does not start/close games, inject code, or modify game
files or internal game coordinates. Windowed mode is required; fullscreen is
detected conservatively by the absence of the normal caption and skipped.

Launcher integration example (run the helper as a separate hidden PowerShell
process immediately before/after starting the game):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File window-helper.ps1 `
  -GameExe 'D:\games\TH09\th09.exe' -StartedAfterUtc '2026-09-20T09:00:00Z' `
  -Width 960 -Height 720 -Resizable 1 -LogPath window-helper.log
```

Use `Start-Process -WindowStyle Hidden` for production background launch. Quote
paths individually and supply a timestamp captured immediately before launching
the game. If multiple matching processes remain, pass `-GameProcessId`.
`-Resizable 0` disables manual edge dragging. Oversized initial dimensions shrink
proportionally to fit the monitor work area. Recommended initial dimensions have
4:3 aspect ratio (640x480, 960x720, 1280x960). Free edge dragging can distort the
aspect ratio: this helper does not install a game window-procedure hook to force
4:3. Dragging a legacy game's frame may temporarily pause its render thread;
resize between battles.

The game keeps its original rendering resolution. The Direct3D presentation path
normally stretches its backbuffer into the current client area; this does not
increase internal detail. Official thprac uses the same resize-frame principle
in `GameGuiInit` (`WS_SIZEBOX` plus `SetWindowPos`), and separately hooks `WM_SIZING`
to enforce 4:3. We do not bundle or attach thprac for this feature.

Verification commands:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File window-helper.ps1 -CompileOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File window-helper.ps1 -SelfTest
```

SelfTest creates and destroys only its own invisible native test window. It
checks adding/removing the resize border and verifies measured client dimensions.
This verifies the Win32 helper, not actual TH09 rendering, fullscreen switching,
third-party wrappers, or thprac/vpatch coexistence. Those need game-side testing.

Primary references:

- https://github.com/touhouworldcup/thprac/blob/master/thprac/src/thprac/thprac_games.cpp
- https://github.com/touhouworldcup/thprac/blob/master/thprac/src/thprac/thprac_gui_impl_win32.cpp
- https://learn.microsoft.com/en-us/previous-versions/windows/embedded/ms889707(v=msdn.10)
- https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowpos
