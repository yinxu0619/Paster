import AppKit
import SwiftData

/// 设置页面的视图模型：清空历史、维护排除应用、列出可选应用。
@MainActor
final class SettingsViewModel: ObservableObject {
    /// 当前运行的常规应用（供排除列表选择）。
    @Published var runningApps: [RunningAppInfo] = []

    private let context = PersistenceManager.shared.mainContext

    init() {
        refreshRunningApps()
    }

    /// 一键清空全部历史。
    func clearAllHistory() {
        do {
            try context.delete(model: ClipboardItem.self)
            try context.save()
        } catch {
            NSLog("[Paster] 清空历史失败: \(error.localizedDescription)")
        }
    }

    /// 刷新当前运行的常规应用列表。
    func refreshRunningApps() {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningAppInfo? in
                guard let bundleID = app.bundleIdentifier else { return nil }
                return RunningAppInfo(bundleID: bundleID, name: app.localizedName ?? bundleID)
            }
        // 去重并按名称排序。
        var seen = Set<String>()
        runningApps = apps
            .filter { seen.insert($0.bundleID).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// 根据 Bundle ID 解析应用展示名称。
    func displayName(forBundleID bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }
}

/// 运行中应用的简要信息。
struct RunningAppInfo: Identifiable, Hashable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
}
