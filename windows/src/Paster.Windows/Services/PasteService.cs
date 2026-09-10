using System.Runtime.InteropServices;
using Paster.Windows.Models;
using Paster.Windows.Native;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Streams;

namespace Paster.Windows.Services;

public sealed class PasteService : IDisposable
{
    private const ushort VkControl = 0x11;
    private const ushort VkV = 0x56;
    private const uint InputKeyboard = 1;
    private const uint KeyEventKeyUp = 0x0002;
    private readonly ClipboardDatabase _database;

    private readonly ForegroundWindowTracker _foreground = new();
    private uint _targetProcess;
    private bool _pasting;
    public IntPtr LastTargetWindow { get; private set; }

    public void CaptureTargetWindow(IntPtr candidate)
    {
        LastTargetWindow = _foreground.Capture(candidate);
        NativeMethods.GetWindowThreadProcessId(LastTargetWindow, out _targetProcess);
    }

    public void Dispose() => _foreground.Dispose();

    public PasteService(ClipboardDatabase database)
    {
        _database = database;
    }

    public async Task CopyAsync(ClipboardItem item, bool plainText = false)
    {
        var package = new DataPackage();
        package.RequestedOperation = DataPackageOperation.Copy;

        if (plainText)
        {
            package.SetText(item.PlainTextRepresentation);
        }
        else
        {
            await FillDataPackageAsync(package, item);
        }

        ClipboardSelfChangeGuard.MarkSelfWrite();
        Clipboard.SetContent(package);
        Clipboard.Flush();
    }

    public async Task PasteAsync(ClipboardItem item, bool plainText = false)
    {
        if (_pasting) { return; }
        _pasting = true;
        var target = LastTargetWindow;
        var targetProcess = _targetProcess;
        try
        {
            await CopyAsync(item, plainText);
            NativeMethods.GetWindowThreadProcessId(target, out var process);
            if (!NativeMethods.IsWindow(target) || process != targetProcess) { return; }
            NativeMethods.ShowWindow(target, NativeMethods.SwShow);
            NativeMethods.SetForegroundWindow(target);
            await Task.Delay(120);
            for (var attempt = 0; attempt < 25 && ModifiersHeld(); attempt++) { await Task.Delay(20); }
            if (NativeMethods.GetForegroundWindow() != target || ModifiersHeld())
            {
                AppLog.Info("Paste cancelled because the target is not focused or shortcut keys are still held. Content remains copied.");
                return;
            }
            SendCtrlV();
        }
        finally { _pasting = false; }
    }

    private static bool ModifiersHeld() => new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C }
        .Any(key => (NativeMethods.GetAsyncKeyState(key) & 0x8000) != 0);

    private async Task FillDataPackageAsync(DataPackage package, ClipboardItem item)
    {
        item = await HydrateAsync(item);

        switch (item.Type)
        {
            case ClipboardItemType.Image when item.ImageData is { Length: > 0 }:
                package.SetBitmap(RandomAccessStreamReference.CreateFromStream(await BytesToStreamAsync(item.ImageData)));
                break;
            case ClipboardItemType.Image:
                AppLog.Error($"Image item {item.Id} has no image data after hydration; pasting its text instead.");
                package.SetText(item.Text ?? item.PlainTextRepresentation);
                break;
            case ClipboardItemType.File when !string.IsNullOrWhiteSpace(item.FilePathList):
                var files = new List<IStorageItem>();
                foreach (var path in item.FilePathList.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
                {
                    try
                    {
                        var localPath = path.Trim();
                        if (Directory.Exists(localPath))
                        {
                            files.Add(await StorageFolder.GetFolderFromPathAsync(localPath));
                        }
                        else
                        {
                            files.Add(await StorageFile.GetFileFromPathAsync(localPath));
                        }
                    }
                    catch
                    {
                        // Missing files are ignored; the text fallback still preserves the copied paths.
                    }
                }
                if (files.Count > 0)
                {
                    package.SetStorageItems(files);
                }
                package.SetText(item.FilePathList);
                break;
            case ClipboardItemType.Url when !string.IsNullOrWhiteSpace(item.Url):
                package.SetText(item.Url);
                package.SetWebLink(new Uri(item.Url));
                break;
            case ClipboardItemType.RichText:
                if (item.RtfData is { Length: > 0 })
                {
                    package.SetRtf(System.Text.Encoding.UTF8.GetString(item.RtfData));
                }
                if (!string.IsNullOrWhiteSpace(item.Html))
                {
                    package.SetHtmlFormat(item.Html);
                }
                package.SetText(item.Text ?? item.PlainTextRepresentation);
                break;
            default:
                package.SetText(item.Text ?? item.PlainTextRepresentation);
                break;
        }
    }

    /// <summary>
    /// List rows are loaded without their blobs, so the item being pasted is re-read in full
    /// here. Everything else in the app keeps working on the lightweight instances.
    /// </summary>
    private async Task<ClipboardItem> HydrateAsync(ClipboardItem item)
    {
        var needsBlobs = item.Type switch
        {
            ClipboardItemType.Image => item.ImageData is not { Length: > 0 },
            ClipboardItemType.RichText => item.RtfData is not { Length: > 0 } && string.IsNullOrEmpty(item.Html),
            _ => false
        };

        if (!needsBlobs)
        {
            return item;
        }

        var full = await _database.GetFullItemAsync(item.Id);
        if (full is null)
        {
            AppLog.Error($"Could not hydrate clipboard item {item.Id} ({item.Type}); it is no longer in the database.");
            return item;
        }

        return full;
    }

    private static async Task<IRandomAccessStream> BytesToStreamAsync(byte[] bytes)
    {
        var stream = new InMemoryRandomAccessStream();
        using var writer = new DataWriter(stream);
        writer.WriteBytes(bytes);
        await writer.StoreAsync();
        await writer.FlushAsync();
        writer.DetachStream();
        stream.Seek(0);
        return stream;
    }

    private static void SendCtrlV()
    {
        var inputs = new[]
        {
            Key(VkControl, false),
            Key(VkV, false),
            Key(VkV, true),
            Key(VkControl, true)
        };
        NativeMethods.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<NativeMethods.Input>());
    }

    private static NativeMethods.Input Key(ushort key, bool up) => new()
    {
        type = InputKeyboard,
        u = new NativeMethods.InputUnion
        {
            ki = new NativeMethods.KeyboardInput
            {
                wVk = key,
                dwFlags = up ? KeyEventKeyUp : 0
            }
        }
    };
}
