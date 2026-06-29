import AppKit

/// 来源应用图标提供者，按 Bundle ID 缓存图标，避免重复磁盘查询。
@MainActor
final class AppIconProvider {
    static let shared = AppIconProvider()
    private init() {}

    private var cache: [String: NSImage] = [:]

    /// 根据 Bundle ID 获取应用图标；找不到时返回通用占位图标。
    func icon(forBundleID bundleID: String?) -> NSImage {
        guard let bundleID, !bundleID.isEmpty else {
            return Self.placeholder
        }
        if let cached = cache[bundleID] { return cached }

        let workspace = NSWorkspace.shared
        var image: NSImage?
        if let url = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            image = workspace.icon(forFile: url.path)
        }
        let result = image ?? Self.placeholder
        cache[bundleID] = result
        return result
    }

    private static let placeholder: NSImage = {
        NSImage(systemSymbolName: "app.dashed", accessibilityDescription: "未知应用")
            ?? NSImage(size: NSSize(width: 16, height: 16))
    }()
}
