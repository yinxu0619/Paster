import AppKit
import Carbon.HIToolbox
import ApplicationServices

/// 负责把历史记录写回系统剪贴板，并模拟 ⌘V 粘贴到当前焦点应用。
///
/// 模拟按键依赖「辅助功能（Accessibility）」权限，首次运行需用户在系统设置中授权。
/// 第 2 轮「扩展」为支持图片/文件/URL/富文本写回，以及「纯文本写回」（剥离格式）。
@MainActor
final class PasteService {
    static let shared = PasteService()
    private init() {}

    /// 按记录原始类型写回系统剪贴板，返回写入后的 changeCount，便于监听器忽略自身写入。
    @discardableResult
    func copyToPasteboard(_ item: ClipboardItem) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.type {
        case .image:
            if let data = item.imageData, let image = NSImage(data: data) {
                pasteboard.writeObjects([image])
            }
        case .file:
            let urls = Self.fileURLs(from: item)
            if !urls.isEmpty {
                pasteboard.writeObjects(urls as [NSPasteboardWriting])
            } else if let text = item.text {
                pasteboard.setString(text, forType: .string)
            }
        case .url:
            if let urlString = item.urlString, let url = URL(string: urlString) {
                pasteboard.writeObjects([url as NSURL])
                pasteboard.setString(urlString, forType: .string)
            }
        case .richText:
            if let rtf = item.rtfData {
                pasteboard.setData(rtf, forType: .rtf)
            }
            if let text = item.text {
                pasteboard.setString(text, forType: .string)
            }
        case .text:
            if let text = item.text {
                pasteboard.setString(text, forType: .string)
            }
        }

        return pasteboard.changeCount
    }

    /// 以纯文本形式写回剪贴板（剥离所有富格式），用于「纯文本粘贴」。
    @discardableResult
    func copyAsPlainText(_ item: ClipboardItem) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.plainTextRepresentation, forType: .string)
        return pasteboard.changeCount
    }

    /// 是否已获得辅助功能（Accessibility）权限。模拟按键必需。
    func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// 触发系统授权弹窗，并把本应用加入"辅助功能"列表。
    func requestAccessibilityPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// 模拟一次 ⌘V 按键，触发当前焦点应用执行粘贴。
    func simulatePasteKeystroke() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    /// 从记录中还原文件 URL 列表。
    private static func fileURLs(from item: ClipboardItem) -> [NSURL] {
        guard let raw = item.fileURLString else { return [] }
        return raw.split(separator: "\n").compactMap { line -> NSURL? in
            let s = String(line)
            if let url = URL(string: s) { return url as NSURL }
            return URL(fileURLWithPath: s) as NSURL
        }
    }
}
