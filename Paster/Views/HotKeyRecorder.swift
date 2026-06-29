import SwiftUI
import AppKit

/// 热键录制按钮（AppKit）。点击进入录制态，按下新的组合键即完成设置。
/// 按 Esc 取消录制。要求至少包含一个主修饰键（⌘/⌥/⌃）。
final class HotKeyRecorderButton: NSButton {
    private(set) var carbonKeyCode: UInt32 = 9
    private(set) var carbonModifiers: UInt32 = 768
    var onChange: ((UInt32, UInt32) -> Void)?

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
        title = "请按下快捷键…"
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

        carbonKeyCode = UInt32(event.keyCode)
        carbonModifiers = carbon
        onChange?(carbonKeyCode, carbonModifiers)
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

    func makeNSView(context: Context) -> HotKeyRecorderButton {
        let button = HotKeyRecorderButton()
        button.configure(keyCode: keyCode, modifiers: modifiers)
        button.onChange = { code, mods in
            keyCode = code
            modifiers = mods
        }
        return button
    }

    func updateNSView(_ nsView: HotKeyRecorderButton, context: Context) {
        nsView.onChange = { code, mods in
            keyCode = code
            modifiers = mods
        }
        nsView.configure(keyCode: keyCode, modifiers: modifiers)
    }
}
