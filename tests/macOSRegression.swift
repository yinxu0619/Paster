import AppKit
import SwiftData
import ImageIO

@main
@MainActor
struct MacOSRegression {
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    static func png(red: UInt8, width: Int = 8, height: Int = 8) -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            bitmap.bitmapData![offset] = red
            bitmap.bitmapData![offset + 1] = 0
            bitmap.bitmapData![offset + 2] = 0
            bitmap.bitmapData![offset + 3] = 255
        }
        return bitmap.representation(using: .png, properties: [:])!
    }

    static func checkPanelContentReuse() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 480))
        defer { panel.close() }
        var creations = 0
        func configure(_ layout: PanelLayout, _ size: NSSize) {
            panel.configureContent(layout: layout, size: size) {
                creations += 1
                let controller = NSViewController()
                controller.view = NSView(frame: CGRect(origin: .zero, size: size))
                return controller
            }
        }

        configure(.bar, NSSize(width: 1440, height: 300))
        let barContent = panel.contentViewController
        // Alternate display widths, then change the configured bar height.
        for size in [NSSize(width: 2560, height: 300), NSSize(width: 1440, height: 300),
                     NSSize(width: 1440, height: 400)] {
            configure(.bar, size)
            check(panel.contentViewController === barContent, "Cross-display resizing must retain the warmed controller")
            check(panel.contentView?.frame.size == size, "Reused content must fill the new panel size")
        }
        check(creations == 1, "Geometry changes must not rebuild panel content")

        configure(.vertical, NSSize(width: 360, height: 480))
        check(creations == 2 && panel.contentViewController !== barContent, "Switching layout must replace content")
        let verticalContent = panel.contentViewController
        configure(.vertical, NSSize(width: 360, height: 1000))
        check(panel.contentViewController === verticalContent, "Sidebar resizing must retain vertical content")
        panel.setContentSize(NSSize(width: 420, height: 900))
        configure(.vertical, NSSize(width: 360, height: 1000))
        check(panel.contentView?.frame.size == NSSize(width: 420, height: 900), "Unchanged configuration preserves manual resizing")
        configure(.bar, NSSize(width: 1440, height: 300))
        check(creations == 3, "Returning to bar layout must configure bar content")
        panel.contentViewController = nil
        configure(.bar, NSSize(width: 1440, height: 300))
        check(creations == 4, "Missing content must be recreated even when layout is unchanged")
    }

    static func main() throws {
        checkPanelContentReuse()
        var seen: [Int: Data] = [:]
        var collision: (Data, Data)?
        for value in 0...255 {
            let data = png(red: UInt8(value))
            if let other = seen[data.count], other != data { collision = (other, data); break }
            seen[data.count] = data
        }
        let (a, b) = collision!
        check(a.count == b.count && a != b, "Fixture must contain distinct, equal-length PNGs")
        let first = ClipboardItem(type: .image, imageData: a)
        check(first.deduplicationKey != ClipboardItem(type: .image, imageData: b).deduplicationKey,
              "Different images must both be recorded")
        check(first.deduplicationKey == ClipboardItem(type: .image, imageData: a).deduplicationKey,
              "Repeated identical images must still deduplicate")
        let regular = ClipboardItem(type: .richText, text: "Hello", rtfData: Data("{\\rtf1 Hello}".utf8))
        let bold = ClipboardItem(type: .richText, text: "Hello", rtfData: Data("{\\rtf1 \\b Hello}".utf8))
        check(regular.deduplicationKey != bold.deduplicationKey, "Rich text formatting must be preserved")
        first.contentDigest = first.computedDeduplicationKey
        check(first.deduplicationKey == first.computedDeduplicationKey, "Cached and legacy fingerprints agree")

        let processed = ImageUtils.processForStorage(png(red: 100, width: 4000, height: 1))!
        for (data, bound) in [(processed.image, 1600), (processed.thumbnail, 240)] {
            let source = CGImageSourceCreateWithData(data as CFData, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            check(image.width <= bound && image.height >= 1, "Downsample pixel size and keep narrow images valid")
        }
        check(ImageUtils.processForStorage(Data("not an image".utf8)) == nil, "Malformed images fail safely")

        check(ClipboardSelection.afterDeleting(2, from: [1, 2, 3]) == 3, "Middle deletion selects next item")
        check(ClipboardSelection.afterDeleting(3, from: [1, 2, 3]) == 2, "Last deletion selects previous item")
        check(ClipboardSelection.afterDeleting(1, from: [1]) == nil, "Last remaining item leaves no selection")
        check(ClipboardSelection.afterDeleting(1, from: [1, 2]) == 2, "First deletion selects next item")
        check(FloatingPanel.presentationLevel.rawValue > Int(CGWindowLevelForKey(.dockWindow)), "Panel must be above Dock")
        check(FloatingPanel.presentationLevel.rawValue < Int(CGWindowLevelForKey(.mainMenuWindow)), "Panel must stay below menus")

        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"] {
            check(ClipboardMonitor.hasPrivateContent(types: [.string, .init(marker)]), "Never retain marked content")
        }
        check(!ClipboardMonitor.hasPrivateContent(types: [.string]), "Normal text remains recordable")
        check(ClipboardMonitor.shouldSkipCopy(previousBundleID: "secret", currentBundleID: "editor", excluded: ["secret"]),
              "Copy then immediately leave an excluded app")
        check(ClipboardMonitor.shouldSkipCopy(previousBundleID: "editor", currentBundleID: "secret", excluded: ["secret"]),
              "Entering an excluded app also suppresses ambiguous content")
        check(!ClipboardMonitor.shouldSkipCopy(previousBundleID: "editor", currentBundleID: "browser", excluded: ["secret"]),
              "Ordinary app transitions remain recordable")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasterRegression-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = PersistenceManager.schema
        let badStore = root.appendingPathComponent("corrupt.store")
        let original = Data("Preserve this original database even when opening fails".utf8)
        try original.write(to: badStore)
        let fallback = PersistenceManager(configuration: ModelConfiguration(schema: schema, url: badStore))
        check(fallback.storageError != nil, "A failed open must be reported")
        let preserved = try Data(contentsOf: badStore)
        check(preserved == original, "Never remove or replace a failed database")
        fallback.mainContext.insert(ClipboardItem(text: "temporary session"))
        try fallback.mainContext.save()
        let temporaryItems = try fallback.mainContext.fetch(FetchDescriptor<ClipboardItem>())
        check(temporaryItems.count == 1, "Fallback remains usable without touching original data")

        let store = root.appendingPathComponent("roundtrip.store")
        let persistent = PersistenceManager(configuration: ModelConfiguration(schema: schema, url: store))
        check(persistent.storageError == nil, "Valid storage opens normally")
        first.isPinned = true
        persistent.mainContext.insert(first)
        persistent.mainContext.insert(bold)
        try persistent.mainContext.save()
        let reopened = PersistenceManager(configuration: ModelConfiguration(schema: schema, url: store))
        let rows = try reopened.mainContext.fetch(FetchDescriptor<ClipboardItem>())
        check(rows.count == 2, "History survives reopening")
        check(rows.first(where: { $0.isPinned })?.deduplicationKey == first.deduplicationKey, "Pinned image digest survives reopening")
        try checkImageStorage(root: root)
        print("PASS: \(checks) macOS regression checks")
    }

    /// Full-size images live in their own entity so list fetches never load them, and rows
    /// written by older versions into the inline column are moved over on open.
    static func checkImageStorage(root: URL) throws {
        let schema = PersistenceManager.schema
        let store = root.appendingPathComponent("images.store")
        let large = Data(repeating: 0xAB, count: 512_000)
        // Keep the manager alive: its container owns the context used below.
        let initial = PersistenceManager(configuration: ModelConfiguration(schema: schema, url: store))
        let context = initial.mainContext
        let fresh = ClipboardItem(type: .image, imageData: large, thumbnailData: png(red: 1))
        check(fresh.imageData == large, "Image is readable before the item is inserted")
        context.insert(fresh)
        // Simulate a row persisted by an older version: bytes still in the legacy inline column.
        let legacy = ClipboardItem(type: .image, thumbnailData: png(red: 2))
        legacy.legacyImageData = large
        context.insert(legacy)
        let orphan = ClipboardImage(data: large)
        context.insert(orphan)
        try context.save()

        let reopened = PersistenceManager(configuration: ModelConfiguration(schema: schema, url: store))
        let ctx = reopened.mainContext
        func imageRows() throws -> Int { try ctx.fetchCount(FetchDescriptor<ClipboardImage>()) }
        let legacyRows = try ctx.fetchCount(FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.legacyImageData != nil }))
        check(legacyRows == 0, "Opening the store moves legacy inline images out of the item row")
        let afterOpen = try imageRows()
        check(afterOpen == 2, "One image row per item; orphans are removed on open")
        let items = try ctx.fetch(FetchDescriptor<ClipboardItem>())
        check(items.count == 2 && items.allSatisfy { $0.imageData == large }, "Both images stay readable after migration")
        check(reopened.migrateLegacyImages() == 0, "Migration is idempotent")

        for item in items { ctx.delete(item) }
        try ctx.save()
        let afterDelete = try imageRows()
        check(afterDelete == 0, "Deleting an item cascades to its image")

        let replaced = ClipboardItem(type: .image, imageData: large)
        ctx.insert(replaced)
        replaced.imageData = Data([1, 2, 3])
        replaced.imageData = nil
        try ctx.save()
        let afterClear = try imageRows()
        check(afterClear == 0, "Replacing or clearing an image leaves no stray rows")
    }
}
