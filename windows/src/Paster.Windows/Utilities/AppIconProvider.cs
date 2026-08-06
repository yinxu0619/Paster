using System.Runtime.InteropServices;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Paster.Windows.Native;
using Paster.Windows.Services;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace Paster.Windows.Utilities;

/// <summary>
/// Source-application icons for history cards, the Windows counterpart of
/// Paster/Utilities/AppIconProvider.swift. Icons come from the executable path already stored on
/// every row (<c>ClipboardItem.SourceProcessPath</c>) and are cached forever - a clipboard history
/// only ever has a handful of distinct source apps, and shell icon lookups hit the disk.
///
/// Must be called from the UI thread: the cache holds <see cref="BitmapImage"/> instances.
/// </summary>
public static class AppIconProvider
{
    private static readonly Dictionary<string, ImageSource?> Cache = new(StringComparer.OrdinalIgnoreCase);
    private static readonly Dictionary<string, Task<ImageSource?>> InFlight = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Synchronous lookup for an icon that has already been loaded. Recycled card elements use
    /// this so a card that scrolls back into view does not flash a placeholder.
    /// </summary>
    public static bool TryGetCached(string? processPath, out ImageSource? icon)
    {
        icon = null;
        return !string.IsNullOrWhiteSpace(processPath) && Cache.TryGetValue(processPath!, out icon);
    }

    public static Task<ImageSource?> GetAsync(string? processPath)
    {
        if (string.IsNullOrWhiteSpace(processPath))
        {
            return Task.FromResult<ImageSource?>(null);
        }

        if (Cache.TryGetValue(processPath, out var cached))
        {
            return Task.FromResult(cached);
        }

        if (InFlight.TryGetValue(processPath, out var pending))
        {
            return pending;
        }

        var load = LoadAsync(processPath);
        InFlight[processPath] = load;
        return load;
    }

    private static async Task<ImageSource?> LoadAsync(string processPath)
    {
        ImageSource? result = null;
        try
        {
            if (ExtractIconPixels(processPath) is { } pixels)
            {
                result = await DecodeAsync(pixels);
            }
        }
        catch (Exception ex)
        {
            // A missing, renamed or permission-denied executable is normal for old history rows.
            AppLog.Error($"Failed to load the source app icon for '{processPath}'.", ex);
        }
        finally
        {
            Cache[processPath] = result;
            InFlight.Remove(processPath);
        }

        return result;
    }

    private sealed record IconPixels(byte[] Bgra, uint Width, uint Height);

    private static IconPixels? ExtractIconPixels(string processPath)
    {
        if (!File.Exists(processPath))
        {
            return null;
        }

        var info = new NativeMethods.ShFileInfo();
        var size = (uint)Marshal.SizeOf<NativeMethods.ShFileInfo>();
        if (NativeMethods.ShGetFileInfo(processPath, 0, ref info, size,
                NativeMethods.ShgfiIcon | NativeMethods.ShgfiLargeIcon) == IntPtr.Zero ||
            info.hIcon == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            return ReadIcon(info.hIcon);
        }
        finally
        {
            NativeMethods.DestroyIcon(info.hIcon);
        }
    }

    private static IconPixels? ReadIcon(IntPtr hIcon)
    {
        if (!NativeMethods.GetIconInfo(hIcon, out var iconInfo))
        {
            return null;
        }

        var screenDc = NativeMethods.GetDC(IntPtr.Zero);
        try
        {
            if (iconInfo.hbmColor == IntPtr.Zero ||
                NativeMethods.GetObject(iconInfo.hbmColor, Marshal.SizeOf<NativeMethods.Bitmap>(), out var bitmap) == 0 ||
                bitmap.bmWidth <= 0 || bitmap.bmHeight <= 0)
            {
                return null;
            }

            var width = bitmap.bmWidth;
            var height = bitmap.bmHeight;
            var pixels = ReadBgra(screenDc, iconInfo.hbmColor, width, height);
            if (pixels is null)
            {
                return null;
            }

            // Pre-Vista icons carry transparency in a 1bpp mask instead of an alpha channel, so a
            // fully zero alpha plane means "opaque where the mask is clear", not "invisible".
            if (IsFullyTransparent(pixels))
            {
                ApplyMaskAlpha(screenDc, iconInfo.hbmMask, pixels, width, height);
            }

            return new IconPixels(pixels, (uint)width, (uint)height);
        }
        finally
        {
            NativeMethods.ReleaseDC(IntPtr.Zero, screenDc);
            if (iconInfo.hbmColor != IntPtr.Zero)
            {
                NativeMethods.DeleteObject(iconInfo.hbmColor);
            }
            if (iconInfo.hbmMask != IntPtr.Zero)
            {
                NativeMethods.DeleteObject(iconInfo.hbmMask);
            }
        }
    }

    private static byte[]? ReadBgra(IntPtr dc, IntPtr bitmapHandle, int width, int height)
    {
        var header = new NativeMethods.BitmapInfo
        {
            bmiHeader = new NativeMethods.BitmapInfoHeader
            {
                biSize = (uint)Marshal.SizeOf<NativeMethods.BitmapInfoHeader>(),
                biWidth = width,
                // Negative height requests a top-down DIB, matching the row order BitmapEncoder wants.
                biHeight = -height,
                biPlanes = 1,
                biBitCount = 32,
                biCompression = NativeMethods.BiRgb
            },
            bmiColors = new uint[256]
        };

        var buffer = new byte[width * height * 4];
        return NativeMethods.GetDIBits(dc, bitmapHandle, 0, (uint)height, buffer, ref header, NativeMethods.DibRgbColors) == 0
            ? null
            : buffer;
    }

    private static bool IsFullyTransparent(byte[] bgra)
    {
        for (var index = 3; index < bgra.Length; index += 4)
        {
            if (bgra[index] != 0)
            {
                return false;
            }
        }

        return true;
    }

    private static void ApplyMaskAlpha(IntPtr dc, IntPtr maskHandle, byte[] bgra, int width, int height)
    {
        if (maskHandle == IntPtr.Zero)
        {
            for (var index = 3; index < bgra.Length; index += 4)
            {
                bgra[index] = 255;
            }

            return;
        }

        var mask = ReadBgra(dc, maskHandle, width, height);
        if (mask is null)
        {
            return;
        }

        // The AND mask is white where the icon should be see-through.
        for (var index = 0; index < bgra.Length; index += 4)
        {
            bgra[index + 3] = mask[index] == 0 ? (byte)255 : (byte)0;
        }
    }

    /// <summary>
    /// Round-trips the raw pixels through the PNG encoder. WinUI has no supported way to hand a
    /// managed byte[] straight to a BitmapSource, and BitmapEncoder is already the codec path this
    /// project uses for clipboard thumbnails.
    /// </summary>
    private static async Task<ImageSource?> DecodeAsync(IconPixels pixels)
    {
        using var stream = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(
            BitmapPixelFormat.Bgra8,
            BitmapAlphaMode.Straight,
            pixels.Width,
            pixels.Height,
            96,
            96,
            pixels.Bgra);
        await encoder.FlushAsync();
        stream.Seek(0);

        var bitmap = new BitmapImage();
        await bitmap.SetSourceAsync(stream);
        return bitmap;
    }
}
