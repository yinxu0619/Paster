using Microsoft.Data.Sqlite;
using Paster.Windows.Models;

namespace Paster.Windows.Services;

public sealed class ClipboardDatabase
{
    /// <summary>
    /// Columns loaded for the history list. ImageData / RtfData / Html are deliberately absent:
    /// the list is rebuilt on every search keystroke, and those blobs are only needed by the one
    /// item the user actually acts on (see <see cref="GetFullItemAsync"/>). ThumbnailData stays
    /// because MainWindow.CreatePreview renders image cards from it.
    /// </summary>
    private const string ListColumns =
        "Id, Type, Text, ThumbnailData, FilePathList, Url, SourceAppName, SourceProcessPath, IsPinned, PinnedAt, CreatedAt";

    /// <summary>
    /// The single definition of history ordering. <see cref="DisplayOrder"/> mirrors it for
    /// in-memory inserts, so the two cannot drift apart.
    /// </summary>
    private const string OrderByClause =
        "ORDER BY IsPinned DESC, COALESCE(PinnedAt, CreatedAt) DESC, CreatedAt DESC";

    private const string KeywordFilter =
        "(Text LIKE $keyword OR Url LIKE $keyword OR FilePathList LIKE $keyword OR SourceAppName LIKE $keyword)";

    /// <summary>
    /// In-memory equivalent of <see cref="OrderByClause"/>, used when the view model repositions a
    /// single item locally instead of re-querying.
    /// </summary>
    public static readonly IComparer<ClipboardItem> DisplayOrder = Comparer<ClipboardItem>.Create((left, right) =>
    {
        var pinned = right.IsPinned.CompareTo(left.IsPinned);
        if (pinned != 0)
        {
            return pinned;
        }

        var rank = (right.PinnedAt ?? right.CreatedAt).CompareTo(left.PinnedAt ?? left.CreatedAt);
        return rank != 0 ? rank : right.CreatedAt.CompareTo(left.CreatedAt);
    });

    private readonly string _connectionString;

    public ClipboardDatabase()
    {
        var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Paster.Windows");
        Directory.CreateDirectory(root);
        DatabasePath = Path.Combine(root, "clipboard.db");
        _connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = DatabasePath
        }.ToString();
    }

    public string DatabasePath { get; }

    public async Task InitializeAsync()
    {
        await using var connection = OpenConnection();
        var command = connection.CreateCommand();
        // WAL keeps the background image migration from blocking history reads.
        command.CommandText = """
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS ClipboardItems (
                Id TEXT PRIMARY KEY,
                Type INTEGER NOT NULL,
                Text TEXT NULL,
                Html TEXT NULL,
                RtfData BLOB NULL,
                ImageData BLOB NULL,
                ThumbnailData BLOB NULL,
                FilePathList TEXT NULL,
                Url TEXT NULL,
                SourceAppName TEXT NULL,
                SourceProcessPath TEXT NULL,
                IsPinned INTEGER NOT NULL,
                PinnedAt TEXT NULL,
                CreatedAt TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS IX_ClipboardItems_CreatedAt ON ClipboardItems(CreatedAt DESC);
            CREATE INDEX IF NOT EXISTS IX_ClipboardItems_IsPinned ON ClipboardItems(IsPinned, PinnedAt DESC);
            """;
        await command.ExecuteNonQueryAsync();
    }

    /// <summary>
    /// Loads the history list. Pinned items are always included; unpinned items are capped at
    /// <paramref name="limit"/>, matching enforceHistoryLimit() in the macOS ClipboardMonitor.
    /// </summary>
    public async Task<IReadOnlyList<ClipboardItem>> GetItemsAsync(
        string? keyword = null,
        int limit = 0,
        CancellationToken cancellationToken = default)
    {
        await using var connection = OpenConnection();
        var command = connection.CreateCommand();
        var hasKeyword = !string.IsNullOrWhiteSpace(keyword);
        var filter = hasKeyword ? $"AND {KeywordFilter}" : string.Empty;

        if (limit > 0)
        {
            command.CommandText = $"""
                SELECT {ListColumns} FROM (
                    SELECT {ListColumns} FROM ClipboardItems WHERE IsPinned = 1 {filter}
                    UNION ALL
                    SELECT * FROM (
                        SELECT {ListColumns} FROM ClipboardItems WHERE IsPinned = 0 {filter}
                        ORDER BY CreatedAt DESC
                        LIMIT $limit
                    )
                )
                {OrderByClause}
                """;
            command.Parameters.AddWithValue("$limit", limit);
        }
        else
        {
            var where = hasKeyword ? $"WHERE {KeywordFilter}" : string.Empty;
            command.CommandText = $"SELECT {ListColumns} FROM ClipboardItems {where} {OrderByClause}";
        }

        if (hasKeyword)
        {
            command.Parameters.AddWithValue("$keyword", $"%{keyword!.Trim()}%");
        }

        var result = new List<ClipboardItem>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            result.Add(ReadListItem(reader));
        }

        return result;
    }

    /// <summary>
    /// Loads every column for a single item. Used to hydrate blobs on the paste path.
    /// </summary>
    public async Task<ClipboardItem?> GetFullItemAsync(Guid id)
    {
        await using var connection = OpenConnection();
        var command = connection.CreateCommand();
        command.CommandText = "SELECT * FROM ClipboardItems WHERE Id = $id LIMIT 1";
        command.Parameters.AddWithValue("$id", id.ToString());
        await using var reader = await command.ExecuteReaderAsync();
        return await reader.ReadAsync() ? ReadItem(reader) : null;
    }

    /// <summary>
    /// Reads just enough of the newest row to compare deduplication keys. Uses length(ImageData)
    /// so a repeated screenshot does not pull a multi-megabyte blob out of the database.
    /// </summary>
    public async Task<string?> GetLatestDeduplicationKeyAsync()
    {
        await using var connection = OpenConnection();
        var command = connection.CreateCommand();
        command.CommandText = """
            SELECT Type, Text, Url, FilePathList, COALESCE(length(ImageData), 0) AS ImageLength
            FROM ClipboardItems
            ORDER BY CreatedAt DESC
            LIMIT 1
            """;
        await using var reader = await command.ExecuteReaderAsync();
        if (!await reader.ReadAsync())
        {
            return null;
        }

        return ClipboardItem.BuildDeduplicationKey(
            (ClipboardItemType)reader.GetInt32(reader.GetOrdinal("Type")),
            GetNullableString(reader, "Text"),
            GetNullableString(reader, "Url"),
            GetNullableString(reader, "FilePathList"),
            reader.GetInt64(reader.GetOrdinal("ImageLength")));
    }

    public async Task AddAsync(ClipboardItem item)
    {
        await using var connection = OpenConnection();
        var command = connection.CreateCommand();
        command.CommandText = """
            INSERT INTO ClipboardItems
            (Id, Type, Text, Html, RtfData, ImageData, ThumbnailData, FilePathList, Url, SourceAppName, SourceProcessPath, IsPinned, PinnedAt, CreatedAt)
            VALUES
            ($id, $type, $text, $html, $rtf, $image, $thumb, $files, $url, $sourceName, $sourcePath, $isPinned, $pinnedAt, $createdAt)
            """;
        BindItem(command, item);
        await command.ExecuteNonQueryAsync();
    }

    public async Task DeleteAsync(Guid id)
    {
        await using var connection = OpenConnection();
        var command = connection.CreateCommand();
        command.CommandText = "DELETE FROM ClipboardItems WHERE Id = $id";
        command.Parameters.AddWithValue("$id", id.ToString());
        await command.ExecuteNonQueryAsync();
    }

    public async Task TogglePinAsync(ClipboardItem item)
    {
        item.IsPinned = !item.IsPinned;
        item.PinnedAt = item.IsPinned ? DateTimeOffset.Now : null;

        await using var connection = OpenConnection();
        var command = connection.CreateCommand();
        command.CommandText = "UPDATE ClipboardItems SET IsPinned = $isPinned, PinnedAt = $pinnedAt WHERE Id = $id";
        command.Parameters.AddWithValue("$id", item.Id.ToString());
        command.Parameters.AddWithValue("$isPinned", item.IsPinned ? 1 : 0);
        command.Parameters.AddWithValue("$pinnedAt", (object?)item.PinnedAt?.ToString("O") ?? DBNull.Value);
        await command.ExecuteNonQueryAsync();
    }

    public async Task ClearAsync()
    {
        await using var connection = OpenConnection();
        var command = connection.CreateCommand();
        command.CommandText = "DELETE FROM ClipboardItems";
        await command.ExecuteNonQueryAsync();
    }

    public async Task EnforceHistoryLimitAsync(int limit)
    {
        if (limit <= 0)
        {
            return;
        }

        await using var connection = OpenConnection();
        var command = connection.CreateCommand();
        command.CommandText = """
            DELETE FROM ClipboardItems
            WHERE IsPinned = 0 AND Id NOT IN (
                SELECT Id FROM ClipboardItems WHERE IsPinned = 0 ORDER BY CreatedAt DESC LIMIT $limit
            )
            """;
        command.Parameters.AddWithValue("$limit", limit);
        await command.ExecuteNonQueryAsync();
    }

    /// <summary>
    /// Image rows written before thumbnails were downscaled, where ThumbnailData is a copy of the
    /// full-size image (or otherwise implausibly large for a preview).
    /// </summary>
    public async Task<IReadOnlyList<Guid>> GetOversizedImageRowIdsAsync(int thumbnailByteThreshold)
    {
        await using var connection = OpenConnection();
        var command = connection.CreateCommand();
        command.CommandText = """
            SELECT Id FROM ClipboardItems
            WHERE Type = $imageType
              AND ImageData IS NOT NULL
              AND (ThumbnailData IS NULL
                   OR length(ThumbnailData) >= length(ImageData)
                   OR length(ThumbnailData) > $threshold)
            ORDER BY CreatedAt DESC
            """;
        command.Parameters.AddWithValue("$imageType", (int)ClipboardItemType.Image);
        command.Parameters.AddWithValue("$threshold", thumbnailByteThreshold);

        var ids = new List<Guid>();
        await using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            if (Guid.TryParse(reader.GetString(0), out var id))
            {
                ids.Add(id);
            }
        }

        return ids;
    }

    public async Task<byte[]?> GetImageDataAsync(Guid id)
    {
        await using var connection = OpenConnection();
        var command = connection.CreateCommand();
        command.CommandText = "SELECT ImageData FROM ClipboardItems WHERE Id = $id LIMIT 1";
        command.Parameters.AddWithValue("$id", id.ToString());
        await using var reader = await command.ExecuteReaderAsync();
        return await reader.ReadAsync() ? GetNullableBytes(reader, "ImageData") : null;
    }

    public async Task UpdateImageDataAsync(Guid id, byte[] imageData, byte[] thumbnailData)
    {
        await using var connection = OpenConnection();
        var command = connection.CreateCommand();
        command.CommandText = "UPDATE ClipboardItems SET ImageData = $image, ThumbnailData = $thumb WHERE Id = $id";
        command.Parameters.AddWithValue("$id", id.ToString());
        command.Parameters.Add("$image", SqliteType.Blob).Value = imageData;
        command.Parameters.Add("$thumb", SqliteType.Blob).Value = thumbnailData;
        await command.ExecuteNonQueryAsync();
    }

    /// <summary>
    /// Reclaims the free pages left behind after shrinking image blobs.
    /// </summary>
    public async Task VacuumAsync()
    {
        await using var connection = OpenConnection();
        var command = connection.CreateCommand();
        command.CommandText = "VACUUM";
        await command.ExecuteNonQueryAsync();
    }

    private SqliteConnection OpenConnection()
    {
        var connection = new SqliteConnection(_connectionString);
        connection.Open();
        return connection;
    }

    private static void BindItem(SqliteCommand command, ClipboardItem item)
    {
        command.Parameters.AddWithValue("$id", item.Id.ToString());
        command.Parameters.AddWithValue("$type", (int)item.Type);
        command.Parameters.AddWithValue("$text", (object?)item.Text ?? DBNull.Value);
        command.Parameters.AddWithValue("$html", (object?)item.Html ?? DBNull.Value);
        command.Parameters.Add("$rtf", SqliteType.Blob).Value = (object?)item.RtfData ?? DBNull.Value;
        command.Parameters.Add("$image", SqliteType.Blob).Value = (object?)item.ImageData ?? DBNull.Value;
        command.Parameters.Add("$thumb", SqliteType.Blob).Value = (object?)item.ThumbnailData ?? DBNull.Value;
        command.Parameters.AddWithValue("$files", (object?)item.FilePathList ?? DBNull.Value);
        command.Parameters.AddWithValue("$url", (object?)item.Url ?? DBNull.Value);
        command.Parameters.AddWithValue("$sourceName", (object?)item.SourceAppName ?? DBNull.Value);
        command.Parameters.AddWithValue("$sourcePath", (object?)item.SourceProcessPath ?? DBNull.Value);
        command.Parameters.AddWithValue("$isPinned", item.IsPinned ? 1 : 0);
        command.Parameters.AddWithValue("$pinnedAt", (object?)item.PinnedAt?.ToString("O") ?? DBNull.Value);
        command.Parameters.AddWithValue("$createdAt", item.CreatedAt.ToString("O"));
    }

    private static ClipboardItem ReadItem(SqliteDataReader reader)
    {
        var item = ReadListItem(reader);
        item.Html = GetNullableString(reader, "Html");
        item.RtfData = GetNullableBytes(reader, "RtfData");
        item.ImageData = GetNullableBytes(reader, "ImageData");
        return item;
    }

    /// <summary>
    /// Reads the columns in <see cref="ListColumns"/>. Html / RtfData / ImageData stay null and
    /// are hydrated on demand.
    /// </summary>
    private static ClipboardItem ReadListItem(SqliteDataReader reader)
    {
        return new ClipboardItem
        {
            Id = Guid.Parse(reader.GetString(reader.GetOrdinal("Id"))),
            Type = (ClipboardItemType)reader.GetInt32(reader.GetOrdinal("Type")),
            Text = GetNullableString(reader, "Text"),
            ThumbnailData = GetNullableBytes(reader, "ThumbnailData"),
            FilePathList = GetNullableString(reader, "FilePathList"),
            Url = GetNullableString(reader, "Url"),
            SourceAppName = GetNullableString(reader, "SourceAppName"),
            SourceProcessPath = GetNullableString(reader, "SourceProcessPath"),
            IsPinned = reader.GetInt32(reader.GetOrdinal("IsPinned")) == 1,
            PinnedAt = ParseDate(GetNullableString(reader, "PinnedAt")),
            CreatedAt = ParseDate(GetNullableString(reader, "CreatedAt")) ?? DateTimeOffset.Now
        };
    }

    private static string? GetNullableString(SqliteDataReader reader, string name)
    {
        var ordinal = reader.GetOrdinal(name);
        return reader.IsDBNull(ordinal) ? null : reader.GetString(ordinal);
    }

    private static byte[]? GetNullableBytes(SqliteDataReader reader, string name)
    {
        var ordinal = reader.GetOrdinal(name);
        return reader.IsDBNull(ordinal) ? null : (byte[])reader.GetValue(ordinal);
    }

    private static DateTimeOffset? ParseDate(string? raw) =>
        DateTimeOffset.TryParse(raw, out var value) ? value : null;
}
