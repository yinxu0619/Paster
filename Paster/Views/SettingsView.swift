import SwiftUI

/// 设置界面（第 4 轮新增）。
///
/// 分为通用、历史、隐私三个分组：开机自启、历史上限、一键清空、排除应用列表。
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var viewModel = SettingsViewModel()

    @State private var showingClearConfirm = false

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("通用", systemImage: "gearshape") }
            privacyTab
                .tabItem { Label("隐私", systemImage: "hand.raised") }
            AboutView()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 460, height: 420)
    }

    // MARK: - 通用

    private var generalTab: some View {
        Form {
            Section("启动") {
                Toggle("登录时自动启动 Paster", isOn: $settings.launchAtLogin)
            }

            Section("快捷键") {
                HStack {
                    Text("呼出面板")
                    Spacer()
                    HotKeyRecorder(keyCode: $settings.hotKeyCode, modifiers: $settings.hotKeyModifiers)
                        .frame(width: 150, height: 24)
                    Button("恢复默认") { settings.resetHotKeyToDefault() }
                }
                Text("点击右侧按钮后按下新的组合键（需包含 ⌘ / ⌥ / ⌃ 之一），按 Esc 取消。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("呼出位置") {
                Picker("面板出现在", selection: $settings.panelPosition) {
                    ForEach(PanelPosition.allCases) { position in
                        Text(position.displayName).tag(position)
                    }
                }
                Text("可选择跟随光标悬浮，或固定从屏幕某一侧滑出（类似 Paste 的底部停靠）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.panelPosition == .bottom || settings.panelPosition == .top {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("横向条高度")
                            Spacer()
                            Text("\(Int(settings.barHeight)) pt")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $settings.barHeight,
                               in: AppSettings.barHeightRange,
                               step: 10) {
                            Text("横向条高度")
                        } minimumValueLabel: {
                            Image(systemName: "rectangle.compress.vertical")
                        } maximumValueLabel: {
                            Image(systemName: "rectangle.expand.vertical")
                        }
                        barHeightPreview
                        Text("横向条铺满屏幕宽度；也可在呼出后直接拖拽面板上边缘调整高度。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("历史") {
                Stepper(value: $settings.historyLimit, in: 20...2000, step: 20) {
                    HStack {
                        Text("历史留存数量上限")
                        Spacer()
                        Text("\(settings.historyLimit) 条")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("超出上限时会自动删除最旧的未固定记录，固定项不受影响。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(role: .destructive) {
                    showingClearConfirm = true
                } label: {
                    Label("清空全部历史", systemImage: "trash")
                }
                .confirmationDialog("确定要清空全部剪贴板历史吗？此操作不可恢复。",
                                    isPresented: $showingClearConfirm,
                                    titleVisibility: .visible) {
                    Button("清空全部", role: .destructive) {
                        viewModel.clearAllHistory()
                    }
                    Button("取消", role: .cancel) {}
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 高度可视化预览：示意屏幕中横向条所占高度比例。
    private var barHeightPreview: some View {
        let isTop = settings.panelPosition == .top
        // 以屏幕可见高度约 900pt 作为示意基准换算占比。
        let ratio = min(0.6, max(0.1, settings.barHeight / 900))
        return GeometryReader { geo in
            let h = geo.size.height
            let barH = max(8, h * ratio)
            ZStack(alignment: isTop ? .top : .bottom) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.12))
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(height: barH)
                    .padding(3)
                    .overlay(alignment: isTop ? .top : .bottom) {
                        Text("Paster")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(barH > 22 ? 4 : 0)
                            .opacity(barH > 22 ? 1 : 0)
                    }
            }
        }
        .frame(height: 64)
        .animation(.easeInOut(duration: 0.15), value: settings.barHeight)
    }

    // MARK: - 隐私

    private var privacyTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("排除应用")
                .font(.headline)
            Text("以下应用复制的内容不会被记录（适用于密码管理器等敏感应用）。")
                .font(.caption)
                .foregroundStyle(.secondary)

            excludedList

            HStack {
                addAppMenu
                Spacer()
                Button {
                    viewModel.refreshRunningApps()
                } label: {
                    Label("刷新应用列表", systemImage: "arrow.clockwise")
                }
            }
        }
        .padding(16)
    }

    private var excludedList: some View {
        Group {
            if settings.excludedBundleIDs.isEmpty {
                Text("尚未排除任何应用")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(settings.excludedBundleIDs, id: \.self) { bundleID in
                        HStack {
                            Image(nsImage: AppIconProvider.shared.icon(forBundleID: bundleID))
                                .resizable()
                                .frame(width: 18, height: 18)
                            Text(viewModel.displayName(forBundleID: bundleID))
                            Spacer()
                            Button {
                                settings.removeExcluded(bundleID: bundleID)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.2))
        )
    }

    private var addAppMenu: some View {
        Menu {
            ForEach(viewModel.runningApps) { app in
                if !settings.excludedBundleIDs.contains(app.bundleID) {
                    Button {
                        settings.addExcluded(bundleID: app.bundleID)
                    } label: {
                        Text(app.name)
                    }
                }
            }
        } label: {
            Label("添加应用", systemImage: "plus")
        }
    }
}
