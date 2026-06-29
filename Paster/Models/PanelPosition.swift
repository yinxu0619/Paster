import Foundation

/// 呼出面板的出现位置（第 6 轮新增，可在设置中切换）。
enum PanelPosition: String, CaseIterable, Identifiable, Codable {
    case cursor   // 跟随光标（悬浮，默认）
    case bottom   // 屏幕底部
    case top      // 屏幕顶部
    case left     // 屏幕左侧
    case right    // 屏幕右侧
    case center   // 屏幕中央

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cursor: return "跟随光标（悬浮）"
        case .bottom: return "屏幕底部"
        case .top:    return "屏幕顶部"
        case .left:   return "屏幕左侧"
        case .right:  return "屏幕右侧"
        case .center: return "屏幕中央"
        }
    }
}
