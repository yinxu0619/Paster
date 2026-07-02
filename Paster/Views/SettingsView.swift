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
                .tabItem { Label(L10n.tr("tab.general"), systemImage: "gearshape") }
            privacyTab
                .tabItem { Label(L10n.tr("tab.privacy"), systemImage: "hand.raised") }
            AboutView()
                .tabItem { Label(L10n.tr("tab.about"), systemImage: "info.circle") }
        }
        .frame(width: 460, height: 420)
        .id(settings.appLanguage)
    }

    // MARK: - 通用

    private var generalTab: some View {
        Form {
            Section(L10n.tr("settings.language")) {
                Picker(L10n.tr("settings.languagePicker"), selection: $settings.appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            }

            Section(L10n.tr("settings.startup")) {
                Toggle(L10n.tr("settings.launchAtLogin"), isOn: $settings.launchAtLogin)
            }

            Section(L10n.tr("settings.shortcuts")) {
                HStack {
                    Text(L10n.tr("settings.showPanel"))
                    Spacer()
                    HotKeyRecorder(keyCode: $settings.hotKeyCode, modifiers: $settings.hotKeyModifiers,
                                   languageToken: settings.appLanguage.rawValue)
                        .frame(width: 150, height: 24)
                    Button(L10n.tr("settings.resetDefault")) { settings.resetHotKeyToDefault() }
                }
                Text(L10n.tr("settings.hotkeyHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(L10n.tr("settings.plainPaste"), selection: $settings.plainPasteShortcut) {
                    ForEach(PlainPasteShortcut.allCases) { shortcut in
                        Text(shortcut.displayName).tag(shortcut)
                    }
                }
                Text(L10n.tr("settings.plainPasteHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.tr("settings.panelPosition")) {
                Picker(L10n.tr("settings.panelPositionPicker"), selection: $settings.panelPosition) {
                    ForEach(PanelPosition.allCases) { position in
                        Text(position.displayName).tag(position)
                    }
                }
                Text(L10n.tr("settings.panelPositionHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.panelPosition == .bottom || settings.panelPosition == .top {
                    Toggle(L10n.tr("settings.barAttachEdge"), isOn: $settings.barAttachToScreenEdge)
                    Text(L10n.tr("settings.barAttachEdgeHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(L10n.tr("settings.barHeight"))
                            Spacer()
                            Text(L10n.tr("settings.barHeightUnit", Int(settings.barHeight)))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $settings.barHeight,
                               in: AppSettings.barHeightRange,
                               step: 10) {
                            Text(L10n.tr("settings.barHeight"))
                        } minimumValueLabel: {
                            Image(systemName: "rectangle.compress.vertical")
                        } maximumValueLabel: {
                            Image(systemName: "rectangle.expand.vertical")
                        }
                        barHeightPreview
                        Text(L10n.tr("settings.barHeightHint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section(L10n.tr("settings.history")) {
                Stepper(value: $settings.historyLimit, in: 20...2000, step: 20) {
                    HStack {
                        Text(L10n.tr("settings.historyLimit"))
                        Spacer()
                        Text(L10n.tr("settings.historyLimitCount", settings.historyLimit))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(L10n.tr("settings.historyLimitHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(role: .destructive) {
                    showingClearConfirm = true
                } label: {
                    Label(L10n.tr("settings.clearAllHistory"), systemImage: "trash")
                }
                .confirmationDialog(L10n.tr("settings.clearConfirm"),
                                    isPresented: $showingClearConfirm,
                                    titleVisibility: .visible) {
                    Button(L10n.tr("settings.clear"), role: .destructive) {
                        viewModel.clearAllHistory()
                    }
                    Button(L10n.tr("settings.cancel"), role: .cancel) {}
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
            Text(L10n.tr("settings.excludedApps"))
                .font(.headline)
            Text(L10n.tr("settings.excludedAppsHint"))
                .font(.caption)
                .foregroundStyle(.secondary)

            excludedList

            HStack {
                addAppMenu
                Spacer()
                Button {
                    viewModel.refreshRunningApps()
                } label: {
                    Label(L10n.tr("settings.refreshApps"), systemImage: "arrow.clockwise")
                }
            }
        }
        .padding(16)
    }

    private var excludedList: some View {
        Group {
            if settings.excludedBundleIDs.isEmpty {
                Text(L10n.tr("settings.noExcludedApps"))
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
            Label(L10n.tr("settings.addApp"), systemImage: "plus")
        }
    }
}
