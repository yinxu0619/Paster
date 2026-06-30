import SwiftUI
import AppKit

/// 关于页（第 6 轮新增）：应用简介 + 赞赏码（微信 / 支付宝 / PayPal）。
struct AboutView: View {
    @ObservedObject private var settings = AppSettings.shared
    private let payPalURL = URL(string: "https://www.paypal.com/paypalme/yinxu0619")!

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(v) (\(b))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                Divider()
                intro
                Divider()
                donate
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .id(settings.appLanguage)
    }

    // MARK: - 头部

    private var header: some View {
        VStack(spacing: 8) {
            if let icon = NSImage(named: "Paster") ?? NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 72, height: 72)
            }
            Text("Paster")
                .font(.title2.weight(.semibold))
            Text(appVersion)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 简介

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("about.intro"))
                .font(.headline)
            Text(L10n.tr("about.description"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 赞赏

    private var donate: some View {
        VStack(spacing: 12) {
            Text(L10n.tr("about.donate"))
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 20) {
                qrColumn(title: L10n.tr("about.wechat"), imageName: "donate_wechat", tint: .green)
                qrColumn(title: L10n.tr("about.alipay"), imageName: "donate_alipay", tint: .blue)
            }

            Link(destination: payPalURL) {
                Label(L10n.tr("about.paypal"), systemImage: "link")
            }
            .font(.callout)

            Text(L10n.tr("about.thanks"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func qrColumn(title: String, imageName: String, tint: Color) -> some View {
        VStack(spacing: 6) {
            qrImage(named: imageName)
                .frame(width: 150, height: 150)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(tint.opacity(0.4), lineWidth: 1)
                )
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 从 App Bundle 的 Resources 中加载赞赏码图片（随打包脚本一并拷入）。
    @ViewBuilder
    private func qrImage(named name: String) -> some View {
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .padding(6)
        } else {
            Image(systemName: "qrcode")
                .resizable()
                .scaledToFit()
                .padding(24)
                .foregroundStyle(.secondary)
        }
    }
}
