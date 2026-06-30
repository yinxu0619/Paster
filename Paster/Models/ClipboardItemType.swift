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
        case .text:     return L10n.tr("type.text")
        case .richText: return L10n.tr("type.richText")
        case .image:    return L10n.tr("type.image")
        case .file:     return L10n.tr("type.file")
        case .url:      return L10n.tr("type.url")
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
