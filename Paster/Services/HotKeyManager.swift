import AppKit
import Carbon.HIToolbox

/// 全局热键管理器。
///
/// 使用 Carbon 的 `RegisterEventHotKey` 注册系统级热键（任意应用内均可触发），
/// 默认 ⌘⇧V。第 3/4 轮会在此基础上「扩展」自定义快捷键能力。
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    /// 热键被按下时的回调。
    var onHotKey: (() -> Void)?

    private init() {}

    /// 注册全局热键，默认 ⌘⇧V。
    func register(keyCode: UInt32 = UInt32(kVK_ANSI_V),
                  modifiers: UInt32 = UInt32(cmdKey | shiftKey)) {
        unregister()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        // 该闭包不捕获任何局部变量（仅引用静态单例），因此可转换为 C 函数指针。
        let callback: EventHandlerUPP = { (_, _, _) -> OSStatus in
            HotKeyManager.shared.onHotKey?()
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, &eventHandlerRef)

        let hotKeyID = EventHotKeyID(signature: HotKeyManager.signature, id: 1)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    /// 注销热键与事件处理器。
    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    /// 四字符签名 'PSTR'，用于唯一标识本应用的热键。
    private static let signature: OSType = {
        "PSTR".utf8.prefix(4).reduce(OSType(0)) { ($0 << 8) + OSType($1) }
    }()
}
