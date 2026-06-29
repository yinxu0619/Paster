import AppKit
import SwiftData

/// 面板的视图模型，封装「粘贴 / 纯文本粘贴 / 重新复制 / 删除」等业务动作，
/// 连接监听器、粘贴服务与持久化上下文。
///
/// 列表数据本身由 SwiftUI 的 `@Query` 直接驱动；本视图模型负责需要协调多个服务的操作。
/// 第 2 轮在第 1 轮 `paste` 基础上「扩展」更多动作方法。
@MainActor
final class ClipboardViewModel: ObservableObject {
    private let monitor: ClipboardMonitor
    private let context: ModelContext
    private let pasteService = PasteService.shared

    init(monitor: ClipboardMonitor, context: ModelContext) {
        self.monitor = monitor
        self.context = context
    }

    /// 执行粘贴：按原始格式写回剪贴板，随后延迟模拟 ⌘V。
    ///
    /// 调用方（`AppDelegate`）需先隐藏面板并激活目标应用，再调用本方法，
    /// 以保证按键发送时焦点已回到目标应用（否则只会替换剪贴板而粘贴不进去）。
    func paste(_ item: ClipboardItem) {
        let changeCount = pasteService.copyToPasteboard(item)
        monitor.markSelfCopy(changeCount: changeCount)
        scheduleKeystroke()
    }

    /// 纯文本粘贴：剥离格式后写回剪贴板并粘贴。
    func pasteAsPlainText(_ item: ClipboardItem) {
        let changeCount = pasteService.copyAsPlainText(item)
        monitor.markSelfCopy(changeCount: changeCount)
        scheduleKeystroke()
    }

    /// 重新复制到系统剪贴板（不触发粘贴）。
    func copy(_ item: ClipboardItem) {
        let changeCount = pasteService.copyToPasteboard(item)
        monitor.markSelfCopy(changeCount: changeCount)
    }

    /// 删除单条记录。
    func delete(_ item: ClipboardItem) {
        context.delete(item)
        try? context.save()
    }

    /// 切换固定状态（Pin / Unpin）。
    func togglePin(_ item: ClipboardItem) {
        item.isPinned.toggle()
        item.pinnedAt = item.isPinned ? Date() : nil
        try? context.save()
    }

    /// 一键清空全部历史（第 4 轮新增）。
    func clearAll() {
        do {
            try context.delete(model: ClipboardItem.self)
            try context.save()
        } catch {
            NSLog("[Paster] 清空历史失败: \(error.localizedDescription)")
        }
    }

    /// 等待目标应用重新获得焦点后再发送 ⌘V。
    private func scheduleKeystroke() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [pasteService] in
            pasteService.simulatePasteKeystroke()
        }
    }
}
