import Foundation
import AppKit
import ServiceManagement
import Carbon.HIToolbox

/// 全局应用配置，持久化到 `UserDefaults`。
///
/// 第 4 轮新增：历史留存上限、排除应用列表、开机自启。
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// 呼出热键发生变化时发送，`AppDelegate` 据此重新注册全局热键。
    static let hotKeyChangedNotification = Notification.Name("PasterHotKeyChanged")

    /// 默认呼出热键：⌘⇧V。
    static let defaultHotKeyCode = UInt32(kVK_ANSI_V)
    static let defaultHotKeyModifiers = UInt32(cmdKey | shiftKey)

    private enum Keys {
        static let historyLimit = "historyLimit"
        static let excludedBundleIDs = "excludedBundleIDs"
        static let launchAtLogin = "launchAtLogin"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let panelPosition = "panelPosition"
        static let barHeight = "barHeight"
        static let plainPasteShortcut = "plainPasteShortcut"
    }

    /// 横向平铺条高度的允许范围。
    static let barHeightRange: ClosedRange<Double> = 160...600

    private let defaults = UserDefaults.standard

    /// 历史留存数量上限（不含固定项）。
    @Published var historyLimit: Int {
        didSet { defaults.set(historyLimit, forKey: Keys.historyLimit) }
    }

    /// 排除应用 Bundle ID 列表（这些应用复制的内容不会被记录）。
    @Published var excludedBundleIDs: [String] {
        didSet { defaults.set(excludedBundleIDs, forKey: Keys.excludedBundleIDs) }
    }

    /// 开机自启开关。
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            applyLaunchAtLogin()
        }
    }

    /// 呼出热键的虚拟键码。
    @Published var hotKeyCode: UInt32 {
        didSet {
            defaults.set(Int(hotKeyCode), forKey: Keys.hotKeyCode)
            notifyHotKeyChanged()
        }
    }

    /// 呼出热键的 Carbon 修饰键掩码。
    @Published var hotKeyModifiers: UInt32 {
        didSet {
            defaults.set(Int(hotKeyModifiers), forKey: Keys.hotKeyModifiers)
            notifyHotKeyChanged()
        }
    }

    /// 呼出面板出现的位置。
    @Published var panelPosition: PanelPosition {
        didSet { defaults.set(panelPosition.rawValue, forKey: Keys.panelPosition) }
    }

    /// 横向平铺条（底部/顶部）的高度，单位 pt。
    @Published var barHeight: Double {
        didSet {
            let clamped = min(Self.barHeightRange.upperBound, max(Self.barHeightRange.lowerBound, barHeight))
            if clamped != barHeight { barHeight = clamped; return }
            defaults.set(barHeight, forKey: Keys.barHeight)
        }
    }

    /// 面板内「无格式粘贴」的快捷键（与回车组合）。
    @Published var plainPasteShortcut: PlainPasteShortcut {
        didSet { defaults.set(plainPasteShortcut.rawValue, forKey: Keys.plainPasteShortcut) }
    }

    private init() {
        historyLimit = defaults.object(forKey: Keys.historyLimit) as? Int ?? 200
        excludedBundleIDs = defaults.stringArray(forKey: Keys.excludedBundleIDs) ?? []
        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        hotKeyCode = UInt32(defaults.object(forKey: Keys.hotKeyCode) as? Int ?? Int(Self.defaultHotKeyCode))
        hotKeyModifiers = UInt32(defaults.object(forKey: Keys.hotKeyModifiers) as? Int ?? Int(Self.defaultHotKeyModifiers))
        panelPosition = PanelPosition(rawValue: defaults.string(forKey: Keys.panelPosition) ?? "") ?? .cursor
        barHeight = defaults.object(forKey: Keys.barHeight) as? Double ?? 240
        plainPasteShortcut = PlainPasteShortcut(rawValue: defaults.string(forKey: Keys.plainPasteShortcut) ?? "") ?? .commandShift
    }

    /// 恢复默认呼出热键（⌘⇧V）。
    func resetHotKeyToDefault() {
        hotKeyCode = Self.defaultHotKeyCode
        hotKeyModifiers = Self.defaultHotKeyModifiers
    }

    /// 当前热键的可读描述，如 "⌘⇧V"。
    var hotKeyDescription: String {
        KeyCodeTranslator.shortcutDescription(keyCode: hotKeyCode, carbonModifiers: hotKeyModifiers)
    }

    private func notifyHotKeyChanged() {
        NotificationCenter.default.post(name: Self.hotKeyChangedNotification, object: nil)
    }

    /// 判断某来源应用是否被排除（敏感应用不记录）。
    func isExcluded(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return excludedBundleIDs.contains(bundleID)
    }

    func addExcluded(bundleID: String) {
        guard !bundleID.isEmpty, !excludedBundleIDs.contains(bundleID) else { return }
        excludedBundleIDs.append(bundleID)
    }

    func removeExcluded(bundleID: String) {
        excludedBundleIDs.removeAll { $0 == bundleID }
    }

    private func applyLaunchAtLogin() {
        do {
            let service = SMAppService.mainApp
            if launchAtLogin {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
        } catch {
            NSLog("[Paster] 开机自启设置失败: \(error.localizedDescription)")
        }
    }
}
