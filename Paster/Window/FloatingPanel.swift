import AppKit

/// 悬浮呼出面板。
///
/// 使用 `NSPanel` + `.nonactivatingPanel`，可在不强制切换前台应用的情况下接收键盘焦点，
/// 失去焦点时自动隐藏（由 `AppDelegate` 作为 delegate 处理）。
final class FloatingPanel: NSPanel {
    /// 按下 Esc（cancelOperation）时回调，由 `AppDelegate` 用于收起面板。
    var onCancel: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .floating
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

    // 不约束到屏幕内，便于呼出动画从屏幕边缘外升起，并精确停靠到边缘。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    // Esc 收起面板（无论焦点在搜索框还是列表）。
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
