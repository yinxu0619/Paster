namespace Paster.Windows.Services;

/// <summary>
/// The clipboard is one lock shared by every process. While the copying app, another clipboard
/// listener or Windows' own clipboard history holds it, reads and writes fail with
/// CLIPBRD_E_CANT_OPEN. Those holds last milliseconds, so a short backoff turns a lost copy or a
/// crashed paste into a brief delay.
/// </summary>
internal static class ClipboardRetry
{
    private const int ClipboardCantOpen = unchecked((int)0x800401D0);
    private const int CallRejected = unchecked((int)0x80010001);
    private const int ServerCallRetryLater = unchecked((int)0x8001010A);
    private static readonly int[] DelaysMs = [10, 20, 40, 80, 160];

    public static bool IsTransient(Exception ex) =>
        ex.HResult is ClipboardCantOpen or CallRejected or ServerCallRetryLater;

    /// <summary>
    /// Runs <paramref name="operation"/>, retrying transient clipboard contention. Continuations stay
    /// on the caller's thread, which the WinRT clipboard APIs require.
    /// </summary>
    public static async Task<T> RunAsync<T>(Func<Task<T>> operation, string what)
    {
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                return await operation();
            }
            catch (Exception ex) when (attempt < DelaysMs.Length && IsTransient(ex))
            {
                AppLog.Trace($"Clipboard busy during {what} (0x{ex.HResult:X8}); retry {attempt + 1}.");
                await Task.Delay(DelaysMs[attempt]);
            }
        }
    }

    public static Task RunAsync(Func<Task> operation, string what) =>
        RunAsync(async () => { await operation(); return true; }, what);
}
