param(
    [string] $GameExe = '',
    [int] $GameProcessId = 0,
    [string] $StartedAfterUtc = '',
    [ValidateRange(320, 7680)] [int] $Width = 960,
    [ValidateRange(240, 4320)] [int] $Height = 720,
    [ValidateSet(0, 1)] [int] $Resizable = 1,
    [ValidateRange(1, 120)] [int] $WaitSeconds = 30,
    [string] $LogPath = '',
    [switch] $SelfTest,
    [switch] $CompileOnly
)

# Windows PowerShell 5.1 compatible. Keep this file ASCII so a BOM is optional.
# This changes only the window frame and client size. It does not patch the game,
# inject a renderer, change internal 640x480 coordinates, or monitor every frame.
$ErrorActionPreference = 'Stop'

function Write-WindowLog([string] $Message) {
    $line = '[{0:u}] {1}' -f [DateTime]::UtcNow, $Message
    Write-Output $line
    if ($LogPath) {
        [IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine,
            (New-Object Text.UTF8Encoding($false)))
    }
}

try {
    if (-not ('Th09AiWindow.Native' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Th09AiWindow {
    public static class Native {
        const int GWL_STYLE = -16;
        const uint WS_CAPTION = 0x00C00000;
        const uint WS_THICKFRAME = 0x00040000;
        const uint SWP_NOMOVE = 0x0002;
        const uint SWP_NOZORDER = 0x0004;
        const uint SWP_NOACTIVATE = 0x0010;
        const uint SWP_FRAMECHANGED = 0x0020;
        const uint SWP_NOOWNERZORDER = 0x0200;
        [StructLayout(LayoutKind.Sequential)]
        public struct Rect { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)]
        struct MonitorInfo { public uint Size; public Rect Monitor, Work; public uint Flags; }
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool IsWindow(IntPtr hWnd);
        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")]
        public static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool GetClientRect(IntPtr hWnd, out Rect rect);
        [DllImport("user32.dll", SetLastError = true)]
        static extern bool GetWindowRect(IntPtr hWnd, out Rect rect);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongW", SetLastError = true)]
        static extern int GetWindowLong(IntPtr hWnd, int index);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongW", SetLastError = true)]
        static extern int SetWindowLong(IntPtr hWnd, int index, int value);
        [DllImport("kernel32.dll")]
        static extern void SetLastError(uint value);
        [DllImport("user32.dll", SetLastError = true)]
        static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y,
            int width, int height, uint flags);
        [DllImport("user32.dll")]
        static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
        [DllImport("user32.dll")]
        static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
        [DllImport("user32.dll", EntryPoint = "CreateWindowExW", CharSet = CharSet.Unicode,
            SetLastError = true)]
        static extern IntPtr CreateWindowEx(uint exStyle, string className, string title,
            uint style, int x, int y, int width, int height, IntPtr parent,
            IntPtr menu, IntPtr instance, IntPtr parameter);
        [DllImport("user32.dll")]
        static extern bool DestroyWindow(IntPtr hWnd);

        static void Check(bool ok, string operation) {
            if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error(), operation);
        }

        public static bool HasResizeFrame(IntPtr window) {
            return ((uint)GetWindowLong(window, GWL_STYLE) & WS_THICKFRAME) != 0;
        }

        public static string Configure(IntPtr window, int requestedWidth,
            int requestedHeight, bool resizable) {
            if (!IsWindow(window)) throw new InvalidOperationException("Window no longer exists.");
            uint oldStyle = unchecked((uint)GetWindowLong(window, GWL_STYLE));
            if ((oldStyle & WS_CAPTION) != WS_CAPTION)
                throw new InvalidOperationException("No normal window caption; select windowed mode in custom.exe first.");
            IntPtr previousDpi = IntPtr.Zero;
            try {
                try { previousDpi = SetThreadDpiAwarenessContext(new IntPtr(-4)); }
                catch (EntryPointNotFoundException) { }
                uint style = resizable ? oldStyle | WS_THICKFRAME : oldStyle & ~WS_THICKFRAME;
                SetLastError(0);
                int oldValue = SetWindowLong(window, GWL_STYLE, unchecked((int)style));
                int error = Marshal.GetLastWin32Error();
                if (oldValue == 0 && error != 0) throw new Win32Exception(error, "SetWindowLongW");
                uint flags = SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER;
                Check(SetWindowPos(window, IntPtr.Zero, 0, 0, 0, 0,
                    flags | SWP_NOMOVE | SWP_FRAMECHANGED | 0x0001), "Apply frame style");

                Rect outer, client;
                Check(GetWindowRect(window, out outer), "GetWindowRect");
                Check(GetClientRect(window, out client), "GetClientRect");
                int frameWidth = outer.Right - outer.Left - (client.Right - client.Left);
                int frameHeight = outer.Bottom - outer.Top - (client.Bottom - client.Top);
                MonitorInfo monitor = new MonitorInfo();
                monitor.Size = (uint)Marshal.SizeOf(typeof(MonitorInfo));
                Check(GetMonitorInfo(MonitorFromWindow(window, 2), ref monitor), "GetMonitorInfo");
                int availableWidth = Math.Max(1, monitor.Work.Right - monitor.Work.Left - frameWidth);
                int availableHeight = Math.Max(1, monitor.Work.Bottom - monitor.Work.Top - frameHeight);
                double scale = Math.Min(1.0, Math.Min((double)availableWidth / requestedWidth,
                    (double)availableHeight / requestedHeight));
                int width = Math.Max(1, (int)Math.Floor(requestedWidth * scale));
                int height = Math.Max(1, (int)Math.Floor(requestedHeight * scale));
                int outerWidth = width + frameWidth;
                int outerHeight = height + frameHeight;
                int x = Math.Max(monitor.Work.Left, Math.Min(outer.Left, monitor.Work.Right - outerWidth));
                int y = Math.Max(monitor.Work.Top, Math.Min(outer.Top, monitor.Work.Bottom - outerHeight));
                Check(SetWindowPos(window, IntPtr.Zero, x, y, outerWidth, outerHeight, flags), "Set client size");
                Check(GetClientRect(window, out client), "Verify client size");
                int actualWidth = client.Right - client.Left;
                int actualHeight = client.Bottom - client.Top;
                if (actualWidth != width || actualHeight != height)
                    throw new InvalidOperationException(String.Format(
                        "Requested {0}x{1}, measured {2}x{3}; game or another window tool constrained resizing.",
                        width, height, actualWidth, actualHeight));
                if (HasResizeFrame(window) != resizable)
                    throw new InvalidOperationException("Resize frame did not remain applied.");
                return String.Format("Client={0}x{1}; requested={2}x{3}; resizable={4}; desktopFit={5}",
                    actualWidth, actualHeight, requestedWidth, requestedHeight, resizable, scale < 1.0);
            } finally {
                if (previousDpi != IntPtr.Zero) SetThreadDpiAwarenessContext(previousDpi);
            }
        }

        public static string RunSelfTest() {
            // An invisible, newly created STATIC test window, never the user's game.
            IntPtr window = CreateWindowEx(0, "STATIC", "TH09-AI resize self-test",
                0x00CA0000, 0, 0, 656, 519, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            Check(window != IntPtr.Zero, "Create hidden self-test window");
            try {
                string first = Configure(window, 640, 480, true);
                string second = Configure(window, 800, 600, false);
                return "PASS: hidden-window frame enable/disable and exact client-size checks. " + first + " | " + second;
            } finally { DestroyWindow(window); }
        }
    }
}
'@
    }
    if ($CompileOnly) { Write-WindowLog 'Native helper compiled successfully.'; exit 0 }
    if ($SelfTest) { Write-WindowLog ([Th09AiWindow.Native]::RunSelfTest()); exit 0 }
    if (-not $GameExe) { throw 'GameExe must be an absolute path to th09.exe.' }
    $expectedPath = [IO.Path]::GetFullPath($GameExe)
    if (-not (Test-Path -LiteralPath $expectedPath -PathType Leaf)) {
        throw ('Game executable does not exist: ' + $expectedPath)
    }
    if ([IO.Path]::GetFileName($expectedPath) -ine 'th09.exe') { throw 'Only th09.exe is supported.' }
    $earliestStart = [DateTime]::MinValue
    if ($StartedAfterUtc) { $earliestStart = [DateTime]::Parse($StartedAfterUtc).ToUniversalTime() }
    $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
    do {
        $matches = @()
        foreach ($candidate in @(Get-Process -Name th09 -ErrorAction SilentlyContinue)) {
            try {
                if ($GameProcessId -gt 0 -and $candidate.Id -ne $GameProcessId) { continue }
                if ($candidate.Path -ine $expectedPath) { continue }
                if ($candidate.StartTime.ToUniversalTime() -lt $earliestStart) { continue }
                $matches += $candidate
            } catch { continue }
        }
        if ($matches.Count -gt 1) { throw 'Multiple matching games found; pass GameProcessId to select one.' }
        if ($matches.Count -eq 1) {
            $candidate = $matches[0]
            $candidate.Refresh()
            $window = $candidate.MainWindowHandle
            if ($window -ne [IntPtr]::Zero -and [Th09AiWindow.Native]::IsWindowVisible($window) -and
                -not [Th09AiWindow.Native]::IsIconic($window)) {
                # Avoid racing the game's initial window style/device setup.
                Start-Sleep -Milliseconds 500
                $candidate.Refresh()
                if ($candidate.HasExited) { throw 'Game exited before window setup.' }
                if ($candidate.MainWindowHandle -ne $window) { continue }
                $result = [Th09AiWindow.Native]::Configure($window, $Width, $Height, ($Resizable -eq 1))
                Write-WindowLog ('PID={0}; {1}' -f $candidate.Id, $result)
                exit 0
            }
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Timed out waiting for the matching visible TH09 window.'
} catch {
    Write-WindowLog ('Window helper failed: ' + $_.Exception.Message)
    exit 1
}
