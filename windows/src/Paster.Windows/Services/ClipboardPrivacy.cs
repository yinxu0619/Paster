using System.Runtime.InteropServices;
using Paster.Windows.Native;

namespace Paster.Windows.Services;

/// <summary>
/// Password managers (KeePass, 1Password, Bitwarden …) tag the secrets they copy with registered
/// clipboard formats so that monitors and clipboard history leave them alone. Windows' own Win+V
/// history honours these markers; a history tool that ignores them stores passwords in plain text.
/// </summary>
internal static class ClipboardPrivacy
{
    private static readonly uint ExcludeFromMonitors =
        NativeMethods.RegisterClipboardFormat("ExcludeClipboardContentFromMonitorProcessing");
    private static readonly uint CanIncludeInHistory =
        NativeMethods.RegisterClipboardFormat("CanIncludeInClipboardHistory");

    /// <summary>
    /// True when the current clipboard content must not be recorded. <paramref name="hwnd"/> opens
    /// the clipboard to read the CanIncludeInClipboardHistory flag; opening without emptying it
    /// does not raise another WM_CLIPBOARDUPDATE.
    /// </summary>
    public static bool IsMarkedPrivate(IntPtr hwnd)
    {
        if (ExcludeFromMonitors != 0 && NativeMethods.IsClipboardFormatAvailable(ExcludeFromMonitors))
        {
            return true;
        }

        if (CanIncludeInHistory == 0 || !NativeMethods.IsClipboardFormatAvailable(CanIncludeInHistory))
        {
            return false;
        }

        // The flag is a DWORD: 0 keeps the content out of history, 1 allows it. Reading it needs the
        // clipboard lock; if that stays busy, or the value is unreadable, the copy is not recorded.
        for (var attempt = 0; attempt < 5; attempt++)
        {
            if (NativeMethods.OpenClipboard(hwnd))
            {
                try
                {
                    return ReadDword(NativeMethods.GetClipboardData(CanIncludeInHistory)) != 1;
                }
                finally
                {
                    NativeMethods.CloseClipboard();
                }
            }

            Thread.Sleep(5);
        }

        AppLog.Info("Clipboard stayed locked while reading CanIncludeInClipboardHistory; not recording this copy.");
        return true;
    }

    private static uint? ReadDword(IntPtr handle)
    {
        if (handle == IntPtr.Zero || NativeMethods.GlobalSize(handle) < sizeof(uint))
        {
            return null;
        }

        var data = NativeMethods.GlobalLock(handle);
        if (data == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            return unchecked((uint)Marshal.ReadInt32(data));
        }
        finally
        {
            NativeMethods.GlobalUnlock(handle);
        }
    }
}
