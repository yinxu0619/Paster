using Paster.Windows.Native;

namespace Paster.Windows.Services;

public abstract class MessageWindow : IDisposable
{
    private readonly NativeMethods.WindowProc _windowProc;
    private readonly string _className;
    private bool _disposed;

    protected IntPtr Hwnd { get; private set; }

    protected MessageWindow(string className)
    {
        _className = $"{className}-{Guid.NewGuid():N}";
        _windowProc = WndProc;
    }

    protected void Create()
    {
        if (Hwnd != IntPtr.Zero)
        {
            return;
        }

        var wndClass = new NativeMethods.WndClass
        {
            lpfnWndProc = _windowProc,
            hInstance = NativeMethods.GetModuleHandle(null),
            lpszClassName = _className
        };

        NativeMethods.RegisterClass(ref wndClass);
        Hwnd = NativeMethods.CreateWindowEx(0, _className, _className, 0, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, wndClass.hInstance, IntPtr.Zero);
        if (Hwnd == IntPtr.Zero)
        {
            throw new InvalidOperationException($"Failed to create message window {_className}.");
        }
    }

    protected abstract IntPtr HandleMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);

    private IntPtr WndProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam)
    {
        return HandleMessage(hwnd, message, wParam, lParam);
    }

    public virtual void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        if (Hwnd != IntPtr.Zero)
        {
            NativeMethods.DestroyWindow(Hwnd);
            Hwnd = IntPtr.Zero;
        }

        _disposed = true;
        GC.SuppressFinalize(this);
    }
}
