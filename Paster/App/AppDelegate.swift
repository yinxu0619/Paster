import AppKit
import SwiftUI
import SwiftData
import QuartzCore

/// 应用核心控制器：负责状态栏图标、全局热键、剪贴板监听与悬浮面板的生命周期。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: FloatingPanel?
    private var monitor: ClipboardMonitor?
    private var viewModel: ClipboardViewModel?
    private var previewWindow: NSWindow?
    private var settingsWindow: NSWindow?

    /// 面板操作集合，缓存以便每次呼出时按当前布局重建内容。
    private var panelActions: PanelActions?

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

        let showItem = NSMenuItem(title: "显示剪贴板历史", action: #selector(showPanelFromMenu), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        menu.addItem(.separator())

        let clearItem = NSMenuItem(title: "清空全部历史", action: #selector(clearAllHistory), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 Paster", action: #selector(quit), keyEquivalent: "q")
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
        alert.messageText = "清空全部剪贴板历史？"
        alert.informativeText = "此操作不可恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空全部")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            viewModel?.clearAll()
        }
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)

        // 菜单栏常驻应用没有标准主菜单，SwiftUI 的 showSettingsWindow: 往往无响应者，
        // 因此这里自建并复用一个承载 SettingsView 的窗口，行为稳定可靠。
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Paster 设置"
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
    private func configurePanelContent(_ panel: FloatingPanel) {
        guard let actions = panelActions else { return }
        let position = AppSettings.shared.panelPosition
        let isBar = (position == .bottom || position == .top)
        let isSide = (position == .left || position == .right)

        let rootView = PanelRootView(actions: actions, layout: isBar ? .bar : .vertical)
            .modelContainer(PersistenceManager.shared.container)
        let hosting = NSHostingController(rootView: rootView)
        // 关闭 SwiftUI 内容反向驱动窗口尺寸，否则横向条 / 满高侧栏会被收缩成内容最小尺寸。
        hosting.sizingOptions = []
        panel.contentViewController = hosting

        // 内容控制器设置后再指定尺寸：
        // - 上/下：铺满屏宽，高度可调；
        // - 左/右：占满屏幕高度的竖向侧栏；
        // - 光标/居中：固定 360×480。
        let visible = currentScreen()?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        if isBar {
            let width = max(480, visible.width - 24)
            let height = CGFloat(AppSettings.shared.barHeight)
            panel.setContentSize(NSSize(width: width, height: height))
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
        window.title = "预览 · \(item.type.displayName)"
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
        alert.messageText = "需要「辅助功能」权限"
        alert.informativeText = """
        Paster 通过模拟 ⌘V 自动粘贴，这需要"辅助功能"权限。

        请在 系统设置 › 隐私与安全性 › 辅助功能 中勾选 Paster，然后重试。

        提示：每次重新打包后签名会变化，系统可能要求重新授权——如果列表里已有旧的 Paster，请先用「−」移除，再重新添加这一份。

        （内容已复制到剪贴板，你也可以直接在目标应用按 ⌘V 粘贴。）
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打开辅助功能设置")
        alert.addButton(withTitle: "好")
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

    /// 根据用户选择的呼出位置，计算面板最终的左下角坐标，并确保不超出可见区域。
    private func targetOrigin(for panel: NSPanel) -> NSPoint {
        let size = panel.frame.size
        guard let visible = currentScreen()?.visibleFrame else { return panel.frame.origin }
        let gap: CGFloat = 12

        switch AppSettings.shared.panelPosition {
        case .cursor:
            let mouse = NSEvent.mouseLocation
            var origin = NSPoint(x: mouse.x, y: mouse.y - size.height)
            origin.x = min(max(origin.x, visible.minX + gap), visible.maxX - size.width - gap)
            origin.y = min(max(origin.y, visible.minY + gap), visible.maxY - size.height - gap)
            return origin
        case .bottom:
            return NSPoint(x: visible.midX - size.width / 2, y: visible.minY + gap)
        case .top:
            // 紧贴屏幕上沿（菜单栏正下方），不留间隙。
            return NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height)
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
