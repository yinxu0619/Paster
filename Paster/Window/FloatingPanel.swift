import AppKit
import QuartzCore

/// 悬浮呼出面板。
///
/// 使用 `NSPanel` + `.nonactivatingPanel`，可在不强制切换前台应用的情况下接收键盘焦点，
/// 失去焦点时自动隐藏（由 `AppDelegate` 作为 delegate 处理）。
final class FloatingPanel: NSPanel {
    /// Above the Dock, while remaining below menus and system alerts.
    static var presentationLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
    }
    /// 按下 Esc（cancelOperation）时回调，由 `AppDelegate` 用于收起面板。
    var onCancel: (() -> Void)?

    private var contentLayout: PanelLayout?
    private var configuredContentSize: NSSize?

    /// Prepare before ordering the window front so its first frame already has the
    /// entrance effect. Keep the shadow stable, and never defer input until completion.
    func prepareEntrance(_ effect: PanelAnimation, position: PanelPosition, reduceMotion: Bool) {
        cancelEntrance()
        guard let contentView else { return }
        contentView.wantsLayer = true
        guard let layer = contentView.layer else { return }
        let effect = effect.effective(reduceMotion: reduceMotion)
        guard effect != .none else { return }

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = effect == .fade ? 0.12 : 0.1
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "paster.fadeIn")
        guard effect != .fade else { return }

        // A short translation settles quickly even on a tall bar or sidebar.
        // Hosting views can use flipped coordinates; enter from the chosen edge.
        let down: CGFloat = contentView.isFlipped ? 1 : -1
        let axis: String
        let offset: CGFloat
        switch position {
        case .bottom: axis = "transform.translation.y"; offset = down * 28
        case .top: axis = "transform.translation.y"; offset = -down * 28
        case .left: axis = "transform.translation.x"; offset = -28
        case .right: axis = "transform.translation.x"; offset = 28
        case .cursor, .center: axis = "transform.translation.y"; offset = down * 10
        }
        let slide: CABasicAnimation
        if effect == .elastic {
            let spring = CASpringAnimation(keyPath: axis)
            spring.mass = 1
            spring.stiffness = 400
            spring.damping = 26
            spring.duration = spring.settlingDuration
            slide = spring
        } else {
            slide = CABasicAnimation(keyPath: axis)
            slide.duration = 0.22
            slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        }
        slide.fromValue = offset
        slide.toValue = 0
        layer.add(slide, forKey: "paster.slideIn")
    }

    func cancelEntrance() {
        contentView?.layer?.removeAnimation(forKey: "paster.slideIn")
        contentView?.layer?.removeAnimation(forKey: "paster.fadeIn")
        hasShadow = true
    }

    /// 屏幕尺寸只影响窗口几何，不应销毁已预热的 SwiftUI 内容与列表状态。
    func configureContent(layout: PanelLayout, size: NSSize,
                          makeController: () -> NSViewController) {
        let needsContent = contentLayout != layout || contentViewController == nil
        if needsContent {
            contentViewController = makeController()
            contentLayout = layout
        }
        // 配置未变化时保留用户手动调整的窗口尺寸。
        if needsContent || configuredContentSize != size {
            setContentSize(size)
            contentViewController?.view.frame = CGRect(origin: .zero, size: size)
            configuredContentSize = size
        }
    }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = Self.presentationLevel
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 关闭系统默认窗口动画，改由 AppDelegate 显式做滑入动画，避免两者冲突造成"闪现"。
        animationBehavior = .none
    }

    // 允许面板成为 key window，从而接收键盘事件。
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        level = Self.presentationLevel
        super.makeKeyAndOrderFront(sender)
    }

    // 不约束到屏幕内，便于呼出动画从屏幕边缘外升起，并精确停靠到边缘。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    // Esc 收起面板（无论焦点在搜索框还是列表）。
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
