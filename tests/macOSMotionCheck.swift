import AppKit
import SwiftUI
import SwiftData

@main @MainActor
struct MotionCheck {
    static func pump(_ seconds: Double = 0.3) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }
    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    static func main() throws {
        setbuf(stdout, nil)
        // This executable has its own bundle and uses only an in-memory history.
        let previousListAnimations = AppSettings.shared.listAnimations
        AppSettings.shared.listAnimations = true
        defer { AppSettings.shared.listAnimations = previousListAnimations }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let config = ModelConfiguration(schema: PersistenceManager.schema, isStoredInMemoryOnly: true)
        let store = try ModelContainer(for: PersistenceManager.schema, configurations: [config])
        for i in 0..<30 {
            let item = ClipboardItem(text: "Motion fixture \(i + 1)\nSample clipboard text for animation verification.")
            item.createdAt = Date(timeIntervalSince1970: Double(1000 - i))
            store.mainContext.insert(item)
        }
        try store.mainContext.save()
        let actions = PanelActions(paste: {_ in}, pastePlain: {_ in}, copy: {_ in}, delete: {_ in}, togglePin: {_ in}, preview: {_ in}, dismiss: {}, openSettings: {})
        let fullWidth = CommandLine.arguments.contains("--full-width")
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let width: CGFloat = fullWidth ? screen.frame.width : 940
        let origin = fullWidth ? screen.frame.origin : NSPoint(x: 120, y: 100)
        let panel = FloatingPanel(contentRect: NSRect(origin: origin, size: NSSize(width: width, height: 320)))
        let root = PanelRootView(actions: actions, layout: .bar)
            .ignoresSafeArea(edges: .top)
            .modelContainer(store)
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        panel.setContentSize(NSSize(width: width, height: 320))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        pump(0.7)
        defer { panel.orderOut(nil); panel.close() }
        let views = descendants(hosting.view)
        guard let scroll = views.compactMap({ $0 as? NSScrollView }).first(where: { $0.documentView?.frame.width ?? 0 > 1000 }) else {
            print(views.map { String(describing: type(of: $0)) }.joined(separator: "\n"))
            fatalError("No horizontal scroll view")
        }
        func x() -> CGFloat { scroll.contentView.bounds.origin.x }
        func key(_ code: UInt16, _ characters: String) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            NSApp.sendEvent(event)
            pump()
        }
        func expect(_ ok: Bool, _ label: String) {
            print("\(ok ? "PASS" : "FAIL"): \(label); offset=\(x())")
            precondition(ok, label)
        }
        print("scroll viewport=\(scroll.contentView.bounds), document=\(scroll.documentView!.frame), hostingFlipped=\(hosting.view.isFlipped), layerFlipped=\(hosting.view.layer?.isGeometryFlipped ?? false)")
        let start = x()
        key(124, "\u{F703}")
        expect(abs(x() - start) < 1, "Visible next card does not move the row")
        key(124, "\u{F703}")
        expect(abs(x() - start) < 1, "Third visible card does not move the row")
        for _ in 0..<(Int(width / 220) + 5) { key(124, "\u{F703}") }
        expect(x() > start + 500, "Crossing the edge reveals offscreen cards")
        let edge = x()
        key(123, "\u{F702}")
        expect(abs(x() - edge) < 1, "Reversing within the viewport keeps the row still")
        key(115, "\u{F729}")
        expect(x() >= start && x() <= start + 14, "Home reveals the first card (allow content padding)")
        key(119, "\u{F72B}")
        expect(x() > scroll.documentView!.frame.width - scroll.contentView.bounds.width - 40, "End reveals the last card")
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        pump()
        key(119, "\u{F72B}")
        expect(x() > scroll.documentView!.frame.width - scroll.contentView.bounds.width - 40, "Repeated End works after scrolling away manually")
        AppSettings.shared.listAnimations = false
        key(115, "\u{F729}")
        expect(x() >= start && x() <= start + 14, "Navigation works with list animation disabled")
        for effect in PanelAnimation.allCases {
            panel.orderOut(nil)
            panel.prepareEntrance(effect, position: .bottom, reduceMotion: false)
            panel.makeKeyAndOrderFront(nil)
            pump(0.5)
            expect(panel.hasShadow && panel.isVisible, "Entrance \(effect.rawValue) settles with shadow")
        }
        print("PASS: real panel navigation and motion UI checks")
    }
}
