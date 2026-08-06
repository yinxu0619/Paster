using System.Collections.Concurrent;
using System.Text;

namespace Paster.Windows.Services;

/// <summary>
/// Append-only text log. Info/Trace writes are buffered and flushed by a background thread so
/// that logging never shows up in the latency of the code paths it measures. Error writes are
/// flushed inline so a crash still lands on disk.
/// </summary>
public static class AppLog
{
    private static readonly string LogDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Paster.Windows");
    private static readonly string LogPath = Path.Combine(LogDirectory, "paster.log");

    private static readonly ConcurrentQueue<string> Pending = new();
    private static readonly AutoResetEvent Signal = new(false);
    private static readonly object FileGate = new();

    /// <summary>
    /// Verbose checkpoint logging. Off unless PASTER_VERBOSE is set, because the hot paths that
    /// use <see cref="Trace"/> run on every panel open.
    /// </summary>
    public static bool VerboseEnabled { get; set; } =
        Environment.GetEnvironmentVariable("PASTER_VERBOSE") is "1" or "true" or "TRUE";

    static AppLog()
    {
        var worker = new Thread(DrainLoop)
        {
            IsBackground = true,
            Name = "Paster.AppLog"
        };
        worker.Start();
        AppDomain.CurrentDomain.ProcessExit += (_, _) => Flush();
    }

    public static void Trace(string message)
    {
        if (VerboseEnabled)
        {
            Enqueue("TRACE", message);
        }
    }

    public static void Info(string message) => Enqueue("INFO", message);

    public static void Error(string message, Exception? exception = null)
    {
        Pending.Enqueue(Format("ERROR", exception is null ? message : $"{message}{Environment.NewLine}{exception}"));
        Flush();
    }

    public static void Flush()
    {
        if (Pending.IsEmpty)
        {
            return;
        }

        var batch = new StringBuilder();
        while (Pending.TryDequeue(out var line))
        {
            batch.Append(line);
        }

        Append(batch.ToString());
    }

    private static void Enqueue(string level, string message)
    {
        Pending.Enqueue(Format(level, message));
        Signal.Set();
    }

    private static string Format(string level, string message) =>
        $"{DateTimeOffset.Now:O} [{level}] {message}{Environment.NewLine}";

    private static void DrainLoop()
    {
        while (true)
        {
            Signal.WaitOne();
            Flush();
        }
    }

    private static void Append(string text)
    {
        if (text.Length == 0)
        {
            return;
        }

        try
        {
            lock (FileGate)
            {
                Directory.CreateDirectory(LogDirectory);
                File.AppendAllText(LogPath, text);
            }
        }
        catch
        {
            // Logging must never take down the clipboard utility.
        }
    }
}
