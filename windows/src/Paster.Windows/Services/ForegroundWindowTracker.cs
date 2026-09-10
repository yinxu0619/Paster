using System.Text;
using Paster.Windows.Native;

namespace Paster.Windows.Services;

/// Remembers the last application window before the taskbar or Paster takes focus.
internal sealed class ForegroundWindowTracker : IDisposable
{
    private readonly NativeMethods.WinEventProc _callback;
    private IntPtr _hook;
    private IntPtr _lastWindow;
    private uint _lastProcess;

    public ForegroundWindowTracker()
    {
        _callback = (_, _, hwnd, _, _, _, _) => Remember(hwnd);
        _hook = NativeMethods.SetWinEventHook(3, 3, IntPtr.Zero, _callback, 0, 0, 0);
        Remember(NativeMethods.GetForegroundWindow());
        if (_hook == IntPtr.Zero) { AppLog.Error("Could not monitor foreground windows."); }
    }

    public IntPtr Capture(IntPtr candidate)
    {
        Remember(candidate);
        NativeMethods.GetWindowThreadProcessId(_lastWindow, out var process);
        return NativeMethods.IsWindow(_lastWindow) && process == _lastProcess ? _lastWindow : IntPtr.Zero;
    }

    private void Remember(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero || !NativeMethods.IsWindow(hwnd)) { return; }
        NativeMethods.GetWindowThreadProcessId(hwnd, out var process);
        if (process == 0 || process == Environment.ProcessId) { return; }
        var name = new StringBuilder(256);
        NativeMethods.GetClassName(hwnd, name, name.Capacity);
        if (name.ToString() is "Shell_TrayWnd" or "Shell_SecondaryTrayWnd" or "NotifyIconOverflowWindow"
            or "TopLevelWindowForOverflowXamlIsland" or "Progman" or "WorkerW") { return; }
        _lastWindow = hwnd;
        _lastProcess = process;
    }

    public void Dispose()
    {
        if (_hook != IntPtr.Zero) { NativeMethods.UnhookWinEvent(_hook); _hook = IntPtr.Zero; }
        GC.KeepAlive(_callback);
    }
}
