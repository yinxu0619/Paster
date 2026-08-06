namespace Paster.Windows.Utilities;

/// <summary>
/// "2 minutes ago" style timestamps, mirroring the <c>.relative(presentation: .named)</c> format
/// ClipboardCardView uses on macOS.
///
/// Deliberately a pure function of (timestamp, now): cards call it while they are being bound, so
/// a scroll or a panel open refreshes what is on screen without any card owning a timer.
/// </summary>
public static class RelativeTime
{
    public static string Format(DateTimeOffset value, bool chinese) => Format(value, chinese, DateTimeOffset.Now);

    public static string Format(DateTimeOffset value, bool chinese, DateTimeOffset now)
    {
        var elapsed = now - value;

        // Clock skew, or a row written a fraction of a second ago.
        if (elapsed < TimeSpan.FromSeconds(45))
        {
            return chinese ? "刚刚" : "just now";
        }

        if (elapsed < TimeSpan.FromMinutes(60))
        {
            var minutes = Math.Max(1, (int)Math.Round(elapsed.TotalMinutes));
            return chinese ? $"{minutes} 分钟前" : Plural(minutes, "minute");
        }

        if (elapsed < TimeSpan.FromHours(24))
        {
            var hours = Math.Max(1, (int)Math.Floor(elapsed.TotalHours));
            return chinese ? $"{hours} 小时前" : Plural(hours, "hour");
        }

        if (elapsed < TimeSpan.FromDays(7))
        {
            var days = Math.Max(1, (int)Math.Floor(elapsed.TotalDays));
            return chinese ? $"{days} 天前" : Plural(days, "day");
        }

        // Past a week "37 days ago" stops being useful; show the date instead.
        return value.Year == now.Year
            ? value.ToString(chinese ? "M月d日 HH:mm" : "MMM d, HH:mm")
            : value.ToString(chinese ? "yyyy年M月d日" : "yyyy-MM-dd");
    }

    private static string Plural(int count, string unit) =>
        count == 1 ? $"1 {unit} ago" : $"{count} {unit}s ago";
}
