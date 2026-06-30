import SwiftUI

/// 顶部搜索栏：实时关键词搜索 + 来源应用筛选。
///
/// 第 3 轮新增。键盘事件（↑↓ 选择、回车粘贴、⌘⌫ 删除、⌘P 固定）由外部
/// 通过 `onKey` 回调统一处理，使搜索框聚焦时仍可进行列表导航。
struct SearchBarView: View {
    @Binding var searchText: String
    @Binding var selectedApp: String?
    let appNames: [String]
    var focus: FocusState<Bool>.Binding
    var onKey: (KeyPress) -> KeyPress.Result

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(L10n.tr("search.placeholder"), text: $searchText)
                .textFieldStyle(.plain)
                .focused(focus)
                .onKeyPress(action: onKey)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            appFilterMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var appFilterMenu: some View {
        Menu {
            Button {
                selectedApp = nil
            } label: {
                Label(L10n.tr("search.allSources"), systemImage: selectedApp == nil ? "checkmark" : "")
            }
            if !appNames.isEmpty {
                Divider()
                ForEach(appNames, id: \.self) { name in
                    Button {
                        selectedApp = name
                    } label: {
                        Label(name, systemImage: selectedApp == name ? "checkmark" : "")
                    }
                }
            }
        } label: {
            Image(systemName: selectedApp == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(selectedApp == nil ? Color.secondary : Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
