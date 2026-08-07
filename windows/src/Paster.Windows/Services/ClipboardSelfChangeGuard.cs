using Paster.Windows.Native;

namespace Paster.Windows.Services;

/// <summary>
/// Tells Paster's own clipboard writes apart from the user copying in another app, so that
/// pasting a history item does not immediately record that item again as a new one.
/// </summary>
internal static class ClipboardSelfChangeGuard
{
    /// <summary>
    /// One <c>Clipboard.SetContent</c> + <c>Flush</c> raises several WM_CLIPBOARDUPDATE messages,
    /// not one, so the guard has to cover a period rather than a fixed number of notifications.
    /// The window only bounds how long the ownership test stays trusted; ownership is what
    /// actually identifies the write, so the window can be generous without over-suppressing.
    /// </summary>
    private static readonly TimeSpan SelfWriteWindow = TimeSpan.FromSeconds(2);

    private static long _armedUntilTicks;

    public static void MarkSelfWrite() =>
        Interlocked.Exchange(ref _armedUntilTicks, DateTime.UtcNow.Add(SelfWriteWindow).Ticks);

    /// <summary>
    /// True when the clipboard change being reported is the one Paster just made. Ownership is
    /// the discriminator: another app copying the very same content owns the clipboard itself,
    /// so that copy is still recorded.
    /// </summary>
    public static bool IsSelfWrite()
    {
        var armedUntil = Interlocked.Read(ref _armedUntilTicks);
        if (armedUntil == 0 || DateTime.UtcNow.Ticks > armedUntil)
        {
            return false;
        }

        var owner = NativeMethods.GetClipboardOwner();
        if (owner == IntPtr.Zero)
        {
            // Unattributable. Recording a duplicate is recoverable; dropping a real copy is not.
            return false;
        }

        NativeMethods.GetWindowThreadProcessId(owner, out var ownerProcessId);
        return ownerProcessId == Environment.ProcessId;
    }
}
