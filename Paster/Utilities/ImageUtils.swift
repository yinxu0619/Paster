import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 图片处理工具：PNG 编码、缩放、缩略图与存储压缩。
///
/// 第 2 轮：PNG 编码 + 缩略图。
/// 第 4 轮：新增「存储压缩」——超过最大边长的大图会被等比缩小后再持久化，
/// 降低数据库体积与内存占用。
enum ImageUtils {
    /// 列表缩略图的最大边长（像素）。
    static let thumbnailMaxDimension = 240
    /// 缩略图 JPEG 质量。240 像素的 JPEG 通常只有几十 KB，而同尺寸 PNG 可达数百 KB；
    /// 缩略图只用于列表扫读，透明区域丢失可以接受。
    static let thumbnailJPEGQuality: CGFloat = 0.8
    /// 超过此大小的缩略图视为旧版本生成的过大缩略图，启动时重新生成。
    /// 240 像素 JPEG 远小于此值，重生成后不会再次命中。
    static let oversizedThumbnailBytes = 100_000

    /// ImageIO uses pixel dimensions and has no AppKit/window-server dependency.
    /// Both full storage and preview images are downsampled before decoding.
    static func processForStorage(_ data: Data) -> (image: Data, thumbnail: Data)? {
        guard let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = downsample(source, maxDimension: 1600),
              let thumbnail = downsample(source, maxDimension: thumbnailMaxDimension, format: .jpeg) else { return nil }
        return (image, thumbnail)
    }

    /// 仅从已存储的原图重新生成缩略图（用于替换旧版本生成的过大缩略图）。
    static func thumbnail(from imageData: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return downsample(source, maxDimension: thumbnailMaxDimension, format: .jpeg)
    }

    private static func downsample(_ source: CGImageSource, maxDimension: Int, format: UTType = .png) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, format.identifier as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any]? = format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: thumbnailJPEGQuality] : nil
        CGImageDestinationAddImage(destination, image, properties as CFDictionary?)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// 将 `NSImage` 编码为 PNG 数据。
    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// 生成等比缩略图的 PNG 数据。
    static func thumbnailPNG(from image: NSImage, maxDimension: CGFloat = 240) -> Data? {
        guard let resized = resized(image, maxDimension: maxDimension) else {
            return pngData(from: image)
        }
        return pngData(from: resized)
    }

    /// 用于持久化的图片数据：超过 `maxDimension` 的大图等比缩小，否则原样编码。
    static func compressedForStorage(from image: NSImage, maxDimension: CGFloat = 1600) -> Data? {
        let size = image.size
        guard size.width > maxDimension || size.height > maxDimension,
              let resized = resized(image, maxDimension: maxDimension) else {
            return pngData(from: image)
        }
        return pngData(from: resized)
    }

    /// 等比缩放图片到指定最大边长；若无需缩放返回 nil。
    private static func resized(_ image: NSImage, maxDimension: CGFloat) -> NSImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let scale = min(1, maxDimension / max(size.width, size.height))
        guard scale < 1 else { return nil }

        let target = NSSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let result = NSImage(size: target)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy,
                   fraction: 1.0)
        result.unlockFocus()
        return result
    }
}
