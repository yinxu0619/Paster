import SwiftUI
import SwiftData
import AppKit

/// 横向平铺条下用鼠标滚轮左右选择条目（触控板的精确滚动仍交给 ScrollView 自然滚动）。
@MainActor
final class WheelSelector: ObservableObject {
    private var monitor: Any?
    /// 触控板精确滚动的累加器与阈值（避免一滑就跳很多项）。
    private var accumulated: CGFloat = 0
    private let preciseThreshold: CGFloat = 10

    var ids: [PersistentIdentifier] = []
    var current: PersistentIdentifier?
    var onSelect: ((PersistentIdentifier?) -> Void)?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            // 只处理悬浮面板上的滚轮，避免误吞设置等其它窗口的滚动事件。
            guard event.window is FloatingPanel else { return event }

            // 取主轴位移：鼠标滚轮多为垂直，触控板可垂直或水平，统一映射为左右切换。
            let dy = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
            let dx = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.deltaX
            let delta = abs(dx) > abs(dy) ? dx : dy
            guard delta != 0 else { return event }

            if event.hasPreciseScrollingDeltas {
                // 触控板：累加到阈值即走格，滑得越快一次跨越的格数越多；滑动结束时清零。
                accumulated += delta
                let steps = Int(accumulated / preciseThreshold)
                if steps != 0 {
                    let direction = steps < 0 ? 1 : -1
                    for _ in 0..<abs(steps) { self.step(direction) }
                    accumulated -= CGFloat(steps) * preciseThreshold
                }
                if event.phase == .ended || event.momentumPhase == .ended {
                    accumulated = 0
                }
            } else {
                // 鼠标滚轮：每个刻度走一格。
                self.step(delta < 0 ? 1 : -1)
            }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func step(_ direction: Int) {
        guard !ids.isEmpty else { return }
        if let current, let index = ids.firstIndex(of: current) {
            let next = max(0, min(ids.count - 1, index + direction))
            onSelect?(ids[next])
        } else {
            onSelect?(direction >= 0 ? ids.first : ids.last)
        }
    }
}

/// 在面板上拦截删除键以删除选中记录。
///
/// 搜索框默认聚焦时，SwiftUI 的 `TextField` 会优先消费退格 / 删除键，导致
/// 挂在文本框上的 `.onKeyPress` 收不到事件。这里用与 `WheelSelector` 相同的
/// `.keyDown` 本地监听，直接在 `FloatingPanel` 层拦截，绕开文本框的吞键。
@MainActor
final class KeyboardSelector: ObservableObject {
    private var monitor: Any?

    /// 搜索框是否为空（退格键仅在为空时用于删除记录，否则交还文本框编辑）。
    var searchEmpty: Bool = true
    /// 当前是否有选中项。
    var hasSelection: Bool = false
    /// 删除当前选中项的回调。
    var onDelete: (() -> Void)?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // 只处理悬浮面板上的按键，避免误吞设置等其它窗口的键盘事件。
            guard event.window is FloatingPanel else { return event }

            // 仅响应不带修饰键的删除键（⌘⌫ 等组合仍由原有逻辑处理）。
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard mods.isEmpty else { return event }

            switch event.keyCode {
            case 117:  // 前向删除（Del / fn+Delete）：直接删除选中项。
                guard self.hasSelection else { return event }
                self.onDelete?()
                return nil
            case 51:   // 退格（Delete）：搜索框为空时删除选中项，否则留给文本框编辑。
                guard self.searchEmpty, self.hasSelection else { return event }
                self.onDelete?()
                return nil
            default:
                return event
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

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
    @ObservedObject private var settings = AppSettings.shared

    /// 选中项（用于键盘导航与回车粘贴）。
    @State private var selectedID: PersistentIdentifier?
    /// 需要滚动到可见位置的目标项。仅在键盘 / 滚轮导航时设置，鼠标点选不触发，
    /// 避免点右侧卡片时视图自动把它滚到居中。
    @State private var scrollTargetID: PersistentIdentifier?
    /// 搜索关键词。
    @State private var searchText: String = ""
    /// 来源应用筛选（nil 表示全部）。
    @State private var selectedApp: String?
    /// 搜索框聚焦状态。
    @FocusState private var searchFocused: Bool
    /// 横向条滚轮选择器。
    @StateObject private var wheel = WheelSelector()
    /// 删除键拦截器（绕开搜索框对退格 / 删除键的吞键）。
    @StateObject private var keyboard = KeyboardSelector()

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
        // 不在 onDisappear 里停监听：面板内容会被复用，隐藏/再呼出时 onAppear 未必重新触发，
        // 停了就再也起不来（滚轮失效）。监听器已按 `event.window is FloatingPanel` 过滤，
        // 常驻不会影响其它窗口；视图真正销毁时由各自 deinit 统一清理。
        .onChange(of: orderedVisible.map(\.persistentModelID)) { _, _ in
            selectDefaultIfNeeded()
            syncWheel()
        }
        .onChange(of: selectedID) { _, id in
            wheel.current = id
            keyboard.hasSelection = (id != nil)
        }
        .onChange(of: searchText) { _, text in keyboard.searchEmpty = text.isEmpty }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.panelWillShowNotification)) { _ in
            prepareForShow()
        }
        .id(settings.appLanguage)
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
        // 填满承载窗口：光标/居中为 360×480，左右侧栏为满屏高度（由 AppDelegate 设定窗口尺寸）。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Text(L10n.tr("panel.itemCount", Int64(orderedVisible.count)))
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
            .onChange(of: scrollTargetID) { _, id in
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
            // 单击用 simultaneousGesture 即时选中，避免与双击互斥时被延迟约 0.3s。
            .onTapGesture(count: 2) { actions.paste(item) }
            .simultaneousGesture(TapGesture(count: 1).onEnded { selectedID = item.persistentModelID })
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
            Text(L10n.tr("panel.itemCount", Int64(orderedVisible.count)))
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
            Text(items.isEmpty ? L10n.tr("panel.emptyHistory") : L10n.tr("panel.noMatch"))
                .foregroundStyle(.secondary)
            if items.isEmpty {
                Text(L10n.tr("panel.emptyHint"))
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
                        sectionHeader(L10n.tr("panel.pinned"), systemImage: "pin.fill")
                        ForEach(pinnedItems) { card(for: $0) }
                    }
                    if !unpinnedItems.isEmpty {
                        if !pinnedItems.isEmpty {
                            sectionHeader(L10n.tr("panel.history"), systemImage: "clock")
                        }
                        ForEach(unpinnedItems) { card(for: $0) }
                    }
                }
                .padding(10)
            }
            .onChange(of: scrollTargetID) { _, id in
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
            // 单击用 simultaneousGesture 即时选中，避免与双击互斥时被延迟约 0.3s。
            .onTapGesture(count: 2) { actions.paste(item) }
            .simultaneousGesture(TapGesture(count: 1).onEnded { selectedID = item.persistentModelID })
            .contextMenu { contextMenu(for: item) }
    }

    @ViewBuilder
    private func contextMenu(for item: ClipboardItem) -> some View {
        Button(L10n.tr("menu.paste")) { actions.paste(item) }
        Button(L10n.tr("menu.pastePlain")) { actions.pastePlain(item) }
        Button(L10n.tr("menu.copy")) { actions.copy(item) }
        Button(L10n.tr("menu.preview")) { actions.preview(item) }
        Divider()
        Button(item.isPinned ? L10n.tr("menu.unpin") : L10n.tr("menu.pin")) { actions.togglePin(item) }
        Button(L10n.tr("menu.delete"), role: .destructive) { actions.delete(item) }
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
        // 可配置的「无格式粘贴」快捷键（默认 ⌘⇧↩）：需在普通回车之前判断。
        let relevant: EventModifiers = [.command, .shift, .option, .control]
        if keyPress.key == .return,
           keyPress.modifiers.intersection(relevant) == AppSettings.shared.plainPasteShortcut.eventModifiers,
           let item = selectedItem {
            actions.pastePlain(item)
            return .handled
        }

        switch keyPress.key {
        case .escape:
            actions.dismiss()
            return .handled
        case .home:
            if let first = orderedVisible.first?.persistentModelID { selectAndScroll(first) }
            return .handled
        case .end:
            if let last = orderedVisible.last?.persistentModelID { selectAndScroll(last) }
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
        case .deleteForward:
            // 外接键盘 Del / fn+Delete：直接删除选中项。
            if let item = selectedItem {
                deleteAndAdvance(item)
                return .handled
            }
            return .ignored
        case .delete where !keyPress.modifiers.contains(.command):
            // 笔记本 Delete（退格）：搜索框为空时删除选中项，否则留给搜索框编辑。
            if searchText.isEmpty, let item = selectedItem {
                deleteAndAdvance(item)
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
            selectAndScroll(ids[next])
        } else {
            selectAndScroll(delta >= 0 ? ids.first : ids.last)
        }
    }

    /// 选中并滚动到目标项（用于键盘 / 滚轮导航；鼠标点选不走这里，故不会自动居中）。
    private func selectAndScroll(_ id: PersistentIdentifier?) {
        selectedID = id
        scrollTargetID = id
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
        prepareForShow()
    }

    /// 每次呼出时的准备：重置搜索与选中、聚焦搜索框，并确保监听已启动。
    ///
    /// 内容视图被复用（未重建）时 `onAppear` 不会再次触发，因此呼出时统一走这里，
    /// 保证复用与重建两种路径下行为一致；回调也在此赋值，避免预建控制器时尚未设置。
    private func prepareForShow() {
        // 横向条模式下启用鼠标滚轮左右选择（滚轮导航需要滚动到可见位置）。
        wheel.onSelect = { id in selectAndScroll(id) }
        // 删除键拦截：搜索框聚焦时也能用 Del / 退格删除选中记录。
        keyboard.onDelete = { if let item = selectedItem { deleteAndAdvance(item) } }

        searchText = ""
        if layout == .bar { wheel.start() }
        keyboard.start()
        // 清空搜索后于下一轮 runloop 读取最新列表，选中首项并聚焦搜索框。
        DispatchQueue.main.async {
            selectAndScroll(orderedVisible.first?.persistentModelID)
            syncWheel()
            keyboard.searchEmpty = searchText.isEmpty
            keyboard.hasSelection = (selectedItem != nil)
            searchFocused = true
        }
    }

    /// 同步滚轮选择器的候选列表与当前选中项。
    private func syncWheel() {
        wheel.ids = orderedVisible.map(\.persistentModelID)
        wheel.current = selectedID
    }

    private func selectDefaultIfNeeded() {
        if selectedID == nil || selectedItem == nil {
            selectedID = orderedVisible.first?.persistentModelID
        }
    }
}
