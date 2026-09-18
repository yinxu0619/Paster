import SwiftUI
import SwiftData
import AppKit

/// 横向平铺条下用鼠标滚轮左右选择条目（触控板的精确滚动仍交给 ScrollView 自然滚动）。
@MainActor
final class WheelSelector: ObservableObject {
    private var monitor: Any?
    /// 鼠标滚轮离散步进的时间节流：一个物理刻度常连发多个事件，
    /// 用最小间隔把「一圈」限制为一格，避免滚一下就窜过好几项。
    private var lastMouseStepAt: TimeInterval = 0
    private let mouseStepInterval: TimeInterval = 0.11

    var ids: [PersistentIdentifier] = []
    var current: PersistentIdentifier?
    var onSelect: ((PersistentIdentifier?) -> Void)?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            // 只处理悬浮面板上的滚轮，避免误吞设置等其它窗口的滚动事件。
            guard event.window is FloatingPanel else { return event }

            // Preserve native trackpad scrolling, including momentum and end events.
            guard !event.hasPreciseScrollingDeltas else { return event }

            // 离散鼠标滚轮仍按格切换，触控板不改变选中项。
            let dy = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
            let dx = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.deltaX
            let delta = abs(dx) > abs(dy) ? dx : dy
            guard delta != 0 else { return event }

            let now = ProcessInfo.processInfo.systemUptime
            if now - lastMouseStepAt >= mouseStepInterval {
                lastMouseStepAt = now
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
            self.current = ids[next]
            onSelect?(self.current)
        } else {
            current = direction >= 0 ? ids.first : ids.last
            onSelect?(current)
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

enum ClipboardSelection {
    static func afterDeleting<ID: Equatable>(_ deleted: ID, from ids: [ID]) -> ID? {
        guard let index = ids.firstIndex(of: deleted) else { return ids.first }
        var remaining = ids
        remaining.remove(at: index)
        return remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)]
    }
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
    private struct ScrollRequest: Equatable {
        let id: PersistentIdentifier
        let animated: Bool
        // Repeat navigation after manually scrolling away must still reveal the item.
        let token = UUID()
    }
    @State private var scrollRequest: ScrollRequest?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 搜索关键词。
    @State private var searchText: String = ""
    @State private var filterKeyword = ""
    @State private var pinnedIDs: [PersistentIdentifier] = []
    @State private var unpinnedIDs: [PersistentIdentifier] = []
    @State private var appNames: [String] = []

    private struct ItemRevision: Equatable {
        let id: PersistentIdentifier
        let pinned: Bool
        let pinnedAt: Date?
    }

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
        // 一次 body 只解析一遍可见项，子视图全部复用，避免各处反复重建全量字典。
        let visible = resolveVisible()
        return Group {
            switch layout {
            case .vertical: verticalBody(visible)
            case .bar:      barBody(visible)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: layout == .bar ? 16 : 12, style: .continuous))
        .onAppear { onPanelAppear() }
        .onChange(of: items.map { ItemRevision(id: $0.persistentModelID, pinned: $0.isPinned, pinnedAt: $0.pinnedAt) }) { _, _ in
            rebuildVisibleItems()
        }
        .onChange(of: selectedApp) { _, _ in rebuildVisibleItems() }
        .task(id: searchText) {
            if !searchText.isEmpty {
                do { try await Task.sleep(for: .milliseconds(120)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            filterKeyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            rebuildVisibleItems()
        }
        // 不在 onDisappear 里停监听：面板内容会被复用，隐藏/再呼出时 onAppear 未必重新触发，
        // 停了就再也起不来（滚轮失效）。监听器已按 `event.window is FloatingPanel` 过滤，
        // 常驻不会影响其它窗口；视图真正销毁时由各自 deinit 统一清理。
        .onChange(of: visible.ordered.map(\.persistentModelID)) { _, _ in
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

    private func verticalBody(_ visible: VisibleItems) -> some View {
        VStack(spacing: 0) {
            header(visible)
            SearchBarView(searchText: $searchText,
                          selectedApp: $selectedApp,
                          appNames: appNames,
                          focus: $searchFocused,
                          onKey: handleKeyPress)
            Divider()
            content(visible)
        }
        // 填满承载窗口：光标/居中为 360×480，左右侧栏为满屏高度（由 AppDelegate 设定窗口尺寸）。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 横向平铺底栏布局

    private func barBody(_ visible: VisibleItems) -> some View {
        VStack(spacing: 0) {
            barHeader(visible)
            Divider()
            barContent(visible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func barHeader(_ visible: VisibleItems) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(.secondary)
            Text("Paster")
                .font(.headline)
            Text(L10n.tr("panel.itemCount", Int64(visible.ordered.count)))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            SearchBarView(searchText: $searchText,
                          selectedApp: $selectedApp,
                          appNames: appNames,
                          focus: $searchFocused,
                          onKey: handleKeyPress)
                .frame(maxWidth: 360)
            // 横向条布局折叠了标题栏，没有别处能进入设置，这里补一个齿轮入口。
            Button { actions.openSettings() } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L10n.tr("menu.settings"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func barContent(_ visible: VisibleItems) -> some View {
        if visible.ordered.isEmpty {
            emptyState
        } else {
            barList(visible)
        }
    }

    private func barList(_ visible: VisibleItems) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // LazyHStack 仅渲染可见瓦片，支持大量历史横向流畅滚动。
                LazyHStack(spacing: 10) {
                    ForEach(visible.ordered) { tile(for: $0) }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: scrollRequest) { _, request in
                guard let request else { return }
                reveal(request, using: proxy)
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

    private func header(_ visible: VisibleItems) -> some View {
        HStack {
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(.secondary)
            Text("Paster")
                .font(.headline)
            Spacer()
            Text(L10n.tr("panel.itemCount", Int64(visible.ordered.count)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: - 内容

    @ViewBuilder
    private func content(_ visible: VisibleItems) -> some View {
        if visible.ordered.isEmpty {
            emptyState
        } else {
            list(visible)
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

    private func list(_ visible: VisibleItems) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // LazyVStack 仅渲染可见卡片，支持百条以上历史流畅滚动。
                LazyVStack(alignment: .leading, spacing: 8) {
                    if !visible.pinned.isEmpty {
                        sectionHeader(L10n.tr("panel.pinned"), systemImage: "pin.fill")
                        ForEach(visible.pinned) { card(for: $0) }
                    }
                    if !visible.unpinned.isEmpty {
                        if !visible.pinned.isEmpty {
                            sectionHeader(L10n.tr("panel.history"), systemImage: "clock")
                        }
                        ForEach(visible.unpinned) { card(for: $0) }
                    }
                }
                .padding(10)
            }
            .onChange(of: scrollRequest) { _, request in
                guard let request else { return }
                reveal(request, using: proxy)
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
        // 各项右侧显示快捷键（与下方 handleKeyPress / KeyboardSelector 的选中态快捷键一致）。
        // contextMenu 内容按需惰性构建，这里的 keyboardShortcut 仅作提示、且只在菜单打开时生效，
        // 不会与列表里逐条卡片重复注册全局快捷键。
        Button(L10n.tr("menu.paste")) { actions.paste(item) }
            .keyboardShortcut(.return, modifiers: [])
        Button(L10n.tr("menu.pastePlain")) { actions.pastePlain(item) }
            .keyboardShortcut(.return, modifiers: settings.plainPasteShortcut.eventModifiers)
        Button(L10n.tr("menu.copy")) { actions.copy(item) }
            .keyboardShortcut("c", modifiers: .command)
        Divider()
        Button(L10n.tr("menu.preview")) { actions.preview(item) }
            .keyboardShortcut("y", modifiers: .command)
        Button(item.isPinned ? L10n.tr("menu.unpin") : L10n.tr("menu.pin")) { actions.togglePin(item) }
            .keyboardShortcut("p", modifiers: .command)
        Divider()
        Button(L10n.tr("menu.delete"), role: .destructive) { actions.delete(item) }
            .keyboardShortcut(.delete, modifiers: [])
    }

    // MARK: - 数据筛选与分组

    private func rebuildVisibleItems() {
        let keyword = filterKeyword
        let filtered = items.filter { item in
            guard selectedApp == nil || item.sourceAppName == selectedApp else { return false }
            return keyword.isEmpty
                || item.previewText.localizedCaseInsensitiveContains(keyword)
                || (item.sourceAppName?.localizedCaseInsensitiveContains(keyword) ?? false)
        }
        pinnedIDs = filtered.filter(\.isPinned)
            .sorted { ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast) }
            .map(\.persistentModelID)
        unpinnedIDs = filtered.filter { !$0.isPinned }.map(\.persistentModelID)
        appNames = Array(Set(items.compactMap(\.sourceAppName))).sorted()
    }

    /// 一次解析得到的可见项分组；`body` 里解析一次后传给各子视图。
    private struct VisibleItems {
        var pinned: [ClipboardItem]
        var unpinned: [ClipboardItem]
        var ordered: [ClipboardItem]
    }

    // Cache identities rather than models: after a deletion @Query can update before
    // onChange rebuilds the cache. Resolve only live rows so a card never reads a deleted model.
    private func resolveVisible() -> VisibleItems {
        let live = Dictionary(uniqueKeysWithValues: items.map { ($0.persistentModelID, $0) })
        let pinned = pinnedIDs.compactMap { live[$0] }
        let unpinned = unpinnedIDs.compactMap { live[$0] }
        return VisibleItems(pinned: pinned, unpinned: unpinned, ordered: pinned + unpinned)
    }

    /// 事件处理（键盘 / 滚轮 / 删除）里按需解析一次；渲染路径不要用它，用 `body` 里的 `visible`。
    private var orderedVisible: [ClipboardItem] { resolveVisible().ordered }

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
            if keyPress.characters == "c", let item = selectedItem {
                actions.copy(item)
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

    /// Reveal only the obscured edge; visible cards keep their position.
    private func reveal(_ request: ScrollRequest, using proxy: ScrollViewProxy) {
        let animated = request.animated && settings.listAnimations && !reduceMotion
        var transaction = Transaction(animation: animated ? .easeOut(duration: 0.18) : nil)
        transaction.disablesAnimations = !animated
        withTransaction(transaction) {
            // With no anchor, SwiftUI moves only enough to make the card wholly visible.
            proxy.scrollTo(request.id)
        }
    }

    private func selectAndScroll(_ id: PersistentIdentifier?, animated: Bool = true) {
        selectedID = id
        wheel.current = id
        scrollRequest = id.map { ScrollRequest(id: $0, animated: animated) }
    }

    private func deleteAndAdvance(_ item: ClipboardItem) {
        let next = ClipboardSelection.afterDeleting(item.persistentModelID,
            from: orderedVisible.map(\.persistentModelID))
        actions.delete(item)
        selectedID = next
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
        filterKeyword = ""
        rebuildVisibleItems()
        scrollRequest = nil
        if layout == .bar { wheel.start() }
        keyboard.start()
        // 下一轮 runloop 读取最新列表：保留上次的选中项（呼出之间不重置），
        // 仅当该项已不存在（被删除 / 超出历史上限）时才回退到首项。
        DispatchQueue.main.async {
            let keepsSelection = selectedID != nil
                && orderedVisible.contains { $0.persistentModelID == selectedID }
            let target = keepsSelection ? selectedID : orderedVisible.first?.persistentModelID
            // Restore position without a second animation during panel entrance.
            selectAndScroll(target, animated: false)
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
