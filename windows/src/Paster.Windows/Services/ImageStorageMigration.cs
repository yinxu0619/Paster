using Paster.Windows.Utilities;

namespace Paster.Windows.Services;

/// <summary>
/// Rewrites image rows captured before thumbnails were downscaled, where ThumbnailData was a
/// verbatim copy of the full-size screenshot. Runs on a background thread and is safe to abandon
/// halfway: each row is committed independently and the query re-selects whatever is left.
/// </summary>
public static class ImageStorageMigration
{
    private const int ThumbnailByteThreshold = 200 * 1024;
    private static readonly TimeSpan StartDelay = TimeSpan.FromSeconds(3);

    public static void RunInBackground(ClipboardDatabase database) => _ = Task.Run(() => RunAsync(database));

    private static async Task RunAsync(ClipboardDatabase database)
    {
        try
        {
            // Let startup, the first history load and the clipboard hook settle first.
            await Task.Delay(StartDelay);

            var ids = await database.GetOversizedImageRowIdsAsync(ThumbnailByteThreshold);
            if (ids.Count == 0)
            {
                AppLog.Info("Image storage migration: no oversized image rows found.");
                return;
            }

            var sizeBefore = FileSize(database.DatabasePath);
            AppLog.Info($"Image storage migration: {ids.Count} row(s) queued. Database is {sizeBefore / 1024 / 1024} MB.");

            var rewritten = 0;
            foreach (var id in ids)
            {
                try
                {
                    var original = await database.GetImageDataAsync(id);
                    if (original is not { Length: > 0 })
                    {
                        continue;
                    }

                    var stored = await ImageUtils.CompressForStorageAsync(original);
                    var thumbnail = await ImageUtils.CreateThumbnailAsync(stored);
                    await database.UpdateImageDataAsync(id, stored, thumbnail);
                    rewritten++;

                    if (rewritten % 25 == 0)
                    {
                        AppLog.Info($"Image storage migration: {rewritten}/{ids.Count} rows rewritten.");
                    }
                }
                catch (Exception ex)
                {
                    AppLog.Error($"Image storage migration failed for row {id}.", ex);
                }

                // Keep the migration well behind interactive work.
                await Task.Delay(15);
            }

            if (rewritten > 0)
            {
                await database.VacuumAsync();
            }

            var sizeAfter = FileSize(database.DatabasePath);
            AppLog.Info(
                $"Image storage migration complete. {rewritten}/{ids.Count} rows rewritten, " +
                $"database {sizeBefore / 1024 / 1024} MB -> {sizeAfter / 1024 / 1024} MB.");
        }
        catch (Exception ex)
        {
            AppLog.Error("Image storage migration aborted.", ex);
        }
    }

    private static long FileSize(string path)
    {
        try
        {
            return new FileInfo(path).Exists ? new FileInfo(path).Length : 0;
        }
        catch
        {
            return 0;
        }
    }
}
