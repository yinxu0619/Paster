using Microsoft.UI.Xaml.Media.Imaging;
using Paster.Windows.Services;

namespace Paster.Windows.Utilities;

/// <summary>
/// Resolves the branding assets that <c>scripts/generate-icon.ps1</c> emits into
/// <c>Assets\</c>. Everything here is optional: a source tree that has not run the
/// generator yet must still start, just without the icon.
/// </summary>
internal static class AppIcons
{
    private static readonly string AssetsDirectory = Path.Combine(AppContext.BaseDirectory, "Assets");

    /// <summary>Multi-size .ico for window title bars, the taskbar and Alt-Tab.</summary>
    public static string? WindowIconPath => Existing(Path.Combine(AssetsDirectory, "Paster.ico"));

    /// <summary>
    /// Returns the app logo scaled for an in-app icon slot, or null when the asset is missing.
    /// The 256px master is decoded down rather than using one of the small logo PNGs so the
    /// result stays crisp on high-DPI displays.
    /// </summary>
    public static BitmapImage? TryLoadLogo(int decodePixelWidth)
    {
        var path = Existing(Path.Combine(AssetsDirectory, "Paster-256.png"));
        if (path is null)
        {
            return null;
        }

        try
        {
            var image = new BitmapImage { DecodePixelWidth = decodePixelWidth };
            image.UriSource = new Uri(path);
            return image;
        }
        catch (Exception ex)
        {
            AppLog.Error($"App logo '{path}' could not be loaded.", ex);
            return null;
        }
    }

    private static string? Existing(string path) => File.Exists(path) ? path : null;
}
