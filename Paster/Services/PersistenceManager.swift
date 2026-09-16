import Foundation
import SwiftData

/// A failed open must never delete the user's history. Fall back to a clearly
/// announced, temporary in-memory session while leaving the original store intact.
@MainActor
final class PersistenceManager {
    static let shared = PersistenceManager()

    /// 全部持久化实体。测试与探针也用这份定义，避免各处 Schema 漂移。
    static let schema = Schema([ClipboardItem.self, ClipboardImage.self])

    let container: ModelContainer
    let storageError: String?
    let storeURL: URL

    init(configuration: ModelConfiguration? = nil) {
        let schema = Self.schema
        let configuration = configuration ?? ModelConfiguration("PasterStore", schema: schema, isStoredInMemoryOnly: false)
        storeURL = configuration.url
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
            storageError = nil
        } catch {
            storageError = error.localizedDescription
            NSLog("[Paster] Cannot open history; keeping the original store: \(error)")
            do {
                let temporary = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                container = try ModelContainer(for: schema, configurations: [temporary])
            } catch {
                fatalError("Cannot create temporary clipboard storage: \(error)")
            }
        }
        if storageError == nil {
            migrateLegacyImages()
            regenerateOversizedThumbnails()
        }
    }

    var mainContext: ModelContext { container.mainContext }

    /// 把旧版本存在 `ClipboardItem` 行内的原图分批搬到 `ClipboardImage`，并清掉失去
    /// 所属记录的孤儿图片。幂等：每一批独立保存，中途退出下次启动接着搬；无旧数据时
    /// 只花一次计数查询。分批是为了避免一次把全部原图（可达数百 MB）读进内存。
    ///
    /// 返回搬迁的记录数，供测试与日志使用。
    @discardableResult
    func migrateLegacyImages(batchSize: Int = 8) -> Int {
        let context = mainContext
        var pending = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.legacyImageData != nil })
        pending.fetchLimit = batchSize
        let total = (try? context.fetchCount(FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.legacyImageData != nil }))) ?? 0
        var moved = 0
        // 每批至少搬走一条，批数有上限，保证不会因为保存没生效而空转。
        var remainingBatches = total / max(batchSize, 1) + 1
        while moved < total, remainingBatches > 0,
              let batch = try? context.fetch(pending), !batch.isEmpty {
            remainingBatches -= 1
            for item in batch {
                // 经计算属性赋值：建立关系并清空旧列。
                item.imageData = item.legacyImageData
            }
            do {
                try context.save()
                moved += batch.count
            } catch {
                NSLog("[Paster] 搬迁旧图片失败，下次启动重试: \(error.localizedDescription)")
                context.rollback()
                break
            }
        }
        if moved > 0 {
            NSLog("[Paster] 已把 \(moved) 张原图搬迁到独立存储")
        }
        removeOrphanImages(in: context)
        return moved
    }

    /// 用原图重新生成旧版本留下的过大缩略图（早期按 Retina 点数生成的两倍 PNG 可达数百 KB，
    /// 列表每次刷新都要整体加载）。只有图片类型记录会被拉取；原图按需读取、逐条释放。
    /// 无法重生成的记录（原图缺失或损坏）保持原样，下次启动会再次尝试，代价只是一次查询。
    ///
    /// 返回重生成的数量。
    @discardableResult
    func regenerateOversizedThumbnails(limitBytes: Int = ImageUtils.oversizedThumbnailBytes) -> Int {
        let context = mainContext
        let imageType = ClipboardItemType.image.rawValue
        var page = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.typeRaw == imageType },
                                                  sortBy: [SortDescriptor(\.createdAt)])
        page.fetchLimit = 8
        var regenerated = 0
        // 分页处理并逐批落盘：一批处理完释放引用，触发过的原图关系随之释放，
        // 峰值内存只有一批原图，而不是全部。
        while let batch = try? context.fetch(page), !batch.isEmpty {
            page.fetchOffset = (page.fetchOffset ?? 0) + batch.count
            for item in batch {
                guard let thumbnail = item.thumbnailData, thumbnail.count > limitBytes,
                      let original = item.imageData,
                      let replacement = ImageUtils.thumbnail(from: original),
                      replacement.count < thumbnail.count else { continue }
                item.thumbnailData = replacement
                regenerated += 1
            }
            guard context.hasChanges else { continue }
            do { try context.save() } catch {
                NSLog("[Paster] 保存重生成的缩略图失败: \(error.localizedDescription)")
                context.rollback()
                break
            }
        }
        if regenerated > 0 {
            NSLog("[Paster] 已重新生成 \(regenerated) 张过大的缩略图")
        }
        return regenerated
    }

    /// 删除没有所属记录的图片行（例如批量清空历史时未级联到的图片）。
    private func removeOrphanImages(in context: ModelContext) {
        do {
            let orphans = try context.fetch(FetchDescriptor<ClipboardImage>(predicate: #Predicate { $0.item == nil }))
            guard !orphans.isEmpty else { return }
            for orphan in orphans { context.delete(orphan) }
            try context.save()
            NSLog("[Paster] 已清理 \(orphans.count) 张孤儿图片")
        } catch {
            NSLog("[Paster] 清理孤儿图片失败: \(error.localizedDescription)")
            context.rollback()
        }
    }
}
