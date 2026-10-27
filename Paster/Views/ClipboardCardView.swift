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
    /// 打开设置窗口，供横向条布局下的齿轮入口使用（该布局没有标题栏可放按钮）。
    var openSettings: () -> Void
}

/// 单条剪贴板记录的卡片视图。
///
/// 第 2 轮新增：图片缩略图预览、来源应用图标 + 名称、类型标签、时间戳。
struct ClipboardCardView: View {
    let item: ClipboardItem
    let isSelected: Bool
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .background {
            // 阴影只挂在选中卡片的底板上：透明阴影照样要逐帧更新，滚动动画里每张可见卡片
            // 都会多一份阴影图层的开销（实测约占动画帧主线程时间的 7%）。
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            if isSelected && settings.selectionShadow {
                shape.fill(backgroundFill).shadow(color: .black.opacity(0.12), radius: 4, y: 1)
            } else {
                shape.fill(backgroundFill)
            }
        }
        .overlay {
            // 同理，透明描边也是每帧要比对的一个绘制节点，只在选中时挂上。
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.5)
            }
        }
        .onHover { hovering in isHovering = hovering }
        .animation(settings.listAnimations && !reduceMotion ? .easeOut(duration: 0.1) : nil, value: isSelected)
        // 悬停渐变是滚动时开销最大的动效（见 `EffectsOptions.hoverAnimation`），默认关闭。
        .animation(settings.hoverAnimation && !reduceMotion ? .easeOut(duration: 0.1) : nil, value: isHovering)
    }

    /// 选中 > 悬停 > 默认，三态背景色（语义色自动适配深色/浅色模式）。
    private var backgroundFill: Color {
        if isSelected { return Color.accentColor.opacity(0.08) }
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
        // 图标与文字合成一段 Text，少两个绘制节点（滚动时每帧都要遍历每张卡片的节点）。
        Text("\(Image(systemName: item.type.symbolName)) \(item.type.displayName)")
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
        // 解码结果按记录缓存，重绘不再重复解码；缺缩略图的旧记录才回退到原图。
        if let nsImage = ThumbnailCache.shared.image(for: item.id, data: item.thumbnailData ?? item.imageData) {
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
        // 横条 20 行 × 每行约 30 字、竖向 4 行就能填满卡片，多余文字只会白白参与排版。
        Text(item.previewSnippet(limit: fillHeight ? 800 : 240))
            .font(.system(size: 13))
            .lineLimit(fillHeight ? 20 : 4)
            .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
    }

    private var timestamp: some View {
        Text(item.createdAt, format: .relative(presentation: .named))
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}
