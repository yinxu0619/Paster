import SwiftUI
import AppKit

/// 关于页（第 6 轮新增）：应用简介 + 赞赏码（微信 / 支付宝 / PayPal）。
struct AboutView: View {
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
            Text("简介")
                .font(.headline)
            Text("Paster 是一款 macOS 原生剪贴板管理工具：后台自动记录文本、富文本、图片、文件与链接，"
                 + "支持全局热键呼出、搜索筛选、固定置顶与多模式粘贴。数据 100% 本地存储，不联网、不上传。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 赞赏

    private var donate: some View {
        VStack(spacing: 12) {
            Text("如果觉得好用，欢迎请作者喝杯咖啡 ☕️")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 20) {
                qrColumn(title: "微信支付", imageName: "donate_wechat", tint: .green)
                qrColumn(title: "支付宝", imageName: "donate_alipay", tint: .blue)
            }

            Link(destination: payPalURL) {
                Label("使用 PayPal 支持", systemImage: "link")
            }
            .font(.callout)

            Text("感谢你的支持！")
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
