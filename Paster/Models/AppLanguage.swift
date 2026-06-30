import Foundation

/// 应用界面语言（可在设置中覆盖系统语言）。
enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system
    case zhHans = "zh-Hans"
    case en = "en"

    var id: String { rawValue }

    /// 设置列表中的展示名称（随当前界面语言变化）。
    var displayName: String {
        switch self {
        case .system: return L10n.tr("language.system")
        case .zhHans: return L10n.tr("language.zh_hans")
        case .en:     return L10n.tr("language.en")
        }
    }
}
