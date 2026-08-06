using Paster.Windows.Native;
using Paster.Windows.Utilities;

namespace Paster.Windows.Services;

public sealed class HotKeyService : MessageWindow
{
    private const int HotKeyId = 100;
    private readonly AppSettings _settings;
    private bool _registered;
    private uint _activeModifiers;
    private int _activeVirtualKey;

    public bool IsRegistered => _registered;
    public int LastError { get; private set; }

    /// <summary>The combination currently held by Windows, which after a failed change is the old one.</summary>
    public uint ActiveModifiers => _activeModifiers;
    public int ActiveVirtualKey => _activeVirtualKey;

    public event EventHandler<IntPtr>? HotKeyPressed;

    /// <summary>
    /// Raised after the live combination actually changes, so surfaces that display it outside the
    /// settings window — the tray tooltip in particular — follow the setting rather than caching
    /// whatever was registered at startup.
    /// </summary>
    public event EventHandler? Changed;

    public HotKeyService(AppSettings settings) : base("PasterHotKey")
    {
        _settings = settings;
        _activeModifiers = settings.HotKeyModifiers;
        _activeVirtualKey = settings.HotKeyVirtualKey;
    }

    public void Start()
    {
        if (_registered)
        {
            return;
        }

        Create();
        if (!TryRegister(_settings.HotKeyModifiers, _settings.HotKeyVirtualKey))
        {
            return;
        }

        _activeModifiers = _settings.HotKeyModifiers;
        _activeVirtualKey = _settings.HotKeyVirtualKey;
    }

    /// <summary>
    /// Swaps the live combination. On failure — almost always because another app already owns the
    /// combination — the previous one is put back so the user is never left without a way to open
    /// the panel. Returns false with <see cref="LastError"/> set to the Win32 error of the attempt.
    /// </summary>
    public bool Apply(uint modifiers, int virtualKey)
    {
        Create();
        if (_registered && modifiers == _activeModifiers && virtualKey == _activeVirtualKey)
        {
            return true;
        }

        if (_registered)
        {
            NativeMethods.UnregisterHotKey(Hwnd, HotKeyId);
            _registered = false;
        }

        if (TryRegister(modifiers, virtualKey))
        {
            _activeModifiers = modifiers;
            _activeVirtualKey = virtualKey;
            AppLog.Info($"Hotkey changed to {HotKey.Describe(modifiers, virtualKey, chinese: false)}.");
            Changed?.Invoke(this, EventArgs.Empty);
            return true;
        }

        var failure = LastError;
        if (!TryRegister(_activeModifiers, _activeVirtualKey))
        {
            AppLog.Error($"Hotkey {HotKey.Describe(modifiers, virtualKey, false)} was rejected (Win32 {failure}) " +
                         $"and the previous {HotKey.Describe(_activeModifiers, _activeVirtualKey, false)} " +
                         $"could not be restored either (Win32 {LastError}).");
        }
        else
        {
            AppLog.Info($"Hotkey {HotKey.Describe(modifiers, virtualKey, false)} was rejected (Win32 {failure}); " +
                        $"reverted to {HotKey.Describe(_activeModifiers, _activeVirtualKey, false)}.");
        }

        LastError = failure;
        return false;
    }

    private bool TryRegister(uint modifiers, int virtualKey)
    {
        _registered = NativeMethods.RegisterHotKey(Hwnd, HotKeyId, modifiers, (uint)virtualKey);
        LastError = _registered ? 0 : System.Runtime.InteropServices.Marshal.GetLastWin32Error();
        return _registered;
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
