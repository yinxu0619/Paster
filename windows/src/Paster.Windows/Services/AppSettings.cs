using System.Text.Json;
using Paster.Windows.Models;

namespace Paster.Windows.Services;

public sealed class AppSettings
{
    private static readonly string SettingsPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Paster.Windows",
        "settings.json");

    private string _settingsPath = SettingsPath;

    public int HistoryLimit { get; set; } = 200;
    public PanelPosition PanelPosition { get; set; } = PanelPosition.Bottom;
    public double BarHeight { get; set; } = 240;
    public bool LaunchAtLogin { get; set; }
    public List<string> ExcludedProcessNames { get; set; } = [];
    public int HotKeyVirtualKey { get; set; } = 0x43;
    public uint HotKeyModifiers { get; set; } = Native.NativeMethods.ModAlt;
    public AppLanguage Language { get; set; } = AppLanguage.System;
    public double AnimationBounciness { get; set; } = 1.35;

    /// <summary>
    /// How solid the panel is over the acrylic backdrop. 0 is clear frosted glass, 1 is a solid
    /// theme colour. Settings files written before this property existed simply keep the default.
    /// </summary>
    public double PanelOpacity { get; set; } = DefaultPanelOpacity;

    /// <summary>
    /// Escape hatch for hardware that renders acrylic poorly, and for users who just dislike it.
    /// When off the panel paints an opaque theme colour and no backdrop is created at all.
    /// </summary>
    public bool PanelAcrylicEnabled { get; set; } = true;

    public const double MinPanelOpacity = 0.0;
    public const double MaxPanelOpacity = 1.0;
    public const double DefaultPanelOpacity = 0.45;

    public static AppSettings Load(string? settingsPath = null)
    {
        var path = settingsPath ?? SettingsPath;
        try
        {
            if (File.Exists(path))
            {
                var settings = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path)) ?? new AppSettings();
                settings._settingsPath = path;
                // Earlier MVP builds used Alt+V. There was no hotkey UI yet, so migrate that default to Alt+C.
                if (settings.HotKeyModifiers == Native.NativeMethods.ModAlt && settings.HotKeyVirtualKey == 0x56)
                {
                    settings.HotKeyVirtualKey = 0x43;
                    settings.Save();
                }
                settings.PanelOpacity = Math.Clamp(settings.PanelOpacity, MinPanelOpacity, MaxPanelOpacity);
                return settings;
            }
        }
        catch
        {
            // Broken settings should not prevent clipboard capture from starting.
        }

        return new AppSettings { _settingsPath = path };
    }

    public void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_settingsPath)!);
        File.WriteAllText(_settingsPath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
    }

    public bool IsExcluded(string? processNameOrPath)
    {
        if (string.IsNullOrWhiteSpace(processNameOrPath))
        {
            return false;
        }

        var fileName = Path.GetFileNameWithoutExtension(processNameOrPath);
        return ExcludedProcessNames.Any(x =>
            string.Equals(x, processNameOrPath, StringComparison.OrdinalIgnoreCase) ||
            string.Equals(x, fileName, StringComparison.OrdinalIgnoreCase));
    }
}
