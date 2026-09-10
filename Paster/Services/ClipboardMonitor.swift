import AppKit
import SwiftData

/// 后台实时监听系统剪贴板变化。
///
/// 通过轮询 `NSPasteboard.general.changeCount` 检测变化（macOS 没有公开的剪贴板变化通知）。
/// 第 2 轮在第 1 轮文本监听基础上「扩展」图片、文件、URL、富文本识别，并记录来源应用。
@MainActor
final class ClipboardMonitor {
    static let historyClearedNotification = Notification.Name("PasterHistoryCleared")
    private let context: ModelContext
    private let settings: AppSettings
    private var timer: Timer?
    private let processingQueue = DispatchQueue(label: "Paster.clipboardProcessing", qos: .userInitiated)
    private var previousBundleID: String?
    private var generation = UUID()
    private var lastChangeCount: Int

    /// 由本应用自己写回剪贴板时记录的 changeCount，避免把「重新复制/粘贴」操作再次记入历史。
    private var ignoredChangeCount: Int?

    /// 单条文本的最大记录长度，超长截断以防异常内容拖垮存储（第 4 轮容错）。
    private let maxTextLength = 1_000_000

    init(context: ModelContext, settings: AppSettings) {
        self.context = context
        self.settings = settings
        self.lastChangeCount = NSPasteboard.general.changeCount
        self.previousBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// 启动轮询监听。
    func start() {
        stop()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(applicationActivated),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(historyCleared),
            name: Self.historyClearedNotification, object: nil)
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
        generation = UUID()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func historyCleared() { generation = UUID() }

    @objc private func applicationActivated(_ notification: Notification) {
        // Drain a pending copy at the app boundary, before forgetting the previous source.
        poll(source: notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
    }

    /// 标记一次由本应用主动写入剪贴板的变化，使其不被记录为新历史。
    func markSelfCopy(changeCount: Int) {
        ignoredChangeCount = changeCount
        lastChangeCount = changeCount
    }

    private func poll() { poll(source: NSWorkspace.shared.frontmostApplication) }

    private func poll(source: NSRunningApplication?) {
        let pasteboard = NSPasteboard.general
        let current = pasteboard.changeCount
        let previous = previousBundleID
        previousBundleID = source?.bundleIdentifier
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        if let ignored = ignoredChangeCount, ignored == current {
            ignoredChangeCount = nil
            return
        }

        // A copy observed across an excluded-app transition is ambiguous: discard it.
        guard !Self.shouldSkipCopy(previousBundleID: previous, currentBundleID: source?.bundleIdentifier,
                                  excluded: Set(settings.excludedBundleIDs)) else { return }
        recordContent(from: pasteboard, source: source)
    }

    static func shouldSkipCopy(previousBundleID: String?, currentBundleID: String?, excluded: Set<String>) -> Bool {
        [previousBundleID, currentBundleID].compactMap { $0 }.contains { excluded.contains($0) }
    }

    /// 解析并记录当前剪贴板内容。
    /// 优先级：图片 > 文件 > 网页链接 > 富文本 > 纯文本。
    private func recordContent(from pasteboard: NSPasteboard, source: NSRunningApplication?) {
        let appName = source?.localizedName
        let bundleID = source?.bundleIdentifier

        let declaredSource = pasteboard.string(forType: NSPasteboard.PasteboardType("org.nspasteboard.source"))
        guard !Self.hasPrivateContent(types: pasteboard.types ?? []),
              !settings.isExcluded(bundleID: bundleID),
              !settings.isExcluded(bundleID: declaredSource) else { return }

        // Snapshot the bytes on the pasteboard thread. Decode and encode on a serial worker,
        // preserving capture order even when a large image is followed by a short text copy.
        guard let snapshot = buildItem(from: pasteboard, appName: appName, bundleID: bundleID) else { return }
        let captureGeneration = generation
        processingQueue.async { [weak self] in
            var snapshot = snapshot
            if snapshot.type == .image {
                guard let raw = snapshot.imageData,
                      let processed = ImageUtils.processForStorage(raw) else { return }
                snapshot.imageData = processed.image
                snapshot.thumbnailData = processed.thumbnail
            }
            if snapshot.type == .image {
                snapshot.digest = "image:" + ClipboardItem.digest([snapshot.imageData ?? Data()])
            } else if snapshot.type == .richText {
                snapshot.digest = "richText:" + ClipboardItem.digest([Data((snapshot.text ?? "").utf8), snapshot.rtfData ?? Data()])
            }
            let ready = snapshot
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == captureGeneration else { return }
                self.persist(ready)
            }
        }
    }

    // https://nspasteboard.org — marker presence matters even with an empty payload.
    static func hasPrivateContent(types: [NSPasteboard.PasteboardType]) -> Bool {
        let ignored: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
            "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword",
            "de.petermaurer.TransientPasteboardType", "com.typeit4me.clipping", "Pasteboard generator type"]
        return types.contains { ignored.contains($0.rawValue) }
    }

    private func persist(_ snapshot: ClipboardSnapshot) {
        // Settings may change while image processing is in flight.
        guard !settings.isExcluded(bundleID: snapshot.sourceBundleID) else { return }
        let item = ClipboardItem(type: snapshot.type, text: snapshot.text, rtfData: snapshot.rtfData,
            imageData: snapshot.imageData, thumbnailData: snapshot.thumbnailData,
            fileURLString: snapshot.fileURLString, urlString: snapshot.urlString,
            sourceAppName: snapshot.sourceAppName, sourceBundleID: snapshot.sourceBundleID,
            createdAt: snapshot.createdAt)
        item.contentDigest = snapshot.digest ?? item.computedDeduplicationKey
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
        descriptor.fetchOffset = limit
        descriptor.propertiesToFetch = [\.createdAt]
        guard let unpinned = try? context.fetch(descriptor), !unpinned.isEmpty else { return }

        for stale in unpinned {
            context.delete(stale)
        }
        try? context.save()
    }

    private func buildItem(from pasteboard: NSPasteboard,
                           appName: String?,
                           bundleID: String?) -> ClipboardSnapshot? {
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
            return ClipboardSnapshot(type: .url,
                                 text: string,
                                 urlString: string,
                                 sourceAppName: appName,
                                 sourceBundleID: bundleID)
        }

        // 4. 富文本（同时保留纯文本表示）
        if let rtf = pasteboard.data(forType: .rtf), let string {
            return ClipboardSnapshot(type: .richText,
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
            return ClipboardSnapshot(type: .text,
                                 text: safe,
                                 sourceAppName: appName,
                                 sourceBundleID: bundleID)
        }

        return nil
    }

    private func imageItem(from pasteboard: NSPasteboard,
                           appName: String?,
                           bundleID: String?) -> ClipboardSnapshot? {
        guard let type = pasteboard.availableType(from: [.png, .tiff]),
              let data = pasteboard.data(forType: type) else { return nil }
        return ClipboardSnapshot(type: .image, imageData: data,
                                 sourceAppName: appName, sourceBundleID: bundleID)
    }

    private func fileItem(from pasteboard: NSPasteboard,
                          appName: String?,
                          bundleID: String?) -> ClipboardSnapshot? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty else {
            return nil
        }
        let joined = urls.map(\.absoluteString).joined(separator: "\n")
        let preview = urls.map(\.path).joined(separator: "\n")
        return ClipboardSnapshot(type: .file,
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

/// Value-only capture payload, never a SwiftData model or AppKit image on the worker.
private struct ClipboardSnapshot: Sendable {
    var type: ClipboardItemType
    var text: String? = nil
    var rtfData: Data? = nil
    var imageData: Data? = nil
    var thumbnailData: Data? = nil
    var fileURLString: String? = nil
    var urlString: String? = nil
    var sourceAppName: String? = nil
    var sourceBundleID: String? = nil
    var createdAt: Date = Date()
    var digest: String? = nil
}
