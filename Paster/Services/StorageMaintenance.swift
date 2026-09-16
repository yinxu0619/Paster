import Foundation
import SwiftData
import SQLite3

/// 存储占用统计，供设置页展示。
struct StorageStats: Equatable {
    /// 数据库文件大小（含 WAL）。
    var fileBytes: Int
    /// SQLite 空闲页占用，VACUUM 后可回收的下限。
    var reclaimableBytes: Int
    var itemCount: Int
    var imageCount: Int
    /// 原图总字节数。
    var imageBytes: Int
    /// 缩略图总字节数。
    var thumbnailBytes: Int
}

/// 数据库体积维护：统计与 VACUUM。
///
/// SwiftData 没有回收空间的接口，删除记录后 SQLite 只把页面放进空闲列表，文件不会缩小。
/// 这里用独立的 SQLite 连接直接操作同一个文件：VACUUM 在容器打开时也能安全执行
/// （SQLite 对 schema 变化会让 Core Data 自动重新准备语句），实测整理后读写与重开均正常。
extension PersistenceManager {
    /// 自动整理阈值：空闲空间同时达到这两个条件才在启动时 VACUUM。
    static let autoCompactMinimumBytes = 20 * 1_048_576
    static let autoCompactMinimumRatio = 0.10

    /// 当前存储统计；临时（内存）存储或读取失败时返回 nil。
    func storageStats() -> StorageStats? {
        guard storageError == nil, let db = SQLiteConnection(url: storeURL, readOnly: true) else { return nil }
        let pageSize = db.scalar("PRAGMA page_size") ?? 0
        let freePages = db.scalar("PRAGMA freelist_count") ?? 0
        let context = mainContext
        let itemCount = (try? context.fetchCount(FetchDescriptor<ClipboardItem>())) ?? 0
        let imageCount = (try? context.fetchCount(FetchDescriptor<ClipboardImage>())) ?? 0
        // 字节合计走 SQL：经 SwiftData 求和要把全部原图读进内存。
        // 表名 / 列名沿用 Core Data 的 Z 前缀约定，表不存在时得到 0。
        let imageBytes = db.scalar("SELECT COALESCE(SUM(LENGTH(ZDATA)), 0) FROM ZCLIPBOARDIMAGE") ?? 0
        let thumbnailBytes = db.scalar("SELECT COALESCE(SUM(LENGTH(ZTHUMBNAILDATA)), 0) FROM ZCLIPBOARDITEM") ?? 0
        return StorageStats(fileBytes: Self.fileSize(storeURL) + Self.fileSize(storeURL.appendingPathExtension("wal")),
                            reclaimableBytes: freePages * pageSize,
                            itemCount: itemCount, imageCount: imageCount,
                            imageBytes: imageBytes, thumbnailBytes: thumbnailBytes)
    }

    /// 执行 VACUUM 回收空闲空间，返回文件缩小的字节数；失败返回 nil。
    @discardableResult
    func compactStorage() -> Int? {
        guard storageError == nil else { return nil }
        // 先把未保存的改动落盘，避免 VACUUM 等待主上下文的事务。
        if mainContext.hasChanges { try? mainContext.save() }
        let before = Self.fileSize(storeURL) + Self.fileSize(storeURL.appendingPathExtension("wal"))
        guard let db = SQLiteConnection(url: storeURL, readOnly: false) else { return nil }
        // 5 秒等待窗口，覆盖后台监听器恰好在写入的情况。
        db.busyTimeout(milliseconds: 5_000)
        guard db.execute("VACUUM") else {
            NSLog("[Paster] 整理存储失败: \(db.lastError)")
            return nil
        }
        // WAL 模式下 VACUUM 先把整库写进 WAL；不截断的话主文件缩了、WAL 却胀起来，白忙一场。
        _ = db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        let after = Self.fileSize(storeURL) + Self.fileSize(storeURL.appendingPathExtension("wal"))
        let freed = max(0, before - after)
        NSLog("[Paster] 已整理存储，释放 \(freed / 1_048_576) MB")
        return freed
    }

    /// 启动时空闲空间明显偏多才整理，避免每次启动都重写整个文件。
    func compactStorageIfWorthwhile() {
        guard let stats = storageStats(), stats.fileBytes > 0 else { return }
        let ratio = Double(stats.reclaimableBytes) / Double(stats.fileBytes)
        guard stats.reclaimableBytes >= Self.autoCompactMinimumBytes,
              ratio >= Self.autoCompactMinimumRatio else { return }
        compactStorage()
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}

extension ClipboardItem {
    /// 读取原图但不把它留在主上下文里。
    ///
    /// 经 `imageData` 触发关系后，原图会一直挂在记录对象上直到应用退出；连续预览 / 粘贴
    /// 几张大图内存就会一路上涨。这里用一个临时 `ModelContext` 读取，返回后上下文释放，
    /// 原图随之释放。尚未插入上下文的记录直接返回内存中的数据。
    func detachedImageData() -> Data? {
        guard let container = modelContext?.container else { return imageData }
        let scratch = ModelContext(container)
        scratch.autosaveEnabled = false
        let itemID = id
        var descriptor = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.id == itemID })
        descriptor.fetchLimit = 1
        guard let copy = try? scratch.fetch(descriptor).first else { return imageData }
        return copy.imageData
    }
}

/// 极简的 SQLite 连接封装，只用于维护性操作。
final class SQLiteConnection {
    private var db: OpaquePointer?

    init?(url: URL, readOnly: Bool) {
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, db != nil else {
            sqlite3_close(db)
            return nil
        }
    }

    deinit { sqlite3_close(db) }

    var lastError: String { String(cString: sqlite3_errmsg(db)) }

    func busyTimeout(milliseconds: Int32) {
        sqlite3_busy_timeout(db, milliseconds)
    }

    /// 执行单条语句，成功返回 true。
    func execute(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    /// 取查询首行首列的整数；语句失败（例如表不存在）返回 nil。
    func scalar(_ sql: String) -> Int? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
