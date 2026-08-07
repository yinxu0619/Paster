import SwiftUI
import AppKit

/// 热键录制按钮（AppKit）。点击进入录制态，按下新的组合键即完成设置。
/// 按 Esc 取消录制。要求至少包含一个主修饰键（⌘/⌥/⌃）。
final class HotKeyRecorderButton: NSButton {
    private(set) var carbonKeyCode: UInt32 = 9
    private(set) var carbonModifiers: UInt32 = 768
    /// 捕获到新组合时调用，由外部尝试注册并返回是否成功；
    /// 失败（通常是被其它应用占用）时按钮回退显示旧组合，不采用新值。
    var onCapture: ((UInt32, UInt32) -> Bool)?

    private var isRecording = false
    private var eventMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    private func setup() {
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
        refreshTitle()
    }

    /// 外部（绑定变化）同步当前热键。
    func configure(keyCode: UInt32, modifiers: UInt32) {
        carbonKeyCode = keyCode
        carbonModifiers = modifiers
        if !isRecording { refreshTitle() }
    }

    @objc private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        title = L10n.tr("hotkey.pressShortcut")
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handle(event)
            return nil // 录制期间拦截按键
        }
    }

    private func stopRecording() {
        isRecording = false
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        refreshTitle()
    }

    private func handle(_ event: NSEvent) {
        // Esc 取消
        if event.keyCode == 53 {
            stopRecording()
            return
        }
        let carbon = KeyCodeTranslator.carbonModifiers(from: event.modifierFlags)
        // 必须包含主修饰键，否则忽略，继续等待。
        guard KeyCodeTranslator.hasPrimaryModifier(carbon) else { return }

        let newCode = UInt32(event.keyCode)
        // 只有注册成功才采用新组合；失败则保留旧值，refreshTitle() 会显示回原来的组合。
        if onCapture?(newCode, carbon) ?? true {
            carbonKeyCode = newCode
            carbonModifiers = carbon
        }
        stopRecording()
    }

    private func refreshTitle() {
        title = KeyCodeTranslator.shortcutDescription(keyCode: carbonKeyCode, carbonModifiers: carbonModifiers)
    }
}

/// SwiftUI 包装。
struct HotKeyRecorder: NSViewRepresentable {
    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt32
    /// 语言切换时触发 `updateNSView`，刷新录制占位文案。
    var languageToken: String = ""
    /// 捕获到新组合时尝试应用；返回是否成功，供按钮据此决定是否采用新显示。
    var onCapture: (UInt32, UInt32) -> Bool

    func makeNSView(context: Context) -> HotKeyRecorderButton {
        let button = HotKeyRecorderButton()
        button.configure(keyCode: keyCode, modifiers: modifiers)
        button.onCapture = onCapture
        return button
    }

    func updateNSView(_ nsView: HotKeyRecorderButton, context: Context) {
        nsView.onCapture = onCapture
        nsView.configure(keyCode: keyCode, modifiers: modifiers)
    }
}
