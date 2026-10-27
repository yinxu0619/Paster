import AppKit
import SwiftUI

/// 横向条在屏幕上的位置与尺寸。面板呼出与设置页的高度预览共用这一份计算，两者始终一致。
enum BarGeometry {
    /// 停靠在可用区域内（不贴边）时，与 Dock / 菜单栏之间留出的间距。
    static let gap: CGFloat = 12

    /// 横向条停靠所依据的矩形区域：贴屏幕边缘时为整块屏幕，否则为去掉 Dock / 菜单栏后的可用区域。
    static func region(on screen: NSScreen?, attachToEdge: Bool) -> NSRect {
        (attachToEdge ? screen?.frame : screen?.visibleFrame) ?? .zero
    }

    /// 贴屏幕边缘时铺满整屏宽；停靠在可用区域内时两侧留出小边距。
    static func size(height: CGFloat, region: NSRect, attachToEdge: Bool) -> NSSize {
        NSSize(width: attachToEdge ? region.width : max(480, region.width - 24), height: height)
    }

    /// 底部贴边时紧贴屏幕最底沿，否则位于 Dock 之上并留出小间距；顶部均紧贴区域上沿。
    static func origin(size: NSSize, region: NSRect, atTop: Bool, attachToEdge: Bool) -> NSPoint {
        let y = atTop ? region.maxY - size.height : (attachToEdge ? region.minY : region.minY + gap)
        return NSPoint(x: region.midX - size.width / 2, y: y)
    }

    static func frame(height: CGFloat, on screen: NSScreen?, atTop: Bool, attachToEdge: Bool) -> NSRect {
        let region = region(on: screen, attachToEdge: attachToEdge)
        let size = size(height: height, region: region, attachToEdge: attachToEdge)
        return NSRect(origin: origin(size: size, region: region, atTop: atTop, attachToEdge: attachToEdge), size: size)
    }
}

/// 拖动设置里的「横向条高度」时，在屏幕上按真实位置与大小画出横向条将占的区域，松手后淡出。
/// 只是一块不接收鼠标、不抢焦点的半透明示意窗口，不会呼出真正的面板。
@MainActor
final class BarHeightPreview {
    static let shared = BarHeightPreview()

    private var window: NSPanel?
    private var hideWork: DispatchWorkItem?

    /// 显示或更新预览；拖动过程中每次高度变化都会调用。
    func show(height: Double) {
        let settings = AppSettings.shared
        hideWork?.cancel()
        hideWork = nil
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let frame = BarGeometry.frame(height: CGFloat(height), on: screen,
                                      atTop: settings.panelPosition == .top,
                                      attachToEdge: settings.barAttachToScreenEdge)
        let window = self.window ?? makeWindow()
        self.window = window
        (window.contentView as? NSHostingView<PreviewShape>)?.rootView = PreviewShape(height: Int(height))
        window.setFrame(frame, display: true)
        if !window.isVisible {
            window.alphaValue = 0
            window.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            window.animator().alphaValue = 1
        }
    }

    /// 松手后稍停片刻再淡出，让人看清最终高度。
    func hide(after delay: TimeInterval = 0.5) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let window = self?.window else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                window.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    if window.alphaValue == 0 { window.orderOut(nil) }
                }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    var isVisible: Bool { window?.isVisible == true }
    var frame: NSRect? { window?.frame }

    private func makeWindow() -> NSPanel {
        let window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.level = FloatingPanel.presentationLevel
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.animationBehavior = .none
        window.contentView = NSHostingView(rootView: PreviewShape(height: 0))
        return window
    }

    private struct PreviewShape: View {
        let height: Int

        var body: some View {
            ZStack {
                Rectangle().fill(Color.accentColor.opacity(0.18))
                Rectangle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                Text(L10n.tr("settings.barHeightUnit", height))
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.accentColor))
            }
        }
    }
}
