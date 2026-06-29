import SwiftUI
import SwiftData

/// 面板布局形态。
/// - `vertical`：跟随光标 / 屏幕侧边的竖向卡片列表（默认）。
/// - `bar`：停靠屏幕上/下边缘的全宽横向平铺条（类似 Paste，扫读效率更高）。
enum PanelLayout {
    case vertical
    case bar
}

/// 呼出面板的根视图。
///
/// 演进路线（增量，不推翻）：
/// - 第 1 轮：纯文本列表，点击/回车粘贴。
/// - 第 2 轮：卡片式布局 + 右键操作菜单。
/// - 第 3 轮：顶部实时搜索 + 来源筛选、Pin 固定与 Pinboard 分组、完整键盘交互、滚动性能优化。
/// - 第 6 轮：新增横向平铺底栏布局（`PanelLayout.bar`），支持左右键导航。
struct PanelRootView: View {
    @Query(sort: \ClipboardItem.createdAt, order: .reverse) private var items: [ClipboardItem]

    /// 选中项（用于键盘导航与回车粘贴）。
    @State private var selectedID: PersistentIdentifier?
    /// 搜索关键词。
    @State private var searchText: String = ""
    /// 来源应用筛选（nil 表示全部）。
    @State private var selectedApp: String?
    /// 搜索框聚焦状态。
    @FocusState private var searchFocused: Bool

    /// 面板可用操作集合，由 `AppDelegate` 注入。
    let actions: PanelActions

    /// 布局形态，由 `AppDelegate` 依据用户选择的呼出位置注入。
    var layout: PanelLayout = .vertical

    var body: some View {
        Group {
            switch layout {
            case .vertical: verticalBody
            case .bar:      barBody
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: layout == .bar ? 16 : 12, style: .continuous))
        .onAppear { onPanelAppear() }
        .onChange(of: orderedVisible.map(\.persistentModelID)) { _, _ in selectDefaultIfNeeded() }
    }

    // MARK: - 竖向布局（默认）

    private var verticalBody: some View {
        VStack(spacing: 0) {
            header
            SearchBarView(searchText: $searchText,
                          selectedApp: $selectedApp,
                          appNames: appNames,
                          focus: $searchFocused,
                          onKey: handleKeyPress)
            Divider()
            content
        }
        .frame(width: 360, height: 480)
    }

    // MARK: - 横向平铺底栏布局

    private var barBody: some View {
        VStack(spacing: 0) {
            barHeader
            Divider()
            barContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var barHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(.secondary)
            Text("Paster")
                .font(.headline)
            Text("\(orderedVisible.count) 条")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            SearchBarView(searchText: $searchText,
                          selectedApp: $selectedApp,
                          appNames: appNames,
                          focus: $searchFocused,
                          onKey: handleKeyPress)
                .frame(maxWidth: 360)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var barContent: some View {
        if orderedVisible.isEmpty {
            emptyState
        } else {
            barList
        }
    }

    private var barList: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // LazyHStack 仅渲染可见瓦片，支持大量历史横向流畅滚动。
                LazyHStack(spacing: 10) {
                    ForEach(orderedVisible) { tile(for: $0) }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private func tile(for item: ClipboardItem) -> some View {
        ClipboardCardView(item: item, isSelected: selectedID == item.persistentModelID, fillHeight: true)
            .frame(width: 210)
            .frame(maxHeight: .infinity)
            .id(item.persistentModelID)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { actions.paste(item) }
            .onTapGesture { selectedID = item.persistentModelID }
            .contextMenu { contextMenu(for: item) }
    }

    // MARK: - 头部

    private var header: some View {
        HStack {
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(.secondary)
            Text("Paster")
                .font(.headline)
            Spacer()
            Text("\(orderedVisible.count) 条")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if orderedVisible.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: items.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(items.isEmpty ? "暂无剪贴板历史" : "没有匹配的内容")
                .foregroundStyle(.secondary)
            if items.isEmpty {
                Text("复制文本、图片、文件或链接后会自动出现在这里")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // LazyVStack 仅渲染可见卡片，支持百条以上历史流畅滚动。
                LazyVStack(alignment: .leading, spacing: 8) {
                    if !pinnedItems.isEmpty {
                        sectionHeader("固定", systemImage: "pin.fill")
                        ForEach(pinnedItems) { card(for: $0) }
                    }
                    if !unpinnedItems.isEmpty {
                        if !pinnedItems.isEmpty {
                            sectionHeader("历史", systemImage: "clock")
                        }
                        ForEach(unpinnedItems) { card(for: $0) }
                    }
                }
                .padding(10)
            }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(title)
            Spacer()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private func card(for item: ClipboardItem) -> some View {
        ClipboardCardView(item: item, isSelected: selectedID == item.persistentModelID)
            .id(item.persistentModelID)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { actions.paste(item) }
            .onTapGesture { selectedID = item.persistentModelID }
            .contextMenu { contextMenu(for: item) }
    }

    @ViewBuilder
    private func contextMenu(for item: ClipboardItem) -> some View {
        Button("粘贴") { actions.paste(item) }
        Button("纯文本粘贴") { actions.pastePlain(item) }
        Button("重新复制") { actions.copy(item) }
        Button("全屏预览") { actions.preview(item) }
        Divider()
        Button(item.isPinned ? "取消固定" : "固定到顶部") { actions.togglePin(item) }
        Button("删除", role: .destructive) { actions.delete(item) }
    }

    // MARK: - 数据筛选与分组

    private var filteredItems: [ClipboardItem] {
        items.filter { item in
            let matchesApp = selectedApp == nil || item.sourceAppName == selectedApp
            let keyword = searchText.trimmingCharacters(in: .whitespaces)
            let matchesText = keyword.isEmpty
                || item.previewText.localizedCaseInsensitiveContains(keyword)
                || (item.sourceAppName?.localizedCaseInsensitiveContains(keyword) ?? false)
            return matchesApp && matchesText
        }
    }

    private var pinnedItems: [ClipboardItem] {
        filteredItems
            .filter(\.isPinned)
            .sorted { ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast) }
    }

    private var unpinnedItems: [ClipboardItem] {
        filteredItems.filter { !$0.isPinned }
    }

    /// 键盘导航使用的扁平有序列表（固定在前）。
    private var orderedVisible: [ClipboardItem] {
        pinnedItems + unpinnedItems
    }

    private var appNames: [String] {
        Array(Set(items.compactMap(\.sourceAppName))).sorted()
    }

    private var selectedItem: ClipboardItem? {
        guard let selectedID else { return nil }
        return orderedVisible.first { $0.persistentModelID == selectedID }
    }

    // MARK: - 键盘交互

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        switch keyPress.key {
        case .escape:
            actions.dismiss()
            return .handled
        case .upArrow:
            moveSelection(by: -1)
            return .handled
        case .downArrow:
            moveSelection(by: 1)
            return .handled
        case .leftArrow where layout == .bar:
            // 横向布局下用左右键导航；竖向布局保留方向键在搜索框内移动光标。
            moveSelection(by: -1)
            return .handled
        case .rightArrow where layout == .bar:
            moveSelection(by: 1)
            return .handled
        case .return:
            if let item = selectedItem {
                actions.paste(item)
                return .handled
            }
            return .ignored
        default:
            break
        }

        // 带 ⌘ 修饰键的快捷操作，避免与文本输入冲突。
        if keyPress.modifiers.contains(.command) {
            if keyPress.key == .delete, let item = selectedItem {
                deleteAndAdvance(item)
                return .handled
            }
            if keyPress.characters == "p", let item = selectedItem {
                actions.togglePin(item)
                return .handled
            }
            if keyPress.characters == "y", let item = selectedItem {
                actions.preview(item)
                return .handled
            }
        }
        return .ignored
    }

    private func moveSelection(by delta: Int) {
        let ids = orderedVisible.map(\.persistentModelID)
        guard !ids.isEmpty else { return }
        if let selectedID, let index = ids.firstIndex(of: selectedID) {
            let next = max(0, min(ids.count - 1, index + delta))
            self.selectedID = ids[next]
        } else {
            selectedID = delta >= 0 ? ids.first : ids.last
        }
    }

    private func deleteAndAdvance(_ item: ClipboardItem) {
        let ids = orderedVisible.map(\.persistentModelID)
        let index = ids.firstIndex(of: item.persistentModelID)
        actions.delete(item)
        if let index {
            let remaining = ids.count - 1
            if remaining > 0 {
                selectedID = ids[min(index, remaining - 1)]
            } else {
                selectedID = nil
            }
        }
    }

    // MARK: - 生命周期

    private func onPanelAppear() {
        selectDefaultIfNeeded()
        // 呼出后自动聚焦搜索框。
        DispatchQueue.main.async { searchFocused = true }
    }

    private func selectDefaultIfNeeded() {
        if selectedID == nil || selectedItem == nil {
            selectedID = orderedVisible.first?.persistentModelID
        }
    }
}
