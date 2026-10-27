import Foundation
import os

/// 本地化工具：根据 `UserDefaults` 中的语言设置选择对应的 `.lproj` 资源。
enum L10n {
    static func tr(_ key: String, comment: String = "") -> String {
        NSLocalizedString(key, bundle: Bundle.l10n, comment: comment)
    }

    static func tr(_ key: String, _ args: CVarArg...) -> String {
        let format = NSLocalizedString(key, bundle: Bundle.l10n, comment: "")
        return String(format: format, locale: Locale(identifier: resolvedLanguageCode), arguments: args)
    }

    /// 当前生效的语言代码（与 `AppSettings.resolvedLanguageCode` 逻辑一致）。
    static var resolvedLanguageCode: String { resolved().code }

    /// 当前语言对应的 `.lproj` Bundle。
    static var bundle: Bundle { resolved().bundle }

    /// 按存储的语言设置缓存解析结果。每张卡片（含右键菜单）每次刷新都会多次取文案，
    /// 原先每次都走 `path(forResource:)` + `Bundle(path:)`，实测占面板刷新主线程时间约一成。
    /// 设置变化时存储值随之变化，缓存自然失效。
    private static let cache = OSAllocatedUnfairLock<(stored: String?, code: String, bundle: Bundle)?>(initialState: nil)

    private static func resolved() -> (code: String, bundle: Bundle) {
        let stored = UserDefaults.standard.string(forKey: "appLanguage")
        if let hit = cache.withLock({ $0 }), hit.stored == stored { return (hit.code, hit.bundle) }
        let code = resolveLanguageCode(stored: stored)
        let bundle = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        cache.withLock { $0 = (stored, code, bundle) }
        return (code, bundle)
    }

    private static func resolveLanguageCode(stored: String?) -> String {
        let language = AppLanguage(rawValue: stored ?? "") ?? .system
        switch language {
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "zh-Hans"
            if preferred.hasPrefix("zh") { return "zh-Hans" }
            if preferred.hasPrefix("en") { return "en" }
            return "zh-Hans"
        case .zhHans: return "zh-Hans"
        case .en:     return "en"
        }
    }
}

extension Bundle {
    /// 当前生效的本地化 Bundle（随设置中的语言切换）。
    static var l10n: Bundle { L10n.bundle }
}
