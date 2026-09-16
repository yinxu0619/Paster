import AppKit

/// 列表缩略图的解码缓存。
///
/// 卡片视图每次重绘都会走一遍 `NSImage(data:)`；键盘移动选中项时所有可见卡片都会重绘，
/// 图片多的横条模式下就是一次次重复解码。这里按记录 UUID 缓存解码后的 `NSImage`，
/// 一条记录一个会话内只解码一次。`NSCache` 在内存紧张时自动淘汰，删除记录留下的
/// 少量残留条目由数量上限兜底。
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 400
    }

    /// 返回缓存的解码图；未命中时解码 `data` 并缓存。`data` 为 nil 或解码失败返回 nil。
    func image(for id: UUID, data: @autoclosure () -> Data?) -> NSImage? {
        let key = id.uuidString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = data(), let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// 某条记录的缩略图被替换后调用。
    func invalidate(_ id: UUID) {
        cache.removeObject(forKey: id.uuidString as NSString)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
