using Microsoft.UI.Dispatching;
using Paster.Windows.Native;

namespace Paster.Windows.Services;

public sealed class TrayIconService : MessageWindow
{
    private const int TrayIconId = 1;
    private const int TrayCallbackMessage = 0x8000 + 42;
    private const uint CommandShowHistory = 1;
    private const uint CommandClearHistory = 2;
    private const uint CommandSettings = 3;
    private const uint CommandQuit = 4;

    private readonly DispatcherQueue _dispatcherQueue;
    private readonly Action _showWindow;
    private readonly Action _clearHistory;
    private readonly Action _showSettings;
    private readonly Action _quit;
    private readonly Func<string, string, string> _localize;
    private IntPtr _iconHandle;
    private bool _disposed;

    public TrayIconService(
        DispatcherQueue dispatcherQueue,
        Func<string, string, string> localize,
        Action showWindow,
        Action clearHistory,
        Action showSettings,
        Action quit) : base("PasterTrayIcon")
    {
        _dispatcherQueue = dispatcherQueue;
        _localize = localize;
        _showWindow = showWindow;
        _clearHistory = clearHistory;
        _showSettings = showSettings;
        _quit = quit;

        Create();
        AddIcon();
    }

    private void Enqueue(Action action)
    {
        _dispatcherQueue.TryEnqueue(() =>
        {
            try
            {
                action();
            }
            catch (Exception ex)
            {
                AppLog.Error("Tray action failed.", ex);
            }
        });
    }

    protected override IntPtr HandleMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam)
    {
        if (message == TrayCallbackMessage)
        {
            var mouseMessage = lParam.ToInt32();
            if (mouseMessage == NativeMethods.WmLButtonUp)
            {
                Enqueue(_showWindow);
            }
            else if (mouseMessage == NativeMethods.WmRButtonUp)
            {
                ShowContextMenu();
            }

            return IntPtr.Zero;
        }

        return NativeMethods.DefWindowProc(hwnd, message, wParam, lParam);
    }

    /// <summary>
    /// Mirrors popUpStatusMenu() in Paster/App/AppDelegate.swift.
    /// </summary>
    private void ShowContextMenu()
    {
        var menu = NativeMethods.CreatePopupMenu();
        if (menu == IntPtr.Zero)
        {
            AppLog.Error("Failed to create the tray context menu; falling back to Settings.");
            Enqueue(_showSettings);
            return;
        }

        try
        {
            NativeMethods.AppendMenu(menu, NativeMethods.MfString, (UIntPtr)CommandShowHistory, _localize("Show History", "显示历史"));
            NativeMethods.AppendMenu(menu, NativeMethods.MfSeparator, UIntPtr.Zero, null);
            NativeMethods.AppendMenu(menu, NativeMethods.MfString, (UIntPtr)CommandClearHistory, _localize("Clear History", "清空历史"));
            NativeMethods.AppendMenu(menu, NativeMethods.MfString, (UIntPtr)CommandSettings, _localize("Settings", "设置"));
            NativeMethods.AppendMenu(menu, NativeMethods.MfSeparator, UIntPtr.Zero, null);
            NativeMethods.AppendMenu(menu, NativeMethods.MfString, (UIntPtr)CommandQuit, _localize("Quit Paster", "退出 Paster"));

            NativeMethods.GetCursorPos(out var cursor);

            // A tray menu only dismisses on outside clicks if its owner is foreground first, and
            // the owner needs a nudge afterwards to leave the internal menu loop.
            NativeMethods.SetForegroundWindow(Hwnd);
            var command = NativeMethods.TrackPopupMenu(
                menu,
                NativeMethods.TpmLeftAlign | NativeMethods.TpmBottomAlign | NativeMethods.TpmRightButton |
                NativeMethods.TpmReturnCmd | NativeMethods.TpmNonNotify,
                cursor.X,
                cursor.Y,
                0,
                Hwnd,
                IntPtr.Zero);
            NativeMethods.PostMessage(Hwnd, NativeMethods.WmNull, IntPtr.Zero, IntPtr.Zero);

            Invoke((uint)command);
        }
        catch (Exception ex)
        {
            AppLog.Error("Tray context menu failed.", ex);
        }
        finally
        {
            NativeMethods.DestroyMenu(menu);
        }
    }

    private void Invoke(uint command)
    {
        switch (command)
        {
            case CommandShowHistory:
                Enqueue(_showWindow);
                break;
            case CommandClearHistory:
                Enqueue(_clearHistory);
                break;
            case CommandSettings:
                Enqueue(_showSettings);
                break;
            case CommandQuit:
                AppLog.Info("Quit requested from the tray menu.");
                Enqueue(_quit);
                break;
        }
    }

    private void AddIcon()
    {
        var iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "Paster.ico");
        _iconHandle = File.Exists(iconPath)
            ? NativeMethods.LoadImage(IntPtr.Zero, iconPath, NativeMethods.ImageIcon, 0, 0, NativeMethods.LrLoadFromFile | NativeMethods.LrDefaultSize)
            : IntPtr.Zero;

        var data = new NativeMethods.NotifyIconData
        {
            cbSize = System.Runtime.InteropServices.Marshal.SizeOf<NativeMethods.NotifyIconData>(),
            hWnd = Hwnd,
            uID = TrayIconId,
            uFlags = NativeMethods.NifMessage | NativeMethods.NifIcon | NativeMethods.NifTip,
            uCallbackMessage = TrayCallbackMessage,
            hIcon = _iconHandle,
            szTip = _localize("Paster - left click to open, right click for the menu", "Paster - 左键打开，右键显示菜单")
        };

        if (!NativeMethods.ShellNotifyIcon(NativeMethods.NimAdd, ref data))
        {
            AppLog.Info("Failed to create tray icon.");
        }
    }

    public override void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        var data = new NativeMethods.NotifyIconData
        {
            cbSize = System.Runtime.InteropServices.Marshal.SizeOf<NativeMethods.NotifyIconData>(),
            hWnd = Hwnd,
            uID = TrayIconId
        };
        NativeMethods.ShellNotifyIcon(NativeMethods.NimDelete, ref data);

        if (_iconHandle != IntPtr.Zero)
        {
            NativeMethods.DestroyIcon(_iconHandle);
            _iconHandle = IntPtr.Zero;
        }

        base.Dispose();
        _disposed = true;
    }
}
