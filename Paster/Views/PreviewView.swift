import SwiftUI

/// 单条记录的全屏 / 大窗预览（第 5 轮新增）。
///
/// 图片以原图等比铺满并可滚动查看（保证高 DPI 下清晰度）；文本/链接/文件
/// 以可选中的滚动文本展示。按 Esc 关闭。
struct PreviewView: View {
    let item: ClipboardItem
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            previewContent
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand { onClose() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(nsImage: AppIconProvider.shared.icon(forBundleID: item.sourceBundleID))
                .resizable()
                .frame(width: 18, height: 18)
            Text(item.sourceAppName ?? L10n.tr("preview.unknownSource"))
                .foregroundStyle(.secondary)
            Spacer()
            Label(item.type.displayName, systemImage: item.type.symbolName)
                .foregroundStyle(.secondary)
            Text(item.createdAt, format: .dateTime.year().month().day().hour().minute())
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var previewContent: some View {
        switch item.type {
        case .image:
            imagePreview
        default:
            ScrollView {
                Text(item.previewText.isEmpty ? L10n.tr("preview.emptyContent") : item.previewText)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let data = item.imageData, let nsImage = NSImage(data: data) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)
            }
        } else {
            ContentUnavailableView(L10n.tr("preview.imageFailed"), systemImage: "photo")
        }
    }
}
