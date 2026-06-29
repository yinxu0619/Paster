import AppKit
import SwiftData

/// 后台实时监听系统剪贴板变化。
///
/// 通过轮询 `NSPasteboard.general.changeCount` 检测变化（macOS 没有公开的剪贴板变化通知）。
/// 第 2 轮在第 1 轮文本监听基础上「扩展」图片、文件、URL、富文本识别，并记录来源应用。
@MainActor
final class ClipboardMonitor {
    private let context: ModelContext
    private let settings: AppSettings
    private var timer: Timer?
    private var lastChangeCount: Int

    /// 由本应用自己写回剪贴板时记录的 changeCount，避免把「重新复制/粘贴」操作再次记入历史。
    private var ignoredChangeCount: Int?

    /// 单条文本的最大记录长度，超长截断以防异常内容拖垮存储（第 4 轮容错）。
    private let maxTextLength = 1_000_000

    init(context: ModelContext, settings: AppSettings) {
        self.context = context
        self.settings = settings
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    /// 启动轮询监听。
    func start() {
        stop()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        // 允许系统合并定时器唤醒，降低后台功耗（第 4 轮功耗优化）。
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 停止监听。
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 标记一次由本应用主动写入剪贴板的变化，使其不被记录为新历史。
    func markSelfCopy(changeCount: Int) {
        ignoredChangeCount = changeCount
        lastChangeCount = changeCount
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        if let ignored = ignoredChangeCount, ignored == current {
            ignoredChangeCount = nil
            return
        }

        recordContent(from: pasteboard)
    }

    /// 解析并记录当前剪贴板内容。
    /// 优先级：图片 > 文件 > 网页链接 > 富文本 > 纯文本。
    private func recordContent(from pasteboard: NSPasteboard) {
        let source = NSWorkspace.shared.frontmostApplication
        let appName = source?.localizedName
        let bundleID = source?.bundleIdentifier

        // 隐私：排除应用（如密码管理器）复制的内容不记录。
        if settings.isExcluded(bundleID: bundleID) { return }

        guard let item = buildItem(from: pasteboard, appName: appName, bundleID: bundleID) else {
            return
        }

        // 与最近一条去重，避免相同内容连续入库。
        if let latest = latestItem(), latest.deduplicationKey == item.deduplicationKey {
            return
        }

        // 容错：任何持久化异常都不应让监听崩溃。
        do {
            context.insert(item)
            try context.save()
            enforceHistoryLimit()
        } catch {
            NSLog("[Paster] 记录剪贴板内容失败: \(error.localizedDescription)")
            context.rollback()
        }
    }

    /// 超出历史上限时，删除最旧的未固定记录（固定项不受上限影响）。
    private func enforceHistoryLimit() {
        let limit = settings.historyLimit
        guard limit > 0 else { return }

        var descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.isPinned == false },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.propertiesToFetch = [\.createdAt]
        guard let unpinned = try? context.fetch(descriptor), unpinned.count > limit else { return }

        for stale in unpinned[limit...] {
            context.delete(stale)
        }
        try? context.save()
    }

    private func buildItem(from pasteboard: NSPasteboard,
                           appName: String?,
                           bundleID: String?) -> ClipboardItem? {
        // 1. 图片
        if let item = imageItem(from: pasteboard, appName: appName, bundleID: bundleID) {
            return item
        }
        // 2. 文件
        if let item = fileItem(from: pasteboard, appName: appName, bundleID: bundleID) {
            return item
        }

        let string = pasteboard.string(forType: .string)

        // 3. 网页链接
        if let string, Self.isWebURL(string) {
            return ClipboardItem(type: .url,
                                 text: string,
                                 urlString: string,
                                 sourceAppName: appName,
                                 sourceBundleID: bundleID)
        }

        // 4. 富文本（同时保留纯文本表示）
        if let rtf = pasteboard.data(forType: .rtf), let string {
            return ClipboardItem(type: .richText,
                                 text: string,
                                 rtfData: rtf,
                                 sourceAppName: appName,
                                 sourceBundleID: bundleID)
        }

        // 5. 纯文本
        if let string {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            // 容错：异常超长文本截断，避免占用过多存储与内存。
            let safe = string.count > maxTextLength ? String(string.prefix(maxTextLength)) : string
            return ClipboardItem(type: .text,
                                 text: safe,
                                 sourceAppName: appName,
                                 sourceBundleID: bundleID)
        }

        return nil
    }

    private func imageItem(from pasteboard: NSPasteboard,
                           appName: String?,
                           bundleID: String?) -> ClipboardItem? {
        // 仅当剪贴板含图片类型时处理（避免把文件图标等误判为图片）。
        let imageTypes: [NSPasteboard.PasteboardType] = [.tiff, .png]
        guard pasteboard.availableType(from: imageTypes) != nil,
              let image = NSImage(pasteboard: pasteboard),
              let png = ImageUtils.compressedForStorage(from: image) else {
            return nil
        }
        let thumb = ImageUtils.thumbnailPNG(from: image)
        return ClipboardItem(type: .image,
                             imageData: png,
                             thumbnailData: thumb,
                             sourceAppName: appName,
                             sourceBundleID: bundleID)
    }

    private func fileItem(from pasteboard: NSPasteboard,
                          appName: String?,
                          bundleID: String?) -> ClipboardItem? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty else {
            return nil
        }
        let joined = urls.map(\.absoluteString).joined(separator: "\n")
        let preview = urls.map(\.path).joined(separator: "\n")
        return ClipboardItem(type: .file,
                             text: preview,
                             fileURLString: joined,
                             sourceAppName: appName,
                             sourceBundleID: bundleID)
    }

    private func latestItem() -> ClipboardItem? {
        var descriptor = FetchDescriptor<ClipboardItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// 判断字符串是否为单个 http/https 网页链接。
    static func isWebURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(" "),
              !trimmed.contains("\n"),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased() else {
            return false
        }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }
}
