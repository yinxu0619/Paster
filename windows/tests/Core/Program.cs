using Microsoft.Data.Sqlite;
using Paster.Windows.Models;
using Paster.Windows.Services;

var checks = 0;
void Check(bool condition, string message)
{
    if (!condition) { throw new Exception(message); }
    checks++;
}
var root = Path.Combine(Path.GetTempPath(), "PasterRegression-" + Guid.NewGuid());
Directory.CreateDirectory(root);
try
{
    var a = new ClipboardItem { Type = ClipboardItemType.Image, ImageData = [1, 2, 3, 4] };
    var b = new ClipboardItem { Type = ClipboardItemType.Image, ImageData = [4, 3, 2, 1] };
    Check(a.DeduplicationKey != b.DeduplicationKey, "Equal byte lengths do not imply equal images");
    Check(a.DeduplicationKey == new ClipboardItem { Type = ClipboardItemType.Image, ImageData = [1, 2, 3, 4] }.DeduplicationKey,
        "Repeated images must deduplicate");
    var plain = new ClipboardItem { Type = ClipboardItemType.RichText, Text = "hello", Html = "hello" };
    var bold = new ClipboardItem { Type = ClipboardItemType.RichText, Text = "hello", Html = "<b>hello</b>" };
    Check(plain.DeduplicationKey != bold.DeduplicationKey, "HTML formatting must participate in deduplication");
    plain.RtfData = [1, 2];
    bold.Html = plain.Html;
    bold.RtfData = [2, 1];
    Check(plain.DeduplicationKey != bold.DeduplicationKey, "RTF formatting must participate in deduplication");

    var settingsPath = Path.Combine(root, "settings.json");
    var settings = AppSettings.Load(settingsPath);
    settings.PanelPosition = PanelPosition.Cursor;
    settings.Save();
    Check(AppSettings.Load(settingsPath).PanelPosition == PanelPosition.Cursor, "Cursor setting survives restart");

    var db = new ClipboardDatabase(Path.Combine(root, "clipboard.db"));
    await db.InitializeAsync();
    await db.AddAsync(a);
    Check(await db.GetLatestDeduplicationKeyAsync() == a.DeduplicationKey, "Persisted fingerprint matches capture");
    await db.AddAsync(b);
    Check((await db.GetItemsAsync()).Count == 2, "Both different equal-sized images remain in history");
    Check((await db.GetItemsAsync()).All(x => x.ImageData is null), "List query must not load original image blobs");
    Check((await db.GetFullItemAsync(a.Id))!.ImageData!.SequenceEqual(a.ImageData!), "Paste hydration preserves original data");

    // Reopen a legacy schema with no digest column and verify the additive migration preserves rows.
    using (var connection = new SqliteConnection($"Data Source={db.DatabasePath}"))
    {
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = "ALTER TABLE ClipboardItems DROP COLUMN ContentDigest";
        command.ExecuteNonQuery();
    }
    var reopened = new ClipboardDatabase(db.DatabasePath);
    await reopened.InitializeAsync();
    Check((await reopened.GetItemsAsync()).Count == 2, "Digest migration must preserve legacy history");
    Check(await reopened.GetLatestDeduplicationKeyAsync() == b.DeduplicationKey, "Legacy images are compared by content");
    await reopened.UpdateImageDataAsync(b.Id, [8, 9, 10], [8]);
    Check(await reopened.GetLatestDeduplicationKeyAsync() != b.DeduplicationKey, "Image migration invalidates stale fingerprints");

    await reopened.TogglePinAsync(a);
    await reopened.EnforceHistoryLimitAsync(1);
    Check((await reopened.GetItemsAsync(limit: 1)).Count == 2, "Pinned rows do not consume history quota");
    await reopened.ClearAsync();
    Check((await reopened.GetItemsAsync()).Single().Id == a.Id, "Clear must keep pinned history");
    await reopened.DeleteAsync(a.Id);
    Check((await reopened.GetItemsAsync()).Count == 0, "Delete removes the selected row");

    await Task.WhenAll(Enumerable.Range(0, 20).Select(i => reopened.AddAsync(new ClipboardItem { Text = $"item {i}" })));
    Check((await reopened.GetItemsAsync()).Count == 20, "Concurrent requests serialize without losing records");
    using var cancellation = new CancellationTokenSource();
    cancellation.Cancel();
    try { await reopened.GetItemsAsync(cancellationToken: cancellation.Token); throw new Exception("Cancellation was ignored"); }
    catch (OperationCanceledException) { checks++; }
    Check((await reopened.GetItemsAsync()).Count == 20, "Cancellation releases the database queue");

    // Hold a write lock: issuing another write must return promptly to its UI caller.
    using (var connection = new SqliteConnection($"Data Source={db.DatabasePath}"))
    {
        connection.Open();
        using var transaction = connection.BeginTransaction();
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "UPDATE ClipboardItems SET Text = Text";
        command.ExecuteNonQuery();
        var clock = System.Diagnostics.Stopwatch.StartNew();
        var pending = reopened.AddAsync(new ClipboardItem { Text = "after lock" });
        Check(clock.ElapsedMilliseconds < 500, "Database lock waits must not block the calling thread");
        await Task.Delay(100);
        Check(!pending.IsCompleted, "Write really waits for the database lock");
        transaction.Commit();
        await pending;
    }
    Console.WriteLine($"PASS: {checks} Windows core regression checks");
}
finally
{
    SqliteConnection.ClearAllPools();
    Directory.Delete(root, recursive: true);
}
