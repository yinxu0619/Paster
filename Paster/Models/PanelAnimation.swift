import Foundation

enum PanelAnimation: String, CaseIterable, Identifiable {
    case smooth, elastic, fade, none

    var id: String { rawValue }
    var displayName: String { L10n.tr("animation.\(rawValue)") }

    func effective(reduceMotion: Bool) -> Self {
        reduceMotion && self != .none ? .fade : self
    }
}
