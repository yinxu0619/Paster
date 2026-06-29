import AppKit
import Carbon.HIToolbox

/// 键码与修饰键的相互转换 / 展示工具（第 6 轮新增，用于自定义热键）。
///
/// 全局热键使用 Carbon 的虚拟键码与修饰键掩码；NSEvent 提供的 keyCode 与 Carbon
/// 虚拟键码一致，修饰键需要在 NSEvent.ModifierFlags 与 Carbon 掩码之间转换。
enum KeyCodeTranslator {
    /// 把 NSEvent 修饰键转换为 Carbon 修饰键掩码。
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option)  { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift)   { result |= UInt32(shiftKey) }
        return result
    }

    /// 是否包含至少一个「主修饰键」（⌘/⌥/⌃），避免设置过于容易误触的快捷键。
    static func hasPrimaryModifier(_ carbon: UInt32) -> Bool {
        (carbon & (UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey))) != 0
    }

    /// 修饰键符号（按 macOS 习惯顺序：⌃⌥⇧⌘）。
    static func modifierSymbols(carbon: UInt32) -> String {
        var symbols = ""
        if carbon & UInt32(controlKey) != 0 { symbols += "⌃" }
        if carbon & UInt32(optionKey)  != 0 { symbols += "⌥" }
        if carbon & UInt32(shiftKey)   != 0 { symbols += "⇧" }
        if carbon & UInt32(cmdKey)     != 0 { symbols += "⌘" }
        return symbols
    }

    /// 键码对应的可读名称。
    static func keyName(_ keyCode: UInt32) -> String {
        names[Int(keyCode)] ?? "Key\(keyCode)"
    }

    /// 完整快捷键描述，如 "⌘⇧V"。
    static func shortcutDescription(keyCode: UInt32, carbonModifiers: UInt32) -> String {
        modifierSymbols(carbon: carbonModifiers) + keyName(keyCode)
    }

    private static let names: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
        42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
        50: "`", 51: "⌫", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]
}
