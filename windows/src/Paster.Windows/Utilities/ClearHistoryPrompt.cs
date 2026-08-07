namespace Paster.Windows.Utilities;

/// <summary>
/// One source of truth for the clear-history confirmation. The panel, the settings window and the
/// tray menu each ask in their own way - a ContentDialog in two of them, a Win32 message box in
/// the tray - but they must all say the same thing, so the wording lives here rather than being
/// copied three times.
///
/// Each accessor takes the "is the UI in Chinese" flag the caller already computed, because the
/// three hosts derive it differently (MainWindow.IsChinese, SettingsWindow.T, App.Localize).
/// </summary>
public static class ClearHistoryPrompt
{
    public static string Title(bool chinese) =>
        chinese ? "确定清空剪贴板历史？" : "Clear clipboard history?";

    /// <summary>
    /// States the pinned-item exemption first: it is the part that changes what the user loses.
    /// </summary>
    public static string Body(bool chinese) =>
        chinese
            ? "置顶记录会保留，其余记录将被永久删除，且无法恢复。"
            : "Pinned items are kept. Everything else is permanently deleted and cannot be undone.";

    public static string Confirm(bool chinese) => chinese ? "清空" : "Clear";

    public static string Cancel(bool chinese) => chinese ? "取消" : "Cancel";

    /// <summary>Status line shown once the clear has run.</summary>
    public static string Done(bool chinese) =>
        chinese ? "已清空，置顶记录已保留。" : "History cleared. Pinned items kept.";
}
