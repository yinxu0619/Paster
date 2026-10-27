import Foundation

/// 面板动效的一组开关，对应设置页「动效与性能」里的各项。
struct EffectsOptions: Equatable {
    var panelAnimation: PanelAnimation
    /// 选中切换与键盘导航时的列表滚动动画。
    var listAnimations: Bool
    /// 鼠标悬停高亮的渐变。触控板滚动时卡片不断从静止的光标下划过，几乎每时每刻都有一段
    /// 悬停动画在播，SwiftUI 只要有动画在跑就逐帧重绘整个列表：实测滚动时主线程占用 62% → 15%。
    var hoverAnimation: Bool
    /// 按住方向键（自动重复）时也播放选中与滚动动画。关闭时只有单按才有动画、重复时瞬间跳到位：
    /// 主线程 CPU 更低（42% → 24%），但越过边缘时一次跳一屏、新卡片集中在同一帧创建，
    /// 实测反而偶有单帧掉帧（120Hz 内屏 0–1 → 9–13 次），所以只在「响应优先」里关闭。
    var keyRepeatAnimation: Bool
    /// 选中卡片下方的阴影。
    var selectionShadow: Bool
}

/// 动效预设：在「好看」和「跟手」之间给用户一个一键选择，细项仍可单独调整。
enum EffectsPreset: String, CaseIterable, Identifiable {
    /// 特效优先：所有动效全开。
    case effects
    /// 均衡（默认）：只关掉开销最大的悬停渐变，其余动效保留。
    case balanced
    /// 响应优先：关闭全部动效，面板瞬间出现、操作即时生效。
    case performance
    /// 细项与任何预设都不一致。
    case custom

    var id: String { rawValue }
    var displayName: String { L10n.tr("effects.preset.\(rawValue)") }

    /// 可在设置里直接选择的预设（不含「自定义」）。
    static let selectable: [EffectsPreset] = [.effects, .balanced, .performance]

    var options: EffectsOptions? {
        switch self {
        case .effects:
            return EffectsOptions(panelAnimation: .smooth, listAnimations: true, hoverAnimation: true,
                                  keyRepeatAnimation: true, selectionShadow: true)
        case .balanced:
            return EffectsOptions(panelAnimation: .smooth, listAnimations: true, hoverAnimation: false,
                                  keyRepeatAnimation: true, selectionShadow: true)
        case .performance:
            return EffectsOptions(panelAnimation: .none, listAnimations: false, hoverAnimation: false,
                                  keyRepeatAnimation: false, selectionShadow: false)
        case .custom:
            return nil
        }
    }

    /// 细项恰好等于某个预设时返回该预设，否则为 `.custom`。
    static func matching(_ options: EffectsOptions) -> EffectsPreset {
        selectable.first { $0.options == options } ?? .custom
    }
}
