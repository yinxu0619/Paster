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
    private readonly SemaphoreSlim _operations = new(1, 1);

    public ClipboardDatabase(string? databasePath = null)
    {
        var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Paster.Windows");
        DatabasePath = databasePath ?? Path.Combine(root, "clipboard.db");
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(DatabasePath))!);
        _connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = DatabasePath
        }.ToString();
    }

    public string DatabasePath { get; }

    private void Initialize()
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
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
        command.ExecuteNonQuery();
        using var columns = connection.CreateCommand();
        columns.CommandText = "PRAGMA table_info(ClipboardItems)";
        using var reader = columns.ExecuteReader();
        var hasDigest = false;
        while (reader.Read()) { hasDigest |= reader.GetString(1) == "ContentDigest"; }
        reader.Close();
        if (!hasDigest)
        {
            using var migration = connection.CreateCommand();
            migration.CommandText = "ALTER TABLE ClipboardItems ADD COLUMN ContentDigest TEXT NULL";
            migration.ExecuteNonQuery();
        }
    }

    /// <summary>
    /// Loads the history list. Pinned items are always included; unpinned items are capped at
    /// <paramref name="limit"/>, matching enforceHistoryLimit() in the macOS ClipboardMonitor.
    /// </summary>
    private IReadOnlyList<ClipboardItem> GetItems(string? keyword = null, int limit = 0, CancellationToken cancellationToken = default)
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
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
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            cancellationToken.ThrowIfCancellationRequested();
            result.Add(ReadListItem(reader));
        }

        return result;
    }

    /// <summary>
    /// Loads every column for a single item. Used to hydrate blobs on the paste path.
    /// </summary>
    private ClipboardItem? GetFullItem(Guid id)
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT * FROM ClipboardItems WHERE Id = $id LIMIT 1";
        command.Parameters.AddWithValue("$id", id.ToString());
        using var reader = command.ExecuteReader();
        return reader.Read() ? ReadItem(reader) : null;
    }

    /// <summary>Old rows are fingerprinted only if they become the newest candidate.</summary>
    private string? GetLatestDeduplicationKey()
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT Id, ContentDigest FROM ClipboardItems ORDER BY CreatedAt DESC LIMIT 1";
        using var reader = command.ExecuteReader();
        if (!reader.Read()) { return null; }
        var id = Guid.Parse(reader.GetString(0));
        if (!reader.IsDBNull(1)) { return reader.GetString(1); }
        reader.Close();
        var item = GetFullItem(id);
        if (item is null) { return null; }
        var digest = item.ComputeDeduplicationKey();
        using var update = connection.CreateCommand();
        update.CommandText = "UPDATE ClipboardItems SET ContentDigest = $digest WHERE Id = $id";
        update.Parameters.AddWithValue("$digest", digest);
        update.Parameters.AddWithValue("$id", id.ToString());
        update.ExecuteNonQuery();
        return digest;
    }

    private void Add(ClipboardItem item)
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = """
            INSERT INTO ClipboardItems
            (Id, Type, Text, Html, RtfData, ImageData, ThumbnailData, FilePathList, Url, SourceAppName, SourceProcessPath, IsPinned, PinnedAt, CreatedAt, ContentDigest)
            VALUES
            ($id, $type, $text, $html, $rtf, $image, $thumb, $files, $url, $sourceName, $sourcePath, $isPinned, $pinnedAt, $createdAt, $digest)
            """;
        BindItem(command, item);
        command.Parameters.AddWithValue("$digest", item.ComputeDeduplicationKey());
        command.ExecuteNonQuery();
    }

    private void Delete(Guid id)
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = "DELETE FROM ClipboardItems WHERE Id = $id";
        command.Parameters.AddWithValue("$id", id.ToString());
        command.ExecuteNonQuery();
    }

    public async Task TogglePinAsync(ClipboardItem item)
    {
        var pinned = !item.IsPinned;
        DateTimeOffset? pinnedAt = pinned ? DateTimeOffset.Now : null;
        var id = item.Id;
        await RunAsync(() => SetPin(id, pinned, pinnedAt));
        // Mutable UI state changes only after the write succeeds, back on the caller's context.
        item.IsPinned = pinned;
        item.PinnedAt = pinnedAt;
    }

    private void SetPin(Guid id, bool pinned, DateTimeOffset? pinnedAt)
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = "UPDATE ClipboardItems SET IsPinned = $isPinned, PinnedAt = $pinnedAt WHERE Id = $id";
        command.Parameters.AddWithValue("$isPinned", pinned ? 1 : 0);
        command.Parameters.AddWithValue("$pinnedAt", (object?)pinnedAt?.ToString("O") ?? DBNull.Value);
        command.Parameters.AddWithValue("$id", id.ToString());
        command.ExecuteNonQuery();
    }

    /// <summary>
    /// Clears the history but keeps pinned rows: pinning is the user's "keep this" marker, so a
    /// clear that discarded pinned items would throw away the entries they deliberately protected.
    /// </summary>
    private void Clear()
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = "DELETE FROM ClipboardItems WHERE IsPinned = 0";
        command.ExecuteNonQuery();
    }

    private void EnforceHistoryLimit(int limit)
    {
        if (limit <= 0)
        {
            return;
        }

        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = """
            DELETE FROM ClipboardItems
            WHERE IsPinned = 0 AND Id NOT IN (
                SELECT Id FROM ClipboardItems WHERE IsPinned = 0 ORDER BY CreatedAt DESC LIMIT $limit
            )
            """;
        command.Parameters.AddWithValue("$limit", limit);
        command.ExecuteNonQuery();
    }

    /// <summary>
    /// Image rows written before thumbnails were downscaled, where ThumbnailData is a copy of the
    /// full-size image (or otherwise implausibly large for a preview).
    /// </summary>
    private IReadOnlyList<Guid> GetOversizedImageRowIds(int thumbnailByteThreshold)
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
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
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            if (Guid.TryParse(reader.GetString(0), out var id))
            {
                ids.Add(id);
            }
        }

        return ids;
    }

    private byte[]? GetImageData(Guid id)
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT ImageData FROM ClipboardItems WHERE Id = $id LIMIT 1";
        command.Parameters.AddWithValue("$id", id.ToString());
        using var reader = command.ExecuteReader();
        return reader.Read() ? GetNullableBytes(reader, "ImageData") : null;
    }

    private void UpdateImageData(Guid id, byte[] imageData, byte[] thumbnailData)
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = "UPDATE ClipboardItems SET ImageData = $image, ThumbnailData = $thumb, ContentDigest = NULL WHERE Id = $id";
        command.Parameters.AddWithValue("$id", id.ToString());
        command.Parameters.Add("$image", SqliteType.Blob).Value = imageData;
        command.Parameters.Add("$thumb", SqliteType.Blob).Value = thumbnailData;
        command.ExecuteNonQuery();
    }

    /// <summary>
    /// Reclaims the free pages left behind after shrinking image blobs.
    /// </summary>
    private void Vacuum()
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = "VACUUM";
        command.ExecuteNonQuery();
    }

    // Microsoft.Data.Sqlite's Async methods perform synchronous I/O. Serialize the work on
    // a worker thread; connection creation, lock waits and row materialization stay off the UI.
    public Task InitializeAsync() =>
        RunAsync(() => Initialize());

    public Task<IReadOnlyList<ClipboardItem>> GetItemsAsync(string? keyword = null, int limit = 0, CancellationToken cancellationToken = default) =>
        RunAsync(() => GetItems(keyword, limit, cancellationToken), cancellationToken);

    public Task<ClipboardItem?> GetFullItemAsync(Guid id) =>
        RunAsync(() => GetFullItem(id));

    public Task<string?> GetLatestDeduplicationKeyAsync() =>
        RunAsync(() => GetLatestDeduplicationKey());

    public Task AddAsync(ClipboardItem item) =>
        RunAsync(() => Add(item));

    public Task DeleteAsync(Guid id) =>
        RunAsync(() => Delete(id));

    public Task ClearAsync() =>
        RunAsync(() => Clear());

    public Task EnforceHistoryLimitAsync(int limit) =>
        RunAsync(() => EnforceHistoryLimit(limit));

    public Task<IReadOnlyList<Guid>> GetOversizedImageRowIdsAsync(int thumbnailByteThreshold) =>
        RunAsync(() => GetOversizedImageRowIds(thumbnailByteThreshold));

    public Task<byte[]?> GetImageDataAsync(Guid id) =>
        RunAsync(() => GetImageData(id));

    public Task UpdateImageDataAsync(Guid id, byte[] imageData, byte[] thumbnailData) =>
        RunAsync(() => UpdateImageData(id, imageData, thumbnailData));

    public Task VacuumAsync() =>
        RunAsync(() => Vacuum());

    private Task RunAsync(Action operation, CancellationToken cancellationToken = default) =>
        RunAsync(() => { operation(); return true; }, cancellationToken);

    private async Task<T> RunAsync<T>(Func<T> operation, CancellationToken cancellationToken = default)
    {
        await _operations.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await Task.Run(operation, cancellationToken).ConfigureAwait(false);
        }
        finally { _operations.Release(); }
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
