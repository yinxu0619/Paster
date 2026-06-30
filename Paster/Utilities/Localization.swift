import Foundation

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
    static var resolvedLanguageCode: String {
        resolveLanguageCode(stored: UserDefaults.standard.string(forKey: "appLanguage"))
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
    static var l10n: Bundle {
        let code = L10n.resolvedLanguageCode
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return .main
    }
}
