namespace Paster.Windows.Services;

internal static class ClipboardSelfChangeGuard
{
    private static int _pendingSelfWrites;

    public static void MarkSelfWrite()
    {
        Interlocked.Increment(ref _pendingSelfWrites);
    }

    public static bool ConsumeIfSelfWrite()
    {
        while (true)
        {
            var current = Volatile.Read(ref _pendingSelfWrites);
            if (current <= 0)
            {
                return false;
            }

            if (Interlocked.CompareExchange(ref _pendingSelfWrites, current - 1, current) == current)
            {
                return true;
            }
        }
    }
}
