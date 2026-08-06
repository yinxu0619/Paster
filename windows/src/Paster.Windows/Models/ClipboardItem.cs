namespace Paster.Windows.Models;

public sealed class ClipboardItem
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public ClipboardItemType Type { get; set; } = ClipboardItemType.Text;
    public string? Text { get; set; }
    public string? Html { get; set; }
    public byte[]? RtfData { get; set; }
    public byte[]? ImageData { get; set; }
    public byte[]? ThumbnailData { get; set; }
    public string? FilePathList { get; set; }
    public string? Url { get; set; }
    public string? SourceAppName { get; set; }
    public string? SourceProcessPath { get; set; }
    public bool IsPinned { get; set; }
    public DateTimeOffset? PinnedAt { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.Now;

    public string TypeLabel => Type switch
    {
        ClipboardItemType.RichText => "Rich Text",
        ClipboardItemType.Image => "Image",
        ClipboardItemType.File => "File",
        ClipboardItemType.Url => "URL",
        _ => "Text"
    };

    public string PinLabel => IsPinned ? "Pinned" : string.Empty;

    public string CreatedAtDisplay => CreatedAt.ToString("yyyy-MM-dd HH:mm:ss");

    public string PreviewText => Type switch
    {
        ClipboardItemType.Image => "Image",
        ClipboardItemType.File => FileDisplayNames,
        ClipboardItemType.Url => Url ?? Text ?? string.Empty,
        _ => (Text ?? string.Empty).Trim()
    };

    public string PlainTextRepresentation =>
        !string.IsNullOrWhiteSpace(Text) ? Text! :
        !string.IsNullOrWhiteSpace(Url) ? Url! :
        !string.IsNullOrWhiteSpace(FilePathList) ? FilePathList! :
        PreviewText;

    public string DeduplicationKey =>
        BuildDeduplicationKey(Type, Text, Url, FilePathList, ImageData?.Length ?? 0);

    /// <summary>
    /// Builds the key from raw column values so the database can compare against the newest row
    /// using length(ImageData) instead of loading the blob.
    /// </summary>
    public static string BuildDeduplicationKey(
        ClipboardItemType type,
        string? text,
        string? url,
        string? filePathList,
        long imageLength) => type switch
        {
            ClipboardItemType.Image => $"image:{imageLength}",
            ClipboardItemType.File => $"file:{filePathList ?? text ?? string.Empty}",
            _ => $"{type}:{text ?? url ?? string.Empty}"
        };

    private string FileDisplayNames
    {
        get
        {
            var raw = FilePathList ?? Text;
            if (string.IsNullOrWhiteSpace(raw))
            {
                return "File";
            }

            return string.Join(Environment.NewLine,
                raw.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)
                   .Select(path => Path.GetFileName(path.Trim()) is { Length: > 0 } name ? name : path.Trim()));
        }
    }

    public override string ToString()
    {
        var pin = IsPinned ? "[Pinned] " : string.Empty;
        var source = string.IsNullOrWhiteSpace(SourceAppName) ? "Unknown" : SourceAppName;
        var preview = PreviewText.Replace("\r", " ").Replace("\n", " ");
        if (preview.Length > 160)
        {
            preview = preview[..160] + "...";
        }

        return $"{pin}{TypeLabel} - {source}{Environment.NewLine}{preview}{Environment.NewLine}{CreatedAtDisplay}";
    }
}
