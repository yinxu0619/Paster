using Microsoft.UI.Xaml;
using Paster.Windows.Models;
using Paster.Windows.Services;
using Paster.Windows.Utilities;
using Paster.Windows.ViewModels;
using System;
using System.Globalization;

namespace Paster.Windows;

public partial class App : Application
{
    private MainWindow? _window;
    private ClipboardMonitor? _clipboardMonitor;
    private HotKeyService? _hotKeyService;
    private TrayIconService? _trayIconService;
    private bool _pendingRefresh;
    private bool _refreshRunning;

    public App()
    {
        AppLog.Info("App constructor entered.");
        InitializeComponent();
        UnhandledException += (_, e) =>
        {
            AppLog.Error("Unhandled WinUI exception.", e.Exception);
        };
        AppLog.Info("App initialized.");
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            AppLog.Info("Paster.Windows launching.");
            var database = new ClipboardDatabase();
            await database.InitializeAsync();
            AppLog.Info("Database initialized.");

            var settings = AppSettings.Load();
            AppLog.Info("Settings loaded.");
            StartupService.Reconcile(settings);
            AppLog.Info($"Launch at login reconciled. Enabled={settings.LaunchAtLogin}.");
            var pasteService = new PasteService(database);
            var viewModel = new ClipboardViewModel(database, settings, pasteService);
            await viewModel.RefreshAsync();
            AppLog.Info("Initial history loaded.");
            ImageStorageMigration.RunInBackground(database);

            _window = new MainWindow(viewModel, settings);
            _window.Closed += (_, _) =>
            {
                _trayIconService?.Dispose();
                _clipboardMonitor?.Dispose();
                _hotKeyService?.Dispose();
            };

            _clipboardMonitor = new ClipboardMonitor(database, settings);
            _clipboardMonitor.ItemRecorded += (_, _) =>
            {
                if (_window is null)
                {
                    return;
                }

                _window.DispatcherQueue.TryEnqueue(async () =>
                {
                    if (!_window.IsPanelVisible)
                    {
                        _pendingRefresh = true;
                        return;
                    }

                    await RefreshViewModelAsync(viewModel);
                });
            };
            _clipboardMonitor.Start();
            AppLog.Info("Clipboard monitor started.");

            _hotKeyService = new HotKeyService(settings);
            _hotKeyService.HotKeyPressed += (_, targetWindow) =>
            {
                pasteService.LastTargetWindow = targetWindow;
                _window.DispatcherQueue.TryEnqueue(() => _window.TogglePanel(targetWindow));
            };
            _hotKeyService.Start();
            AppLog.Info(_hotKeyService.IsRegistered
                ? "Global hotkey Alt+C registered."
                : $"Global hotkey registration failed. Win32 error {_hotKeyService.LastError}.");

            var status = _hotKeyService.IsRegistered
                ? Localize(settings, "Ready. Global hotkey Alt+C is registered.", "就绪。全局热键 Alt+C 已注册。")
                : Localize(settings, $"Ready, but Alt+C registration failed. Windows error: {_hotKeyService.LastError}. The shortcut may be used by another app.",
                    $"就绪，但 Alt+C 注册失败。Windows 错误：{_hotKeyService.LastError}。可能被其他应用占用。");
            _window.ShowStartup(status);
            _window.PanelVisibilityChanged += visible =>
            {
                if (visible && _pendingRefresh)
                {
                    _window.DispatcherQueue.TryEnqueue(async () => await RefreshViewModelAsync(viewModel));
                }
            };

            _trayIconService = new TrayIconService(
                _window.DispatcherQueue,
                (english, chinese) => Localize(settings, english, chinese),
                () => _window.ShowMainWindow(Localize(settings, "Paster is running from the system tray.", "Paster 正在系统托盘中运行。")),
                () => _ = viewModel.ClearAllAsync(),
                () => _window.ShowSettingsWindow(),
                Quit);
            AppLog.Info("Tray icon created.");
        }
        catch (Exception ex)
        {
            AppLog.Error("Fatal startup failure.", ex);
            throw;
        }
    }

    /// <summary>
    /// Tears down the tray icon, clipboard hook and hotkey before ending the process. Paster has
    /// no visible main window to close, so nothing else would release the message loop.
    /// </summary>
    private void Quit()
    {
        AppLog.Info("Shutting down Paster.");
        _trayIconService?.Dispose();
        _clipboardMonitor?.Dispose();
        _hotKeyService?.Dispose();
        _window?.Close();
        AppLog.Flush();
        Exit();
    }

    private async Task RefreshViewModelAsync(ClipboardViewModel viewModel)
    {
        if (_refreshRunning)
        {
            _pendingRefresh = true;
            return;
        }

        _refreshRunning = true;
        try
        {
            _pendingRefresh = false;
            await viewModel.RefreshAsync();
        }
        finally
        {
            _refreshRunning = false;
        }
    }

    private static string Localize(AppSettings settings, string english, string chinese)
    {
        var useChinese = settings.Language == AppLanguage.ChineseSimplified ||
                         (settings.Language == AppLanguage.System &&
                          CultureInfo.CurrentUICulture.TwoLetterISOLanguageName.Equals("zh", StringComparison.OrdinalIgnoreCase));
        return useChinese ? chinese : english;
    }
}
