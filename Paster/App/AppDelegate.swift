import AppKit
import SwiftUI
import SwiftData
import QuartzCore

/// 应用核心控制器：负责状态栏图标、全局热键、剪贴板监听与悬浮面板的生命周期。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 面板即将呼出时发送，供内容视图重置搜索/选中、聚焦搜索框并确保监听已启动。
    static let panelWillShowNotification = Notification.Name("PasterPanelWillShow")

    private var statusItem: NSStatusItem?
    private var panel: FloatingPanel?
    private var monitor: ClipboardMonitor?
    private var viewModel: ClipboardViewModel?
    private var previewWindow: NSWindow?
    private var settingsWindow: NSWindow?

    /// 面板操作集合，缓存以便每次呼出时按当前布局重建内容。
    private var panelActions: PanelActions?

    /// 当前面板内容对应的配置签名（呼出位置/屏幕尺寸/横条高度）。
    /// 仅在签名变化时才重建 SwiftUI 内容，避免每次呼出都新建 NSHostingController 造成延迟。
    private var contentSignature: String?

    /// 呼出面板前记录的前台应用，用于粘贴后把焦点交还给它。
    private var previousApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏常驻应用：不在 Dock 显示图标、不抢占前台。
        NSApp.setActivationPolicy(.accessory)

        let context = PersistenceManager.shared.mainContext
        let monitor = ClipboardMonitor(context: context, settings: .shared)
        monitor.start()
        self.monitor = monitor
        self.viewModel = ClipboardViewModel(monitor: monitor, context: context)

        setupStatusItem()
        setupPanel()

        HotKeyManager.shared.onHotKey = { [weak self] in
            self?.togglePanel()
        }
        registerHotKeyFromSettings()

        // 监听热键变更，实时重新注册。
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(hotKeyDidChange),
                                               name: AppSettings.hotKeyChangedNotification,
                                               object: nil)
    }

    private func registerHotKeyFromSettings() {
        let settings = AppSettings.shared
        HotKeyManager.shared.register(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers)
    }

    @objc private func hotKeyDidChange() {
        registerHotKeyFromSettings()
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyManager.shared.unregister()
        monitor?.stop()
    }

    // MARK: - 状态栏图标

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Paster")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            popUpStatusMenu()
        } else {
            togglePanel()
        }
    }

    private func popUpStatusMenu() {
        let menu = NSMenu()

        let showItem = NSMenuItem(title: L10n.tr("menu.showHistory"), action: #selector(showPanelFromMenu), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        menu.addItem(.separator())

        let clearItem = NSMenuItem(title: L10n.tr("menu.clearHistory"), action: #selector(clearAllHistory), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        let settingsItem = NSMenuItem(title: L10n.tr("menu.settings"), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: L10n.tr("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        if let button = statusItem?.button {
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: button.bounds.height + 4),
                       in: button)
        }
    }

    @objc private func showPanelFromMenu() { showPanel() }

    @objc private func clearAllHistory() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("alert.clearTitle")
        alert.informativeText = L10n.tr("alert.clearMessage")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("settings.clear"))
        alert.addButton(withTitle: L10n.tr("settings.cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            viewModel?.clearAll()
        }
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)

        // 菜单栏常驻应用没有标准主菜单，SwiftUI 的 showSettingsWindow: 往往无响应者，
        // 因此这里自建并复用一个承载 SettingsView 的窗口，行为稳定可靠。
        if let window = settingsWindow {
            window.title = L10n.tr("menu.settingsWindowTitle")
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = L10n.tr("menu.settingsWindowTitle")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 460, height: 420))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - 面板

    private func setupPanel() {
        let actions = PanelActions(
            paste: { [weak self] item in self?.handlePaste(item) },
            pastePlain: { [weak self] item in self?.handlePastePlain(item) },
            copy: { [weak self] item in self?.viewModel?.copy(item) },
            delete: { [weak self] item in self?.viewModel?.delete(item) },
            togglePin: { [weak self] item in self?.viewModel?.togglePin(item) },
            preview: { [weak self] item in self?.showPreview(item) },
            dismiss: { [weak self] in self?.hidePanel() }
        )
        self.panelActions = actions

        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 480))
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hidePanel() }
        self.panel = panel
        configurePanelContent(panel)
    }

    /// 依据当前呼出位置设置面板尺寸与布局：上下边缘 → 全宽横向平铺条；其余 → 竖向卡片。
    ///
    /// 性能关键：仅当「呼出位置 / 屏幕尺寸 / 横条高度」变化时才重建 SwiftUI 内容
    /// （新建 NSHostingController 并重新拉取历史记录较慢，约 0.x 秒）。配置未变时直接
    /// 复用已建好的内容，呼出只做定位与动画，实现按键即出。
    private func configurePanelContent(_ panel: FloatingPanel) {
        guard let actions = panelActions else { return }
        let position = AppSettings.shared.panelPosition
        let isBar = (position == .bottom || position == .top)
        let isSide = (position == .left || position == .right)
        let visible = currentScreen()?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        // 横向条按用户选择停靠到真实屏幕边缘（含 Dock/菜单栏区域）或可用区域内。
        let barRegion = barLayoutRegion()
        let barHeight = CGFloat(AppSettings.shared.barHeight)
        let attachEdge = AppSettings.shared.barAttachToScreenEdge

        let signature = "\(position.rawValue)|\(Int(visible.width))x\(Int(visible.height))|\(Int(barRegion.width))|\(Int(barHeight))|\(attachEdge)"
        // 配置未变化且内容已存在：复用，跳过昂贵的重建。
        if signature == contentSignature, panel.contentViewController != nil {
            return
        }
        contentSignature = signature

        // 忽略顶部安全区：.titled 面板会为标题栏预留 ~32pt 安全区，导致内容整体下移，
        // 顶部停靠时表现为"没贴顶、有条缝"。这里让内容填满到窗口最上沿。
        let rootView = PanelRootView(actions: actions, layout: isBar ? .bar : .vertical)
            .ignoresSafeArea(edges: .top)
            .modelContainer(PersistenceManager.shared.container)
        let hosting = NSHostingController(rootView: rootView)
        // 关闭 SwiftUI 内容反向驱动窗口尺寸，否则横向条 / 满高侧栏会被收缩成内容最小尺寸。
        hosting.sizingOptions = []
        panel.contentViewController = hosting

        // 内容控制器设置后再指定尺寸：
        // - 上/下：铺满屏宽，高度可调；
        // - 左/右：占满屏幕高度的竖向侧栏；
        // - 光标/居中：固定 360×480。
        if isBar {
            // 贴屏幕边缘时铺满整屏宽；停靠在可用区域内时两侧留出小边距。
            let width = attachEdge ? barRegion.width : max(480, barRegion.width - 24)
            panel.setContentSize(NSSize(width: width, height: barHeight))
        } else if isSide {
            panel.setContentSize(NSSize(width: 360, height: visible.height))
        } else {
            panel.setContentSize(NSSize(width: 360, height: 480))
        }
        hosting.view.frame = CGRect(origin: .zero, size: panel.frame.size)
    }

    private func togglePanel() {
        if panel?.isVisible == true {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let panel else { return }
        previousApp = NSWorkspace.shared.frontmostApplication

        // 每次呼出前按当前设置重建布局与尺寸（竖向卡片 / 全宽横向平铺）。
        configurePanelContent(panel)

        // 窗口直接定位到最终位置；滑入动画交给 GPU 加速的内容图层完成（比窗口 setFrame 更丝滑）。
        panel.setFrameOrigin(targetOrigin(for: panel))
        panel.alphaValue = 1
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        // 通知内容视图重置状态并聚焦搜索框（内容被复用、onAppear 不再触发时也生效）。
        NotificationCenter.default.post(name: Self.panelWillShowNotification, object: nil)

        animateEntrance(panel)
    }

    /// 用 Core Animation 在内容图层上做「弹性位移 + 淡入」入场动画（GPU 加速，丝滑流畅，带果冻回弹）。
    private func animateEntrance(_ panel: FloatingPanel) {
        guard let contentView = panel.contentView else { return }
        contentView.wantsLayer = true
        guard let layer = contentView.layer else { return }
        layer.removeAnimation(forKey: "paster.slideIn")
        layer.removeAnimation(forKey: "paster.fadeIn")

        let position = AppSettings.shared.panelPosition
        let slides = position != .cursor && position != .center

        // 淡入（更快）。
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.16
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "paster.fadeIn")

        // 位移起点（图层 y 轴向上：负值=向下/屏幕下方，正值=向上/屏幕上方）：
        // - 底部：从下方进入（起点在下方，向上滑出）→ 负值
        // - 顶部：从上方进入（起点在上方，向下滑出）→ 正值
        // - 左/右：x 轴为标准方向，从对应侧边进入
        // - 悬浮/居中：轻微回弹的小位移
        let size = panel.frame.size
        let axis: String
        let from: CGFloat
        switch position {
        case .bottom: axis = "transform.translation.y"; from = -size.height
        case .top:    axis = "transform.translation.y"; from =  size.height
        case .left:   axis = "transform.translation.x"; from = -size.width
        case .right:  axis = "transform.translation.x"; from =  size.width
        case .cursor, .center: axis = "transform.translation.y"; from = -16
        }

        let spring = CASpringAnimation(keyPath: axis)
        spring.fromValue = from
        spring.toValue = 0
        spring.mass = 1
        spring.stiffness = 320       // 更高刚度 → 动画更快
        spring.damping = 18          // 偏低阻尼 → 带果冻回弹
        spring.initialVelocity = 0
        spring.duration = spring.settlingDuration

        // 大幅贴边滑入期间临时关闭窗口阴影，避免回弹时出现空阴影框；结束后恢复。
        if slides {
            panel.hasShadow = false
            DispatchQueue.main.asyncAfter(deadline: .now() + spring.settlingDuration) { [weak panel] in
                panel?.hasShadow = true
            }
        }
        layer.add(spring, forKey: "paster.slideIn")
    }

    private func hidePanel() {
        // 粘贴 / 失焦路径需要即时隐藏以保证焦点与按键时序，这里直接 orderOut。
        panel?.orderOut(nil)
        panel?.alphaValue = 1
    }

    /// 展示单条记录的大窗预览。
    private func showPreview(_ item: ClipboardItem) {
        hidePanel()

        let view = PreviewView(item: item) { [weak self] in
            self?.previewWindow?.close()
        }
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = L10n.tr("preview.windowTitle", item.type.displayName)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 680, height: 520))
        window.center()
        window.isReleasedWhenClosed = false
        previewWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func handlePaste(_ item: ClipboardItem) {
        // 没有辅助功能权限时，模拟 ⌘V 会被系统静默忽略：先把内容放进剪贴板，再引导授权。
        guard ensureAccessibilityOrGuide(for: item) else { return }
        // 顺序很关键：先隐藏面板让 Paster 让出焦点，再激活目标应用，最后写回剪贴板并延迟发送 ⌘V。
        hidePanel()
        previousApp?.activate()
        viewModel?.paste(item)
    }

    private func handlePastePlain(_ item: ClipboardItem) {
        guard ensureAccessibilityOrGuide(for: item) else { return }
        hidePanel()
        previousApp?.activate()
        viewModel?.pasteAsPlainText(item)
    }

    /// 检查辅助功能权限；缺失则把内容写入剪贴板并弹窗引导授权，返回 false 表示本次不再尝试模拟按键。
    private func ensureAccessibilityOrGuide(for item: ClipboardItem) -> Bool {
        if PasteService.shared.hasAccessibilityPermission() { return true }

        viewModel?.copy(item)            // 至少保证内容已在剪贴板，可手动 ⌘V
        PasteService.shared.requestAccessibilityPermission()
        hidePanel()

        let alert = NSAlert()
        alert.messageText = L10n.tr("alert.accessibilityTitle")
        alert.informativeText = L10n.tr("alert.accessibilityMessage")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.tr("alert.openAccessibility"))
        alert.addButton(withTitle: L10n.tr("alert.ok"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    /// 当前鼠标所在的屏幕（多屏适配）。
    private func currentScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// 横向条停靠所依据的矩形区域：
    /// - 贴屏幕边缘（`barAttachToScreenEdge`）：整块屏幕 `frame`；
    /// - 否则：去掉 Dock / 菜单栏后的可用区域 `visibleFrame`。
    private func barLayoutRegion() -> NSRect {
        let screen = currentScreen() ?? NSScreen.main
        if AppSettings.shared.barAttachToScreenEdge {
            return screen?.frame ?? NSScreen.main?.frame ?? .zero
        }
        return screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
    }

    /// 根据用户选择的呼出位置，计算面板最终的左下角坐标，并确保不超出可见区域。
    private func targetOrigin(for panel: NSPanel) -> NSPoint {
        let size = panel.frame.size
        guard let visible = currentScreen()?.visibleFrame else { return panel.frame.origin }
        // 横向条按开关决定贴真实屏幕边缘还是可用区域内。
        let bar = barLayoutRegion()
        let gap: CGFloat = 12

        switch AppSettings.shared.panelPosition {
        case .cursor:
            let mouse = NSEvent.mouseLocation
            var origin = NSPoint(x: mouse.x, y: mouse.y - size.height)
            origin.x = min(max(origin.x, visible.minX + gap), visible.maxX - size.width - gap)
            origin.y = min(max(origin.y, visible.minY + gap), visible.maxY - size.height - gap)
            return origin
        case .bottom:
            // 贴边时紧贴屏幕最底沿；否则位于 Dock 之上并留出小间距。
            let y = AppSettings.shared.barAttachToScreenEdge ? bar.minY : bar.minY + gap
            return NSPoint(x: bar.midX - size.width / 2, y: y)
        case .top:
            // 贴边/贴菜单栏下沿，均紧贴区域上沿不留缝。
            return NSPoint(x: bar.midX - size.width / 2, y: bar.maxY - size.height)
        case .left:
            return NSPoint(x: visible.minX + gap, y: visible.midY - size.height / 2)
        case .right:
            return NSPoint(x: visible.maxX - size.width - gap, y: visible.midY - size.height / 2)
        case .center:
            return NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
    }

}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    /// 仅悬浮面板失去焦点时自动隐藏（设置/预览等其它窗口不受影响）。
    func windowDidResignKey(_ notification: Notification) {
        if let object = notification.object as? NSWindow, object === panel {
            hidePanel()
        }
    }

    /// 横向条模式下拖拽调整高度后，记住新的高度。
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let object = notification.object as? NSWindow, object === panel else { return }
        let position = AppSettings.shared.panelPosition
        guard position == .bottom || position == .top else { return }
        AppSettings.shared.barHeight = Double(panel?.frame.height ?? CGFloat(AppSettings.shared.barHeight))
    }
}
