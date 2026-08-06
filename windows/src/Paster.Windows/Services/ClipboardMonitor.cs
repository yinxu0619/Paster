using Paster.Windows.Models;
using Paster.Windows.Native;
using Paster.Windows.Utilities;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage.Streams;

namespace Paster.Windows.Services;

public sealed class ClipboardMonitor : MessageWindow
{
    private const int MaxTextLength = 1_000_000;
    private readonly ClipboardDatabase _database;
    private readonly AppSettings _settings;

    /// <summary>
    /// Windows fires WM_CLIPBOARDUPDATE more than once for a single copy in some apps, and each
    /// message starts a fire-and-forget record. Without this gate both runs read the same "latest"
    /// deduplication key before either has inserted, so both pass the check and the copy lands
    /// twice. Serialising makes the check and the insert atomic with respect to each other.
    /// </summary>
    private readonly SemaphoreSlim _recordGate = new(1, 1);
    private bool _started;
    private bool _disposed;

    public event EventHandler<ClipboardItem>? ItemRecorded;

    public ClipboardMonitor(ClipboardDatabase database, AppSettings settings) : base("PasterClipboardMonitor")
    {
        _database = database;
        _settings = settings;
    }

    public void Start()
    {
        if (_started)
        {
            return;
        }

        Create();
        NativeMethods.AddClipboardFormatListener(Hwnd);
        _started = true;
    }

    protected override IntPtr HandleMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam)
    {
        if (message == NativeMethods.WmClipboardUpdate)
        {
            _ = RecordCurrentClipboardAsync();
            return IntPtr.Zero;
        }

        return NativeMethods.DefWindowProc(hwnd, message, wParam, lParam);
    }

    private async Task RecordCurrentClipboardAsync()
    {
        try
        {
            await _recordGate.WaitAsync();
        }
        catch (ObjectDisposedException)
        {
            return;
        }

        try
        {
            await RecordCurrentClipboardCoreAsync();
        }
        catch (Exception ex)
        {
            AppLog.Error("Failed to record the clipboard.", ex);
        }
        finally
        {
            if (!_disposed)
            {
                _recordGate.Release();
            }
        }
    }

    private async Task RecordCurrentClipboardCoreAsync()
    {
        if (ClipboardSelfChangeGuard.ConsumeIfSelfWrite())
        {
            return;
        }

        var sourceWindow = NativeMethods.GetForegroundWindow();
        var sourcePath = NativeMethods.GetProcessPathFromWindow(sourceWindow);
        if (_settings.IsExcluded(sourcePath))
        {
            return;
        }

        ClipboardItem? item;
        try
        {
            item = await BuildItemAsync(sourcePath);
        }
        catch (Exception ex)
        {
            AppLog.Error("Failed to read clipboard content.", ex);
            return;
        }

        if (item is null)
        {
            return;
        }

        var latestKey = await _database.GetLatestDeduplicationKeyAsync();
        if (latestKey == item.DeduplicationKey)
        {
            return;
        }

        await _database.AddAsync(item);
        await _database.EnforceHistoryLimitAsync(_settings.HistoryLimit);
        ItemRecorded?.Invoke(this, item);
    }

    private static async Task<ClipboardItem?> BuildItemAsync(string? sourcePath)
    {
        var content = Clipboard.GetContent();
        var sourceName = string.IsNullOrWhiteSpace(sourcePath) ? null : Path.GetFileNameWithoutExtension(sourcePath);

        if (content.Contains(StandardDataFormats.Bitmap))
        {
            var bitmap = await content.GetBitmapAsync();
            var bytes = await ReadStreamAsync(await bitmap.OpenReadAsync());
            var stored = await ImageUtils.CompressForStorageAsync(bytes);
            var thumbnail = await ImageUtils.CreateThumbnailAsync(stored);
            return new ClipboardItem
            {
                Type = ClipboardItemType.Image,
                ImageData = stored,
                ThumbnailData = thumbnail,
                SourceAppName = sourceName,
                SourceProcessPath = sourcePath
            };
        }

        if (content.Contains(StandardDataFormats.StorageItems))
        {
            var items = await content.GetStorageItemsAsync();
            var paths = items.Select(x => x.Path).Where(x => !string.IsNullOrWhiteSpace(x)).ToArray();
            if (paths.Length > 0)
            {
                return new ClipboardItem
                {
                    Type = ClipboardItemType.File,
                    Text = string.Join(Environment.NewLine, paths),
                    FilePathList = string.Join(Environment.NewLine, paths),
                    SourceAppName = sourceName,
                    SourceProcessPath = sourcePath
                };
            }
        }

        var text = content.Contains(StandardDataFormats.Text) ? await content.GetTextAsync() : null;
        if (!string.IsNullOrWhiteSpace(text) && IsWebUrl(text))
        {
            return new ClipboardItem
            {
                Type = ClipboardItemType.Url,
                Text = text,
                Url = text.Trim(),
                SourceAppName = sourceName,
                SourceProcessPath = sourcePath
            };
        }

        if (content.Contains(StandardDataFormats.Rtf) && !string.IsNullOrWhiteSpace(text))
        {
            var rtf = await content.GetRtfAsync();
            return new ClipboardItem
            {
                Type = ClipboardItemType.RichText,
                Text = SafeText(text),
                RtfData = System.Text.Encoding.UTF8.GetBytes(rtf),
                SourceAppName = sourceName,
                SourceProcessPath = sourcePath
            };
        }

        if (content.Contains(StandardDataFormats.Html) && !string.IsNullOrWhiteSpace(text))
        {
            return new ClipboardItem
            {
                Type = ClipboardItemType.RichText,
                Text = SafeText(text),
                Html = await content.GetHtmlFormatAsync(),
                SourceAppName = sourceName,
                SourceProcessPath = sourcePath
            };
        }

        if (!string.IsNullOrWhiteSpace(text))
        {
            return new ClipboardItem
            {
                Type = ClipboardItemType.Text,
                Text = SafeText(text),
                SourceAppName = sourceName,
                SourceProcessPath = sourcePath
            };
        }

        return null;
    }

    private static async Task<byte[]> ReadStreamAsync(IRandomAccessStreamWithContentType stream)
    {
        using var input = stream;
        var length = checked((int)Math.Min(input.Size, int.MaxValue));
        var bytes = new byte[length];
        using var reader = new DataReader(input.GetInputStreamAt(0));
        await reader.LoadAsync((uint)length);
        reader.ReadBytes(bytes);
        return bytes;
    }

    private static string SafeText(string text) =>
        text.Length > MaxTextLength ? text[..MaxTextLength] : text;

    private static bool IsWebUrl(string text)
    {
        var trimmed = text.Trim();
        return !trimmed.Contains(' ') &&
               !trimmed.Contains('\n') &&
               Uri.TryCreate(trimmed, UriKind.Absolute, out var uri) &&
               (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps) &&
               !string.IsNullOrWhiteSpace(uri.Host);
    }

    public override void Dispose()
    {
        if (_started && Hwnd != IntPtr.Zero)
        {
            NativeMethods.RemoveClipboardFormatListener(Hwnd);
        }

        _disposed = true;
        _recordGate.Dispose();
        base.Dispose();
    }
}
