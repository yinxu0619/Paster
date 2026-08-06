using Paster.Windows.Services;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace Paster.Windows.Utilities;

/// <summary>
/// Image scaling for clipboard storage, mirroring Paster/Utilities/ImageUtils.swift
/// (compressedForStorage / thumbnailPNG). Images are stored at most
/// <see cref="StorageMaxDimension"/> on the long edge and previewed from a small
/// thumbnail, so a 4K screenshot no longer costs tens of megabytes per capture.
/// </summary>
public static class ImageUtils
{
    public const uint StorageMaxDimension = 1600;
    public const uint ThumbnailMaxDimension = 240;

    /// <summary>
    /// Scales an image down for persistence. Images already within the limit are returned
    /// untouched; images are never upscaled.
    /// </summary>
    public static Task<byte[]> CompressForStorageAsync(byte[] bytes, uint maxDimension = StorageMaxDimension) =>
        ResizeAsync(bytes, maxDimension, "storage compression");

    /// <summary>
    /// Produces a small PNG preview used by the history cards.
    /// </summary>
    public static Task<byte[]> CreateThumbnailAsync(byte[] bytes, uint maxDimension = ThumbnailMaxDimension) =>
        ResizeAsync(bytes, maxDimension, "thumbnail generation");

    private static async Task<byte[]> ResizeAsync(byte[] bytes, uint maxDimension, string operation)
    {
        if (bytes.Length == 0 || maxDimension == 0)
        {
            return bytes;
        }

        try
        {
            using var source = await ToStreamAsync(bytes);
            var decoder = await BitmapDecoder.CreateAsync(source);
            var width = decoder.PixelWidth;
            var height = decoder.PixelHeight;
            if (width == 0 || height == 0)
            {
                return bytes;
            }

            var longest = Math.Max(width, height);
            if (longest <= maxDimension)
            {
                return bytes;
            }

            var scale = (double)maxDimension / longest;
            var targetWidth = Math.Max(1u, (uint)Math.Floor(width * scale));
            var targetHeight = Math.Max(1u, (uint)Math.Floor(height * scale));

            var pixels = await decoder.GetPixelDataAsync(
                BitmapPixelFormat.Bgra8,
                BitmapAlphaMode.Straight,
                new BitmapTransform
                {
                    ScaledWidth = targetWidth,
                    ScaledHeight = targetHeight,
                    InterpolationMode = BitmapInterpolationMode.Fant
                },
                ExifOrientationMode.RespectExifOrientation,
                ColorManagementMode.DoNotColorManage);

            using var target = new InMemoryRandomAccessStream();
            var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, target);
            encoder.SetPixelData(
                BitmapPixelFormat.Bgra8,
                BitmapAlphaMode.Straight,
                targetWidth,
                targetHeight,
                decoder.DpiX <= 0 ? 96 : decoder.DpiX,
                decoder.DpiY <= 0 ? 96 : decoder.DpiY,
                pixels.DetachPixelData());
            await encoder.FlushAsync();

            return await ToBytesAsync(target);
        }
        catch (Exception ex)
        {
            // An undecodable clipboard image must still be captured, just without downscaling.
            AppLog.Error($"Image {operation} failed; keeping the original bytes.", ex);
            return bytes;
        }
    }

    private static async Task<InMemoryRandomAccessStream> ToStreamAsync(byte[] bytes)
    {
        var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream))
        {
            writer.WriteBytes(bytes);
            await writer.StoreAsync();
            await writer.FlushAsync();
            writer.DetachStream();
        }

        stream.Seek(0);
        return stream;
    }

    private static async Task<byte[]> ToBytesAsync(IRandomAccessStream stream)
    {
        var length = checked((int)stream.Size);
        var bytes = new byte[length];
        using var reader = new DataReader(stream.GetInputStreamAt(0));
        await reader.LoadAsync((uint)length);
        reader.ReadBytes(bytes);
        return bytes;
    }
}
