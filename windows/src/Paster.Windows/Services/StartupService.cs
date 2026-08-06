using Microsoft.Win32;

namespace Paster.Windows.Services;

/// <summary>
/// Registers Paster under the per-user Run key so it starts with the Windows session.
/// Registry access is best-effort: a locked-down or policy-managed machine must never
/// prevent the clipboard app from running.
/// </summary>
public static class StartupService
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "Paster";

    public static string? LastError { get; private set; }

    public static string ExecutablePath
    {
        get
        {
            var path = Environment.ProcessPath;
            return string.IsNullOrWhiteSpace(path)
                ? Path.Combine(AppContext.BaseDirectory, "Paster.Windows.exe")
                : path;
        }
    }

    private static string CommandLine => $"\"{ExecutablePath}\"";

    /// <summary>
    /// Returns whether the Run entry currently points at this executable,
    /// or null when the registry could not be read.
    /// </summary>
    public static bool? IsEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: false);
            var value = key?.GetValue(ValueName) as string;
            LastError = null;
            return !string.IsNullOrWhiteSpace(value);
        }
        catch (Exception ex)
        {
            LastError = ex.Message;
            AppLog.Error("Failed to read launch-at-login registry value.", ex);
            return null;
        }
    }

    public static bool TryApply(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true)
                            ?? Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true);
            if (key is null)
            {
                LastError = "Run registry key is unavailable.";
                AppLog.Error($"Failed to open launch-at-login registry key: {LastError}");
                return false;
            }

            if (enabled)
            {
                key.SetValue(ValueName, CommandLine, RegistryValueKind.String);
                AppLog.Info($"Launch at login enabled for {CommandLine}.");
            }
            else if (key.GetValue(ValueName) is not null)
            {
                key.DeleteValue(ValueName, throwOnMissingValue: false);
                AppLog.Info("Launch at login disabled.");
            }

            LastError = null;
            return true;
        }
        catch (Exception ex)
        {
            LastError = ex.Message;
            AppLog.Error($"Failed to {(enabled ? "enable" : "disable")} launch at login.", ex);
            return false;
        }
    }

    /// <summary>
    /// Makes the registry match the saved preference. The saved setting wins, so a moved or
    /// renamed executable is re-registered with its new path on the next launch.
    /// </summary>
    public static void Reconcile(AppSettings settings)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: false);
            var current = key?.GetValue(ValueName) as string;
            var expected = CommandLine;

            if (settings.LaunchAtLogin)
            {
                if (!string.Equals(current, expected, StringComparison.OrdinalIgnoreCase))
                {
                    TryApply(true);
                }
            }
            else if (!string.IsNullOrWhiteSpace(current))
            {
                TryApply(false);
            }
        }
        catch (Exception ex)
        {
            LastError = ex.Message;
            AppLog.Error("Failed to reconcile launch-at-login state.", ex);
        }
    }
}
