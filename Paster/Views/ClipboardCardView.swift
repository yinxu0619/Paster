import SwiftUI

/// 面板可用的操作集合，由 `AppDelegate` 注入，连接视图与视图模型 / 面板控制。
struct PanelActions {
    var paste: (ClipboardItem) -> Void
    var pastePlain: (ClipboardItem) -> Void
    var copy: (ClipboardItem) -> Void
    var delete: (ClipboardItem) -> Void
    /// 第 3 轮新增：切换固定状态。
    var togglePin: (ClipboardItem) -> Void
    /// 第 5 轮新增：全屏预览。
    var preview: (ClipboardItem) -> Void
    /// 第 6 轮新增：关闭/收起面板（Esc）。
    var dismiss: () -> Void
}

/// 单条剪贴板记录的卡片视图。
///
/// 第 2 轮新增：图片缩略图预览、来源应用图标 + 名称、类型标签、时间戳。
struct ClipboardCardView: View {
    let item: ClipboardItem
    let isSelected: Bool

    /// 横向平铺条模式下让卡片纵向填满，并放大图片 / 多展示文本（第 6 轮新增）。
    var fillHeight: Bool = false

    /// 鼠标悬停状态，用于第 5 轮的悬停反馈动效。
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            contentBody
            if fillHeight { Spacer(minLength: 4) }
            timestamp
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(backgroundFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.8) : Color.clear, lineWidth: 1.5)
        )
        .scaleEffect(isSelected ? 1.0 : (isHovering ? 0.995 : 1.0))
        .shadow(color: .black.opacity(isSelected ? 0.12 : 0), radius: 4, y: 1)
        .onHover { hovering in isHovering = hovering }
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }

    /// 选中 > 悬停 > 默认，三态背景色（语义色自动适配深色/浅色模式）。
    private var backgroundFill: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        if isHovering { return Color.primary.opacity(0.08) }
        return Color.primary.opacity(0.04)
    }

    // MARK: - 头部：来源应用 + 类型标签 + 时间

    private var headerRow: some View {
        HStack(spacing: 6) {
            Image(nsImage: AppIconProvider.shared.icon(forBundleID: item.sourceBundleID))
                .resizable()
                .frame(width: 16, height: 16)
            Text(item.sourceAppName ?? L10n.tr("card.unknownSource"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            typeBadge
        }
    }

    private var typeBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: item.type.symbolName)
            Text(item.type.displayName)
        }
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.secondary.opacity(0.15)))
        .foregroundStyle(.secondary)
    }

    // MARK: - 内容预览

    @ViewBuilder
    private var contentBody: some View {
        switch item.type {
        case .image:
            imagePreview
        default:
            textPreview
        }
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let data = item.thumbnailData ?? item.imageData,
           let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : 120, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Label(L10n.tr("card.image"), systemImage: "photo")
                .foregroundStyle(.secondary)
        }
    }

    private var textPreview: some View {
        Text(item.previewText)
            .font(.system(size: 13))
            .lineLimit(fillHeight ? nil : 4)
            .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
    }

    private var timestamp: some View {
        Text(item.createdAt, format: .relative(presentation: .named))
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}
