import Foundation

/// 剪贴板内容类型。
/// 第 1 轮仅支持 `text`；第 2 轮在此「新增」富文本、图片、文件、URL 四种 case，
/// 不删除已有 case，以保证增量兼容与历史数据可读。
enum ClipboardItemType: String, Codable, CaseIterable {
    case text
    case richText
    case image
    case file
    case url

    /// 中文展示名称，用于卡片上的类型标签。
    var displayName: String {
        switch self {
        case .text: return "文本"
        case .richText: return "富文本"
        case .image: return "图片"
        case .file: return "文件"
        case .url: return "链接"
        }
    }

    /// 对应的 SF Symbol 名称，用于列表/卡片图标。
    var symbolName: String {
        switch self {
        case .text: return "doc.plaintext"
        case .richText: return "doc.richtext"
        case .image: return "photo"
        case .file: return "doc"
        case .url: return "link"
        }
    }
}
