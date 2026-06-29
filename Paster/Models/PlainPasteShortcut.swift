import SwiftUI

/// 面板内「无格式（纯文本）粘贴」的快捷键（与回车组合，可在设置中切换）。
enum PlainPasteShortcut: String, CaseIterable, Identifiable, Codable {
    case commandShift   // ⌘⇧↩（默认）
    case command        // ⌘↩
    case option         // ⌥↩
    case control        // ⌃↩

    var id: String { rawValue }

    /// 用于在设置中展示的符号，例如 "⌘⇧↩"。
    var displayName: String {
        switch self {
        case .commandShift: return "⌘⇧↩"
        case .command:      return "⌘↩"
        case .option:       return "⌥↩"
        case .control:      return "⌃↩"
        }
    }

    /// 与回车搭配所需的修饰键集合（用于匹配 SwiftUI 的 KeyPress）。
    var eventModifiers: EventModifiers {
        switch self {
        case .commandShift: return [.command, .shift]
        case .command:      return [.command]
        case .option:       return [.option]
        case .control:      return [.control]
        }
    }
}
