using Paster.Windows.Native;

namespace Paster.Windows.Services;

public sealed class HotKeyService : MessageWindow
{
    private const int HotKeyId = 100;
    private readonly AppSettings _settings;
    private bool _registered;

    public bool IsRegistered => _registered;
    public int LastError { get; private set; }

    public event EventHandler<IntPtr>? HotKeyPressed;

    public HotKeyService(AppSettings settings) : base("PasterHotKey")
    {
        _settings = settings;
    }

    public void Start()
    {
        if (_registered)
        {
            return;
        }

        Create();
        _registered = NativeMethods.RegisterHotKey(Hwnd, HotKeyId, _settings.HotKeyModifiers, (uint)_settings.HotKeyVirtualKey);
        LastError = _registered ? 0 : System.Runtime.InteropServices.Marshal.GetLastWin32Error();
    }

    protected override IntPtr HandleMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam)
    {
        if (message == NativeMethods.WmHotKey && wParam.ToInt32() == HotKeyId)
        {
            HotKeyPressed?.Invoke(this, NativeMethods.GetForegroundWindow());
            return IntPtr.Zero;
        }

        return NativeMethods.DefWindowProc(hwnd, message, wParam, lParam);
    }

    public override void Dispose()
    {
        if (_registered && Hwnd != IntPtr.Zero)
        {
            NativeMethods.UnregisterHotKey(Hwnd, HotKeyId);
        }

        base.Dispose();
    }
}
