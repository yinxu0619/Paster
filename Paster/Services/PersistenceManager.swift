import Foundation
import SwiftData

/// SwiftData 持久化容器的统一入口。
///
/// 全应用共享同一个 `ModelContainer`，数据 100% 本地存储，不联网、不上传。
/// 第 4 轮新增：数据损坏时自动删除旧存储并重建，避免应用无法启动。
@MainActor
final class PersistenceManager {
    static let shared = PersistenceManager()

    let container: ModelContainer

    private init() {
        let schema = Schema([ClipboardItem.self])
        let configuration = ModelConfiguration("PasterStore", schema: schema, isStoredInMemoryOnly: false)

        if let created = try? ModelContainer(for: schema, configurations: [configuration]) {
            container = created
            return
        }

        // 容器创建失败（多为存储文件损坏 / 不兼容迁移）：删除旧存储后重建。
        NSLog("[Paster] 检测到数据存储异常，正在尝试修复…")
        Self.destroyStore(at: configuration.url)
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
            NSLog("[Paster] 数据存储已重建。")
        } catch {
            fatalError("无法创建 SwiftData 容器: \(error)")
        }
    }

    /// 主线程使用的上下文。
    var mainContext: ModelContext { container.mainContext }

    /// 删除损坏的 SQLite 存储及其 WAL / SHM 边车文件。
    private static func destroyStore(at url: URL) {
        let fileManager = FileManager.default
        let sidecars = [url,
                        url.appendingPathExtension("wal"),
                        url.appendingPathExtension("shm")]
        // SwiftData 的 url 可能已带扩展名，这里同时尝试同目录下的 -wal / -shm。
        let base = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        let extraSidecars = ["\(base).store-wal", "\(base).store-shm"].map { dir.appendingPathComponent($0) }

        for file in sidecars + extraSidecars where fileManager.fileExists(atPath: file.path) {
            try? fileManager.removeItem(at: file)
        }
    }
}
