using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.Diagnostics;
using System.Globalization;
using System.Numerics;
using Microsoft.UI;
using Microsoft.UI.Composition;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Hosting;
using Paster.Windows.Models;
using Paster.Windows.Native;
using Paster.Windows.Services;
using Paster.Windows.Utilities;
using Paster.Windows.ViewModels;
using Windows.Graphics;
using Windows.Storage.Streams;
using Windows.System;
using WinRT;
using WinRT.Interop;

namespace Paster.Windows;

public sealed partial class MainWindow : Window
{
    private const int PanelWidth = 680;
    private const int PanelHeight = 640;
    private const double CardSpacing = 10;

    /// <summary>
    /// The header is a label, not a banner: the panel is a transient overlay and every point
    /// spent on branding is a point taken from the history list.
    /// </summary>
    private const double HeaderTitleFontSize = 17;
    private const double HeaderIconSize = 20;
    private const double BarTitleFontSize = 15;
    private const double BarIconSize = 18;

    /// <summary>Pixels travelled per unit of MouseWheelDelta (one notch is 120 units).</summary>
    private const double BarWheelPixelsPerUnit = 1.6;
    private const double VerticalWheelPixelsPerUnit = 1.2;

    private readonly AppSettings _settings;
    private readonly IntPtr _hwnd;
    private readonly Grid _root;
    private readonly Grid _headerPanel;
    private readonly RowDefinition _headerRow;
    private readonly TextBox _searchBox;
    private readonly ScrollViewer _historyScroll;
    private readonly Grid _historySurface;
    private readonly ItemsRepeater _historyRepeater;
    private readonly StackLayout _historyLayout;
    private readonly TextBlock _emptyState;
    private readonly SmoothScroller _scroller;
    private readonly TextBlock _countText;
    private readonly TextBlock _statusText;
    private readonly TextBlock _helpText;
    private readonly TextBlock _titleText;
    private readonly Image _titleIcon;
    private readonly StackPanel _actionsPanel;
    private readonly StackPanel _footerPanel;
    private readonly Button _clearButton;
    private readonly Button _settingsButton;

    /// <summary>
    /// Headers and items in one flat list, because ItemsRepeater has no grouping. Reference
    /// identity is what the reconciler in <see cref="SyncEntries"/> diffs on, so the three section
    /// markers below are singletons rather than freshly built strings.
    /// </summary>
    private readonly ObservableCollection<object> _entries = [];
    private readonly SectionEntry _pinnedSection = new();
    private readonly SectionEntry _historySection = new();
    private readonly SectionEntry _recentSection = new();

    /// <summary>Cards currently realised by the repeater - a dozen or so, not the whole history.</summary>
    private readonly List<Border> _realizedCards = [];

    private const int PreviewCacheLimit = 40;
    private readonly Dictionary<Guid, BitmapImage> _previewCache = [];
    private readonly List<Guid> _previewOrder = [];
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _renderDebounceTimer;

    private readonly MenuFlyout _cardMenu = new();
    private readonly MenuFlyoutItem _menuPaste = new();
    private readonly MenuFlyoutItem _menuPastePlain = new();
    private readonly MenuFlyoutItem _menuCopy = new();
    private readonly MenuFlyoutItem _menuPin = new();
    private readonly MenuFlyoutItem _menuDelete = new();

    private DesktopAcrylicController? _acrylicController;
    private SystemBackdropConfiguration? _backdropConfiguration;

    private SettingsWindow? _settingsWindow;
    private bool _renderRequested;
    private bool _cardsDirty = true;
    private double _barCardWidth = 220;
    private double _barCardMinHeight = 100;
    private double _barCardMaxHeight = 140;
    private SizeInt32? _lastAppliedSize;
    private RectInt32? _lastAppliedRect;
    private bool _windowShownOnce;
    private bool _isVisible;
    private bool _hotkeyPanelSession;

    private bool IsBarLayout => _settings.PanelPosition is PanelPosition.Bottom or PanelPosition.Top;
    private bool IsChinese => _settings.Language == AppLanguage.ChineseSimplified ||
                              (_settings.Language == AppLanguage.System &&
                               CultureInfo.CurrentUICulture.TwoLetterISOLanguageName.Equals("zh", StringComparison.OrdinalIgnoreCase));

    public ClipboardViewModel ViewModel { get; }
    public bool IsPanelVisible => _isVisible;
    public event Action<bool>? PanelVisibilityChanged;

    public MainWindow(ClipboardViewModel viewModel, AppSettings settings)
    {
        ViewModel = viewModel;
        _settings = settings;
        _root = new Grid();
        _headerPanel = new Grid();
        _headerRow = new RowDefinition { Height = GridLength.Auto };
        _searchBox = new TextBox();
        _historyScroll = new ScrollViewer();
        _historySurface = new Grid();
        _historyRepeater = new ItemsRepeater();
        _historyLayout = new StackLayout { Spacing = CardSpacing };
        _emptyState = new TextBlock();
        _scroller = new SmoothScroller(_historyScroll);
        _countText = new TextBlock();
        _statusText = new TextBlock();
        _helpText = new TextBlock();
        _titleText = new TextBlock();
        _titleIcon = new Image();
        _actionsPanel = new StackPanel();
        _footerPanel = new StackPanel();
        _clearButton = new Button();
        _settingsButton = new Button();
        _renderDebounceTimer = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread().CreateTimer();
        _renderDebounceTimer.Interval = TimeSpan.FromMilliseconds(1);
        _renderDebounceTimer.IsRepeating = false;
        _renderDebounceTimer.Tick += (_, _) =>
        {
            if (_renderRequested)
            {
                _renderRequested = false;
                SyncEntries();
            }
        };

        ThemeBrushes.Apply(Application.Current.RequestedTheme == ApplicationTheme.Dark);
        Content = BuildContent();
        ThemeBrushes.Changed += OnThemeBrushesChanged;
        _root.ActualThemeChanged += (_, _) => ApplyTheme();

        ViewModel.Items.CollectionChanged += Items_CollectionChanged;
        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(ViewModel.ItemCountText))
            {
                _countText.Text = ViewModel.ItemCountText;
            }
            if (e.PropertyName == nameof(ViewModel.SelectedItem))
            {
                UpdateSelectedCardStyles();
                ScrollSelectedIntoView();
            }
        };

        _hwnd = WindowNative.GetWindowHandle(this);
        ConfigureWindow();
        ApplyTheme();
        Activated += MainWindow_Activated;
    }

    public void ShowStartup(string status)
    {
        EnsureNativeWindowVisible();
        ParkWindow();
        _statusText.Text = status;
    }

    public void ShowMainWindow(string status)
    {
        ShowMainWindowInternal(status, center: true);
    }

    public void ShowSettingsWindow()
    {
        if (_settingsWindow is null)
        {
            _settingsWindow = new SettingsWindow(_settings, ViewModel, () =>
            {
                _statusText.Text = T("Settings updated.", "设置已更新。");
                ApplyWindowSizeForCurrentPosition();
                ApplyLocalizedTexts();
                ApplyLayoutMode();
                ApplyBackdrop();
                _cardsDirty = true;
                RequestRender();
            });
            _settingsWindow.Closed += (_, _) => _settingsWindow = null;
        }

        _settingsWindow.Activate();
    }

    public void TogglePanel(IntPtr targetWindow)
    {
        AppLog.Trace($"TogglePanel invoked. IsVisible={_isVisible}.");
        if (_isVisible)
        {
            HidePanel();
        }
        else
        {
            ShowPanel(targetWindow);
        }
    }

    private void ShowPanel(IntPtr targetWindow)
    {
        _hotkeyPanelSession = true;
        ShowMainWindowInternal(T("Paster opened by Alt+C.", "已通过 Alt+C 打开 Paster。"), center: false);
    }

    private void ShowMainWindowInternal(string status, bool center)
    {
        var sw = Stopwatch.StartNew();
        _statusText.Text = status;
        EnsureNativeWindowVisible();
        AppLog.Trace($"ShowPanel checkpoint: ensure-visible {sw.ElapsedMilliseconds}ms");
        PositionForCurrentSetting(forceCenter: center);
        AppLog.Trace($"ShowPanel checkpoint: positioned {sw.ElapsedMilliseconds}ms");

        _root.Visibility = Visibility.Visible;
        PrepareEntranceState();
        AppLog.Trace($"ShowPanel checkpoint: prepared entrance {sw.ElapsedMilliseconds}ms");
        NativeMethods.SetForegroundWindow(_hwnd);
        Activate();
        AppLog.Trace($"ShowPanel checkpoint: activated {sw.ElapsedMilliseconds}ms");
        _isVisible = true;
        PanelVisibilityChanged?.Invoke(true);
        ApplyLayoutMode();
        AppLog.Trace($"ShowPanel checkpoint: layout {sw.ElapsedMilliseconds}ms");
        if (_cardsDirty)
        {
            RequestRender();
        }
        else
        {
            // Relative timestamps go stale while the panel is parked. Only realised cards need it.
            RefreshVisibleTimestamps();
        }
        AppLog.Trace($"ShowPanel checkpoint: render-request {sw.ElapsedMilliseconds}ms");
        RunEntranceAnimation();
        DispatcherQueue.TryEnqueue(() => _searchBox.Focus(FocusState.Programmatic));
        AppLog.Info($"ShowMainWindowInternal completed in {sw.ElapsedMilliseconds}ms. CardsDirty={_cardsDirty}.");
    }

    private UIElement BuildContent()
    {
        _root.Padding = new Thickness(14);
        _root.Background = ThemeBrushes.PanelBackground;
        _root.RowDefinitions.Add(_headerRow);
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        // The search box owns focus while the panel is open and marks caret keys as handled, so a
        // plain bubbling KeyDown handler never sees Left/Right/Up/Down. Listen to handled events
        // too and hand the caret keys back explicitly (see SearchBoxWantsKey).
        _root.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(Root_KeyDown), handledEventsToo: true);

        _headerPanel.ColumnSpacing = 12;
        _headerPanel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _headerPanel.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        var logo = AppIcons.TryLoadLogo(decodePixelWidth: 64);
        _titleIcon.Source = logo;
        _titleIcon.Visibility = logo is null ? Visibility.Collapsed : Visibility.Visible;
        _titleIcon.Stretch = Stretch.Uniform;
        _titleIcon.VerticalAlignment = VerticalAlignment.Center;
        _titleIcon.Width = HeaderIconSize;
        _titleIcon.Height = HeaderIconSize;
        title.Children.Add(_titleIcon);
        _titleText.Text = "Paster";
        _titleText.FontSize = HeaderTitleFontSize;
        _titleText.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        _titleText.Foreground = ThemeBrushes.PrimaryText;
        title.Children.Add(_titleText);
        _countText.Text = ViewModel.ItemCountText;
        _countText.VerticalAlignment = VerticalAlignment.Center;
        _countText.Foreground = ThemeBrushes.SecondaryText;
        title.Children.Add(_countText);
        _headerPanel.Children.Add(title);

        _clearButton.Click += Clear_Click;
        Grid.SetColumn(_clearButton, 1);
        _actionsPanel.Orientation = Orientation.Horizontal;
        _actionsPanel.Spacing = 8;
        _settingsButton.Click += (_, _) => ShowSettingsWindow();
        _actionsPanel.Children.Add(_settingsButton);
        _actionsPanel.Children.Add(_clearButton);
        Grid.SetColumn(_actionsPanel, 1);
        _headerPanel.Children.Add(_actionsPanel);
        _root.Children.Add(_headerPanel);

        _searchBox.Margin = new Thickness(0, 12, 0, 10);
        _searchBox.CornerRadius = new CornerRadius(8);
        _searchBox.Resources["TextControlBorderBrushFocused"] = ThemeBrushes.SearchFocusBorder;
        _searchBox.Resources["TextControlBorderThemeThicknessFocused"] = new Thickness(1);
        _searchBox.TextChanged += (_, _) => ViewModel.SearchText = _searchBox.Text;
        Grid.SetRow(_searchBox, 1);
        _root.Children.Add(_searchBox);

        BuildHistorySurface();
        BuildSharedContextMenu();

        _footerPanel.Spacing = 4;
        _footerPanel.Margin = new Thickness(0, 10, 0, 0);
        _statusText.Text = T("Starting...", "正在启动...");
        _statusText.TextWrapping = TextWrapping.Wrap;
        _statusText.Foreground = ThemeBrushes.SecondaryText;
        _footerPanel.Children.Add(_statusText);

        _helpText.TextWrapping = TextWrapping.Wrap;
        _helpText.Foreground = ThemeBrushes.TertiaryText;
        _footerPanel.Children.Add(_helpText);
        Grid.SetRow(_footerPanel, 3);
        _root.Children.Add(_footerPanel);

        ApplyLocalizedTexts();
        ApplyLayoutMode();
        SyncEntries();

        return _root;
    }

    /// <summary>
    /// The virtualised history list. Cards are produced by <see cref="CardElementFactory"/> and
    /// recycled by the repeater, so the number of live XAML objects tracks the viewport rather than
    /// the history length.
    /// </summary>
    private void BuildHistorySurface()
    {
        _historyRepeater.Layout = _historyLayout;
        _historyRepeater.ItemsSource = _entries;
        _historyRepeater.ItemTemplate = new CardElementFactory(CreateCardElement, CreateSectionHeaderElement);
        _historyRepeater.ElementPrepared += Repeater_ElementPrepared;
        _historyRepeater.ElementClearing += Repeater_ElementClearing;

        // A transparent surface under the repeater keeps the gaps between cards hit-testable, so a
        // wheel event in a gap still reaches the handler below instead of falling through to the
        // ScrollViewer.
        _historySurface.Background = new SolidColorBrush(Colors.Transparent);
        _historySurface.Children.Add(_historyRepeater);

        // Registered on the surface rather than on the ScrollViewer on purpose. The ScrollViewer
        // handles PointerWheelChanged itself and marks it handled, which is why the previous
        // `_historyScroll.PointerWheelChanged +=` handler never ran at all: a plain subscription is
        // skipped for already-handled events. Handling it one level lower, while it is still
        // unhandled, both runs reliably and stops the ScrollViewer from acting on it too.
        _historySurface.PointerWheelChanged += HistorySurface_PointerWheelChanged;

        _historyScroll.Content = _historySurface;
        _historyScroll.SizeChanged += HistoryScroll_SizeChanged;
        Grid.SetRow(_historyScroll, 2);
        _root.Children.Add(_historyScroll);

        _emptyState.HorizontalAlignment = HorizontalAlignment.Center;
        _emptyState.VerticalAlignment = VerticalAlignment.Center;
        _emptyState.Foreground = ThemeBrushes.TertiaryText;
        _emptyState.Visibility = Visibility.Collapsed;
        Grid.SetRow(_emptyState, 2);
        _root.Children.Add(_emptyState);
    }

    private void BuildSharedContextMenu()
    {
        // One flyout for the whole list instead of a six-item MenuFlyout per card. Every handler
        // acts on ViewModel.SelectedItem, which the right-tap handler sets from the card's
        // DataContext before showing the menu.
        _menuPaste.Click += async (_, _) => await PasteAndHideAsync(false);
        _menuPastePlain.Click += async (_, _) => await PasteAndHideAsync(true);
        _menuCopy.Click += async (_, _) => await ViewModel.CopySelectedAsync();
        _menuPin.Click += async (_, _) => await ViewModel.TogglePinSelectedAsync();
        _menuDelete.Click += async (_, _) => await ViewModel.DeleteSelectedAsync();

        _cardMenu.Items.Add(_menuPaste);
        _cardMenu.Items.Add(_menuPastePlain);
        _cardMenu.Items.Add(_menuCopy);
        _cardMenu.Items.Add(new MenuFlyoutSeparator());
        _cardMenu.Items.Add(_menuPin);
        _cardMenu.Items.Add(_menuDelete);
    }

    private void ApplyLayoutMode()
    {
        var bar = IsBarLayout;
        if (bar)
        {
            _headerPanel.Visibility = Visibility.Collapsed;
            _headerRow.Height = new GridLength(0);
            _root.Padding = new Thickness(10, 6, 10, 8);
            _actionsPanel.Visibility = Visibility.Collapsed;
            _footerPanel.Visibility = Visibility.Collapsed;
            _searchBox.Margin = new Thickness(0, 2, 0, 6);
            _titleText.FontSize = BarTitleFontSize;
            _titleIcon.Width = BarIconSize;
            _titleIcon.Height = BarIconSize;
            _countText.Text = ViewModel.ItemCountText;
        }
        else
        {
            _headerPanel.Visibility = Visibility.Visible;
            _headerRow.Height = GridLength.Auto;
            _root.Padding = new Thickness(14);
            _actionsPanel.Visibility = Visibility.Visible;
            _footerPanel.Visibility = Visibility.Visible;
            _searchBox.Margin = new Thickness(0, 12, 0, 10);
            _titleText.FontSize = HeaderTitleFontSize;
            _titleIcon.Width = HeaderIconSize;
            _titleIcon.Height = HeaderIconSize;
            _countText.Text = ViewModel.ItemCountText;
        }

        _historyLayout.Orientation = bar ? Orientation.Horizontal : Orientation.Vertical;
        _historyRepeater.HorizontalAlignment = bar ? HorizontalAlignment.Left : HorizontalAlignment.Stretch;
        _historySurface.HorizontalAlignment = bar ? HorizontalAlignment.Left : HorizontalAlignment.Stretch;
        _historyScroll.HorizontalScrollBarVisibility = bar ? ScrollBarVisibility.Auto : ScrollBarVisibility.Disabled;
        _historyScroll.VerticalScrollBarVisibility = bar ? ScrollBarVisibility.Disabled : ScrollBarVisibility.Auto;
        // ScrollMode.Disabled turns off the ScrollViewer's own input handling while leaving the
        // extent scrollable programmatically. It has to be off on the active axis: the built-in
        // DirectManipulation wheel handling claims the event before it can bubble to the surface
        // handler below, which is why nothing reached that handler in the vertical layouts.
        _historyScroll.HorizontalScrollMode = ScrollMode.Disabled;
        _historyScroll.VerticalScrollMode = ScrollMode.Disabled;
        _emptyState.Margin = bar ? new Thickness(40, 0, 0, 0) : new Thickness(0, 40, 0, 0);

        UpdateBarCardSizing();
        ApplyCardMetricsToRealized();
    }

    private void ApplyLocalizedTexts()
    {
        _clearButton.Content = T("Clear", "清空");
        _settingsButton.Content = T("Settings", "设置");
        _searchBox.PlaceholderText = T("Search text, URL, file path or source app", "搜索文本、链接、文件路径或来源应用");
        _helpText.Text = T(
            "Alt+C show/hide, Enter paste, Ctrl+Shift+Enter plain paste, Del delete, Ctrl+P pin, Esc hide.",
            "Alt+C 显示/隐藏，Enter 粘贴，Ctrl+Shift+Enter 纯文本粘贴，Del 删除，Ctrl+P 置顶，Esc 隐藏。");

        _menuPaste.Text = T("Paste", "粘贴");
        _menuPastePlain.Text = T("Paste as plain text", "粘贴为纯文本");
        _menuCopy.Text = T("Copy again", "再次复制");
        _menuPin.Text = T("Pin / Unpin", "置顶 / 取消置顶");
        _menuDelete.Text = T("Delete", "删除");

        _pinnedSection.Title = T("Pinboard", "置顶");
        _historySection.Title = T("History", "历史");
        _recentSection.Title = T("Recent", "最近");
        _emptyState.Text = string.IsNullOrWhiteSpace(ViewModel.SearchText)
            ? T("No clipboard history yet.", "还没有剪贴板历史。")
            : T("No matching items.", "没有匹配项。");
    }

    // MARK: - Theme and backdrop

    private void ApplyTheme()
    {
        ThemeBrushes.Apply(_root.ActualTheme == ElementTheme.Dark);
        if (_backdropConfiguration is not null)
        {
            _backdropConfiguration.Theme = ThemeBrushes.IsDark ? SystemBackdropTheme.Dark : SystemBackdropTheme.Light;
        }

        ApplyBackdrop();
    }

    private void OnThemeBrushesChanged()
    {
        // Card fills animate a private brush, so they cannot follow a shared brush retint.
        foreach (var card in _realizedCards)
        {
            if (card.Tag is CardParts parts)
            {
                ApplyCardState(parts, animate: false);
            }
        }
    }

    /// <summary>
    /// Acrylic rather than Mica: this is a transient overlay that appears over whatever the user is
    /// working in, which is exactly the surface type acrylic is specified for. Mica samples the
    /// desktop wallpaper for long-lived app windows and would ignore the content actually behind
    /// the panel.
    ///
    /// A <see cref="DesktopAcrylicController"/> is used instead of the simpler
    /// <c>DesktopAcrylicBackdrop</c> because only the controller exposes TintOpacity /
    /// LuminosityOpacity, which is what makes the user-facing slider mean anything.
    /// </summary>
    private void ApplyBackdrop()
    {
        var supported = DesktopAcrylicController.IsSupported();
        var wanted = _settings.PanelAcrylicEnabled && supported;
        if (!wanted)
        {
            TearDownBackdrop();
            ThemeBrushes.SetPanelOpacity(_settings.PanelOpacity, acrylicActive: false);
            AppLog.Info($"Backdrop off (enabled={_settings.PanelAcrylicEnabled} supported={supported}). " +
                        $"Panel painted solid {ThemeBrushes.AcrylicFallback}.");
            return;
        }

        if (_acrylicController is null)
        {
            try
            {
                _backdropConfiguration = new SystemBackdropConfiguration
                {
                    IsInputActive = true,
                    Theme = ThemeBrushes.IsDark ? SystemBackdropTheme.Dark : SystemBackdropTheme.Light
                };
                _acrylicController = new DesktopAcrylicController();
                _acrylicController.SetSystemBackdropConfiguration(_backdropConfiguration);
                _acrylicController.AddSystemBackdropTarget(this.As<ICompositionSupportsSystemBackdrop>());
            }
            catch (Exception ex)
            {
                // Missing GPU support or a locked-down composition stack: fall back to a solid panel
                // rather than leaving an unreadable half-rendered surface.
                AppLog.Error("Acrylic backdrop could not be created; using a solid panel instead.", ex);
                TearDownBackdrop();
                ThemeBrushes.SetPanelOpacity(_settings.PanelOpacity, acrylicActive: false);
                return;
            }
        }

        var opacity = Math.Clamp(_settings.PanelOpacity, AppSettings.MinPanelOpacity, AppSettings.MaxPanelOpacity);
        _acrylicController.TintColor = ThemeBrushes.AcrylicTint;
        // Honoured by the OS when the user turns transparency effects off, or when the compositor
        // cannot run the effect.
        _acrylicController.FallbackColor = ThemeBrushes.AcrylicFallback;
        _acrylicController.TintOpacity = (float)(0.10 + (0.75 * opacity));
        _acrylicController.LuminosityOpacity = (float)(0.30 + (0.70 * opacity));
        ThemeBrushes.SetPanelOpacity(opacity, acrylicActive: true);
        AppLog.Info($"Backdrop acrylic dark={ThemeBrushes.IsDark} opacity={opacity:F2} " +
                    $"tint={_acrylicController.TintColor} tintOpacity={_acrylicController.TintOpacity:F2} " +
                    $"luminosity={_acrylicController.LuminosityOpacity:F2} fallback={_acrylicController.FallbackColor} " +
                    $"rootFill={ThemeBrushes.PanelBackground.Color}");
    }

    private void TearDownBackdrop()
    {
        if (_acrylicController is null)
        {
            return;
        }

        _acrylicController.Dispose();
        _acrylicController = null;
        _backdropConfiguration = null;
    }

    // MARK: - Entrance animation

    private void RunEntranceAnimation()
    {
        var intensity = (float)Math.Clamp(_settings.AnimationBounciness, 0.6, 2.4);
        var position = _settings.PanelPosition;
        var fromX = position == PanelPosition.Left ? -24f * intensity : position == PanelPosition.Right ? 24f * intensity : 0f;
        var fromY = position == PanelPosition.Top ? -20f * intensity : position == PanelPosition.Bottom ? 20f * intensity : 8f * intensity;
        var bounceX = fromX == 0 ? 0f : -MathF.Sign(fromX) * (1.6f * intensity);
        var bounceY = fromY == 0 ? 0f : -MathF.Sign(fromY) * (1.6f * intensity);

        var visual = ElementCompositionPreview.GetElementVisual(_root);
        var compositor = visual.Compositor;
        var animation = compositor.CreateVector3KeyFrameAnimation();
        animation.InsertKeyFrame(0.0f, new Vector3(fromX, fromY, 0f));
        animation.InsertKeyFrame(0.82f, new Vector3(bounceX, bounceY, 0f));
        animation.InsertKeyFrame(1.0f, Vector3.Zero);
        animation.Duration = TimeSpan.FromMilliseconds(130 + (35 * intensity));

        visual.StartAnimation("Offset", animation);
        _root.Opacity = 1.0;
        AppLog.Trace("RunEntranceAnimation executed with lightweight composition.");
    }

    private void PrepareEntranceState()
    {
        var intensity = (float)Math.Clamp(_settings.AnimationBounciness, 0.6, 2.4);
        var position = _settings.PanelPosition;
        var fromX = position == PanelPosition.Left ? -24f * intensity : position == PanelPosition.Right ? 24f * intensity : 0f;
        var fromY = position == PanelPosition.Top ? -20f * intensity : position == PanelPosition.Bottom ? 20f * intensity : 8f * intensity;
        var visual = ElementCompositionPreview.GetElementVisual(_root);
        visual.Offset = new Vector3(fromX, fromY, 0f);
        _root.Opacity = 1.0;
    }

    // MARK: - Item source

    private void Items_CollectionChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        _cardsDirty = true;
        RequestRender();
    }

    private void RequestRender()
    {
        // A single Merge() in the view model raises many collection events; coalesce them so the
        // flat entry list is reconciled once.
        _renderRequested = true;
        _renderDebounceTimer.Stop();
        _renderDebounceTimer.Start();
    }

    /// <summary>
    /// Reconciles <see cref="_entries"/> in place against the view model. Only genuine
    /// inserts / removes / moves reach the repeater, so an unchanged card keeps its element and
    /// nothing is rebuilt.
    /// </summary>
    private void SyncEntries()
    {
        var sw = Stopwatch.StartNew();
        _cardsDirty = false;

        var desired = new List<object>(ViewModel.Items.Count + 2);
        var pinnedHeaderShown = false;
        var historyHeaderShown = false;
        foreach (var item in ViewModel.Items)
        {
            if (item.IsPinned && !pinnedHeaderShown)
            {
                desired.Add(_pinnedSection);
                pinnedHeaderShown = true;
            }
            if (!item.IsPinned && !historyHeaderShown)
            {
                desired.Add(pinnedHeaderShown ? _historySection : _recentSection);
                historyHeaderShown = true;
            }
            desired.Add(item);
        }

        var wanted = new HashSet<object>(desired, ReferenceEqualityComparer.Instance);
        for (var index = _entries.Count - 1; index >= 0; index--)
        {
            if (!wanted.Contains(_entries[index]))
            {
                _entries.RemoveAt(index);
            }
        }

        for (var target = 0; target < desired.Count; target++)
        {
            var entry = desired[target];
            var existing = IndexOfEntry(entry, target);
            if (existing < 0)
            {
                _entries.Insert(target, entry);
            }
            else if (existing != target)
            {
                _entries.Move(existing, target);
            }
        }

        _emptyState.Text = string.IsNullOrWhiteSpace(ViewModel.SearchText)
            ? T("No clipboard history yet.", "还没有剪贴板历史。")
            : T("No matching items.", "没有匹配项。");
        var empty = _entries.Count == 0;
        _emptyState.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        _historyScroll.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;

        UpdateSelectedCardStyles();
        ScrollSelectedIntoView();
        AppLog.Trace($"SyncEntries reconciled {ViewModel.Items.Count} items into {_entries.Count} rows in {sw.Elapsed.TotalMilliseconds:F1}ms");
    }

    private int IndexOfEntry(object entry, int startAt)
    {
        for (var index = startAt; index < _entries.Count; index++)
        {
            if (ReferenceEquals(_entries[index], entry))
            {
                return index;
            }
        }

        for (var index = 0; index < startAt && index < _entries.Count; index++)
        {
            if (ReferenceEquals(_entries[index], entry))
            {
                return index;
            }
        }

        return -1;
    }

    // MARK: - Element realisation

    private void Repeater_ElementPrepared(ItemsRepeater sender, ItemsRepeaterElementPreparedEventArgs args)
    {
        var data = args.Index >= 0 && args.Index < _entries.Count ? _entries[args.Index] : null;

        if (args.Element is TextBlock header && data is SectionEntry section)
        {
            header.Text = section.Title;
            ApplySectionHeaderMetrics(header);
            return;
        }

        if (args.Element is Border card && card.Tag is CardParts parts && data is ClipboardItem item)
        {
            BindCard(parts, item);
            _realizedCards.Add(card);
        }
    }

    private void Repeater_ElementClearing(ItemsRepeater sender, ItemsRepeaterElementClearingEventArgs args)
    {
        if (args.Element is not Border card || card.Tag is not CardParts parts)
        {
            return;
        }

        _realizedCards.Remove(card);
        parts.Item = null;
        parts.IsHovered = false;
        card.DataContext = null;
        // Let the LRU preview cache own the bitmap rather than the recycled element.
        parts.ImagePreview.Source = null;
        parts.AppIcon.Source = null;
    }

    private void BindCard(CardParts parts, ClipboardItem item)
    {
        parts.Item = item;
        parts.IsHovered = false;
        parts.Root.DataContext = item;

        ApplyCardMetrics(parts);

        parts.Source.Text = string.IsNullOrWhiteSpace(item.SourceAppName)
            ? T("Unknown source", "未知来源")
            : item.SourceAppName;
        parts.Pin.Visibility = item.IsPinned ? Visibility.Visible : Visibility.Collapsed;
        parts.BadgeText.Text = item.TypeLabel;
        parts.Time.Text = RelativeTime.Format(item.CreatedAt, IsChinese);

        ApplyAppIcon(parts, item);
        ApplyPreview(parts, item);
        ApplyCardState(parts, animate: false);
    }

    private void ApplyAppIcon(CardParts parts, ClipboardItem item)
    {
        if (AppIconProvider.TryGetCached(item.SourceProcessPath, out var cached))
        {
            parts.AppIcon.Source = cached;
            parts.AppIcon.Visibility = cached is null ? Visibility.Collapsed : Visibility.Visible;
            parts.AppIconFallback.Visibility = cached is null ? Visibility.Visible : Visibility.Collapsed;
            return;
        }

        parts.AppIcon.Source = null;
        parts.AppIcon.Visibility = Visibility.Collapsed;
        parts.AppIconFallback.Visibility = Visibility.Visible;
        _ = LoadAppIconAsync(parts, item);
    }

    private async Task LoadAppIconAsync(CardParts parts, ClipboardItem item)
    {
        var icon = await AppIconProvider.GetAsync(item.SourceProcessPath);
        // The element may have been recycled onto a different row while the shell lookup ran.
        if (icon is null || !ReferenceEquals(parts.Item, item))
        {
            return;
        }

        parts.AppIcon.Source = icon;
        parts.AppIcon.Visibility = Visibility.Visible;
        parts.AppIconFallback.Visibility = Visibility.Collapsed;
    }

    private void ApplyPreview(CardParts parts, ClipboardItem item)
    {
        var bar = IsBarLayout;
        var hasImage = item.Type == ClipboardItemType.Image &&
                       (item.ThumbnailData is { Length: > 0 } || item.ImageData is { Length: > 0 });

        parts.ImageHost.Visibility = hasImage ? Visibility.Visible : Visibility.Collapsed;
        parts.TextPreview.Visibility = hasImage ? Visibility.Collapsed : Visibility.Visible;

        if (!hasImage)
        {
            parts.ImagePreview.Source = null;
            parts.TextPreview.Text = item.PreviewText;
            return;
        }

        if (TryGetPreview(item.Id, out var cached))
        {
            parts.ImagePreview.Source = cached;
            return;
        }

        parts.ImagePreview.Source = null;
        var decodeWidth = (int)Math.Round(Math.Clamp(bar ? _barCardWidth : 320, 120, 360));
        _ = LoadImageAsync(parts, item, item.ThumbnailData ?? item.ImageData!, decodeWidth);
    }

    private async Task LoadImageAsync(CardParts parts, ClipboardItem item, byte[] bytes, int decodeWidth)
    {
        try
        {
            var bitmap = new BitmapImage();
            // Decode straight to card size; otherwise a 4K capture is rasterised in full to fill
            // a ~200px preview. Both must be set before SetSourceAsync to take effect.
            bitmap.DecodePixelType = DecodePixelType.Logical;
            bitmap.DecodePixelWidth = decodeWidth;

            using var stream = new InMemoryRandomAccessStream();
            using (var writer = new DataWriter(stream))
            {
                writer.WriteBytes(bytes);
                await writer.StoreAsync();
                await writer.FlushAsync();
                writer.DetachStream();
            }
            stream.Seek(0);
            await bitmap.SetSourceAsync(stream);
            StorePreview(item.Id, bitmap);

            if (ReferenceEquals(parts.Item, item))
            {
                parts.ImagePreview.Source = bitmap;
            }
        }
        catch (Exception ex)
        {
            AppLog.Error("Failed to render image preview.", ex);
        }
    }

    private void RefreshVisibleTimestamps()
    {
        foreach (var card in _realizedCards)
        {
            if (card.Tag is CardParts { Item: { } item } parts)
            {
                parts.Time.Text = RelativeTime.Format(item.CreatedAt, IsChinese);
            }
        }
    }

    // MARK: - Card construction

    private UIElement CreateSectionHeaderElement()
    {
        var header = new TextBlock
        {
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = ThemeBrushes.SectionHeaderText
        };
        ApplySectionHeaderMetrics(header);
        return header;
    }

    private void ApplySectionHeaderMetrics(TextBlock header)
    {
        var bar = IsBarLayout;
        header.Width = bar ? 74 : double.NaN;
        header.VerticalAlignment = bar ? VerticalAlignment.Center : VerticalAlignment.Top;
        header.TextAlignment = bar ? TextAlignment.Center : TextAlignment.Left;
        header.Margin = bar ? new Thickness(0, 0, 2, 0) : new Thickness(4, 6, 0, 0);
    }

    private UIElement CreateCardElement()
    {
        var fill = new SolidColorBrush(ThemeBrushes.CardBackgroundColor);
        var card = new Border
        {
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(10),
            Background = fill,
            BorderBrush = ThemeBrushes.CardBorder,
            // Constant thickness: growing the border on selection would relayout the card contents.
            BorderThickness = new Thickness(1.5)
        };

        var layout = new Grid { RowSpacing = 8 };
        var topRow = new RowDefinition { Height = GridLength.Auto };
        var bodyRow = new RowDefinition { Height = GridLength.Auto };
        var timeRow = new RowDefinition { Height = GridLength.Auto };
        layout.RowDefinitions.Add(topRow);
        layout.RowDefinitions.Add(bodyRow);
        layout.RowDefinitions.Add(timeRow);

        var top = new Grid { ColumnSpacing = 6 };
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var appIcon = new Image
        {
            Width = 16,
            Height = 16,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed
        };
        top.Children.Add(appIcon);

        var appIconFallback = new FontIcon
        {
            Glyph = "\uECAA",
            FontSize = 14,
            Foreground = ThemeBrushes.TertiaryText,
            VerticalAlignment = VerticalAlignment.Center
        };
        top.Children.Add(appIconFallback);

        var source = new TextBlock
        {
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = ThemeBrushes.SourceText,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center
        };
        Grid.SetColumn(source, 1);
        top.Children.Add(source);

        var pin = new FontIcon
        {
            Glyph = "\uE840",
            FontSize = 12,
            Foreground = ThemeBrushes.PinAccent,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed
        };
        Grid.SetColumn(pin, 2);
        top.Children.Add(pin);

        var badgeText = new TextBlock { FontSize = 11, Foreground = ThemeBrushes.BadgeText };
        var badge = new Border
        {
            CornerRadius = new CornerRadius(9),
            Padding = new Thickness(7, 1, 7, 2),
            Background = ThemeBrushes.BadgeBackground,
            VerticalAlignment = VerticalAlignment.Center,
            Child = badgeText
        };
        Grid.SetColumn(badge, 3);
        top.Children.Add(badge);
        layout.Children.Add(top);

        var textPreview = new TextBlock
        {
            FontSize = 14,
            TextWrapping = TextWrapping.Wrap,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Foreground = ThemeBrushes.PrimaryText
        };
        Grid.SetRow(textPreview, 1);
        layout.Children.Add(textPreview);

        var imagePreview = new Image
        {
            Stretch = Stretch.Uniform,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch
        };
        var imageHost = new Border
        {
            CornerRadius = new CornerRadius(8),
            Background = ThemeBrushes.ImagePlaceholder,
            Padding = new Thickness(3),
            Visibility = Visibility.Collapsed,
            Child = imagePreview
        };
        Grid.SetRow(imageHost, 1);
        layout.Children.Add(imageHost);

        var time = new TextBlock { FontSize = 11, Foreground = ThemeBrushes.TertiaryText };
        Grid.SetRow(time, 2);
        layout.Children.Add(time);

        card.Child = layout;

        // ~0.15s ease between the three background states, matching ClipboardCardView on macOS.
        var fillKeyFrame = new ColorAnimation
        {
            Duration = new Duration(TimeSpan.FromMilliseconds(150)),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
        };
        Storyboard.SetTarget(fillKeyFrame, fill);
        Storyboard.SetTargetProperty(fillKeyFrame, "Color");
        var fillAnimation = new Storyboard();
        fillAnimation.Children.Add(fillKeyFrame);

        card.Tag = new CardParts
        {
            Root = card,
            BodyRow = bodyRow,
            AppIcon = appIcon,
            AppIconFallback = appIconFallback,
            Source = source,
            Pin = pin,
            BadgeText = badgeText,
            TextPreview = textPreview,
            ImageHost = imageHost,
            ImagePreview = imagePreview,
            Time = time,
            Fill = fill,
            FillAnimation = fillAnimation,
            FillKeyFrame = fillKeyFrame
        };

        // Attached once per pooled element, not once per item.
        card.Tapped += Card_Tapped;
        card.DoubleTapped += Card_DoubleTapped;
        card.RightTapped += Card_RightTapped;
        card.PointerEntered += Card_PointerEntered;
        card.PointerExited += Card_PointerExited;
        card.PointerCanceled += Card_PointerExited;
        card.PointerCaptureLost += Card_PointerExited;

        ApplyCardMetrics((CardParts)card.Tag);
        return card;
    }

    private void ApplyCardMetrics(CardParts parts)
    {
        var bar = IsBarLayout;
        parts.Root.Width = bar ? _barCardWidth : double.NaN;
        parts.Root.MinHeight = bar ? _barCardMinHeight : 0;
        parts.Root.MaxHeight = bar ? _barCardMaxHeight : double.PositiveInfinity;
        parts.Root.HorizontalAlignment = bar ? HorizontalAlignment.Left : HorizontalAlignment.Stretch;
        parts.BodyRow.Height = bar ? new GridLength(1, GridUnitType.Star) : GridLength.Auto;
        parts.TextPreview.MaxLines = bar ? BarPreviewLineCount() : 4;
        parts.ImagePreview.MaxHeight = bar ? double.PositiveInfinity : 180;
        parts.ImagePreview.MinHeight = bar ? 60 : 120;
    }

    /// <summary>
    /// How many preview lines fit once the header row, the timestamp row, the two row gaps and the
    /// card padding have taken their share. A fixed line count pushed the timestamp past the card's
    /// MaxHeight on short bars, where the rounded Border simply clipped it away.
    /// </summary>
    private int BarPreviewLineCount()
    {
        const double chrome = 71;
        const double lineHeight = 19;
        return (int)Math.Clamp(Math.Floor((_barCardMaxHeight - chrome) / lineHeight), 2, 8);
    }

    private void ApplyCardMetricsToRealized()
    {
        foreach (var card in _realizedCards)
        {
            if (card.Tag is CardParts parts)
            {
                ApplyCardMetrics(parts);
            }
        }

        for (var index = 0; index < _entries.Count; index++)
        {
            if (_entries[index] is SectionEntry && _historyRepeater.TryGetElement(index) is TextBlock header)
            {
                ApplySectionHeaderMetrics(header);
            }
        }
    }

    private void ApplyCardState(CardParts parts, bool animate)
    {
        var selected = parts.Item is not null && ReferenceEquals(ViewModel.SelectedItem, parts.Item);
        var target = selected
            ? ThemeBrushes.CardSelectedColor
            : parts.IsHovered
                ? ThemeBrushes.CardHoverColor
                : ThemeBrushes.CardBackgroundColor;

        parts.Root.BorderBrush = selected ? ThemeBrushes.CardBorderSelected : ThemeBrushes.CardBorder;

        if (!animate)
        {
            // A running Storyboard holds the brush colour, so it has to be stopped before the
            // value can be assigned directly.
            parts.FillAnimation.Stop();
            parts.Fill.Color = target;
            return;
        }

        parts.FillKeyFrame.To = target;
        parts.FillAnimation.Begin();
    }

    private void UpdateSelectedCardStyles()
    {
        foreach (var card in _realizedCards)
        {
            if (card.Tag is CardParts parts)
            {
                ApplyCardState(parts, animate: true);
            }
        }
    }

    // MARK: - Card input

    private static ClipboardItem? ItemFor(object sender) =>
        sender is FrameworkElement element ? element.DataContext as ClipboardItem : null;

    private void Card_Tapped(object sender, TappedRoutedEventArgs e)
    {
        if (ItemFor(sender) is { } item)
        {
            ViewModel.SelectedItem = item;
        }
    }

    private async void Card_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (ItemFor(sender) is { } item)
        {
            ViewModel.SelectedItem = item;
            await PasteAndHideAsync(false);
        }
    }

    private void Card_RightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if (sender is not FrameworkElement element || ItemFor(sender) is not { } item)
        {
            return;
        }

        ViewModel.SelectedItem = item;
        _cardMenu.ShowAt(element, new FlyoutShowOptions { Position = e.GetPosition(element) });
        e.Handled = true;
    }

    private void Card_PointerEntered(object sender, PointerRoutedEventArgs e)
    {
        if (sender is Border { Tag: CardParts parts })
        {
            parts.IsHovered = true;
            ApplyCardState(parts, animate: true);
        }
    }

    private void Card_PointerExited(object sender, PointerRoutedEventArgs e)
    {
        if (sender is Border { Tag: CardParts parts })
        {
            parts.IsHovered = false;
            ApplyCardState(parts, animate: true);
        }
    }

    // MARK: - Scrolling

    private void HistorySurface_PointerWheelChanged(object sender, PointerRoutedEventArgs e)
    {
        var delta = e.GetCurrentPoint(_historyScroll).Properties.MouseWheelDelta;
        if (delta == 0)
        {
            return;
        }

        var horizontal = IsBarLayout;
        AppLog.Trace($"Wheel delta={delta} horizontal={horizontal} " +
                     $"offset={(horizontal ? _historyScroll.HorizontalOffset : _historyScroll.VerticalOffset):F1} " +
                     $"scrollable={(horizontal ? _historyScroll.ScrollableWidth : _historyScroll.ScrollableHeight):F1}");

        if (!_scroller.CanScroll(horizontal))
        {
            return;
        }

        // Precision touchpads send many small deltas instead of 120-unit notches; scaling them the
        // same way turns them into correspondingly small target moves, which the easing absorbs
        // without visible stepping.
        _scroller.Nudge(-delta * (horizontal ? BarWheelPixelsPerUnit : VerticalWheelPixelsPerUnit), horizontal);
        e.Handled = true;
    }

    private void HistoryScroll_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (!IsBarLayout)
        {
            return;
        }

        // Only a genuine change in the computed sizes is worth touching elements for. Previously
        // this rebuilt every card on every resize and DPI change.
        if (UpdateBarCardSizing())
        {
            ApplyCardMetricsToRealized();
        }
    }

    /// <summary>
    /// Centres the selected card, mirroring the ScrollViewReader / scrollTo(id, anchor: .center)
    /// behaviour of PanelRootView on macOS. Routed through the same scroller as the wheel so a
    /// keyboard jump and an in-flight wheel glide share one target instead of fighting.
    /// </summary>
    private void ScrollSelectedIntoView()
    {
        if (ViewModel.SelectedItem is not { } selected)
        {
            return;
        }

        var index = IndexOfEntry(selected, 0);
        if (index < 0)
        {
            return;
        }

        // Layout may not have run yet for an element realised in this same pass.
        DispatcherQueue.TryEnqueue(() =>
        {
            try
            {
                if (_historyRepeater.TryGetElement(index) is not FrameworkElement element)
                {
                    // Off-screen under virtualisation: realise just this one element to measure it.
                    element = _historyRepeater.GetOrCreateElement(index) as FrameworkElement
                              ?? throw new InvalidOperationException("Repeater returned no element.");
                    _historyRepeater.UpdateLayout();
                }

                if (element.ActualWidth <= 0 && element.ActualHeight <= 0)
                {
                    return;
                }

                var origin = element
                    .TransformToVisual(_historySurface)
                    .TransformPoint(new global::Windows.Foundation.Point(0, 0));

                if (IsBarLayout)
                {
                    var offset = origin.X + (element.ActualWidth / 2) - (_historyScroll.ViewportWidth / 2);
                    _scroller.GlideTo(Math.Max(0, offset), horizontal: true);
                }
                else
                {
                    var offset = origin.Y + (element.ActualHeight / 2) - (_historyScroll.ViewportHeight / 2);
                    _scroller.GlideTo(Math.Max(0, offset), horizontal: false);
                }
            }
            catch (Exception ex)
            {
                AppLog.Error("Failed to scroll the selected card into view.", ex);
            }
        });
    }

    // MARK: - Preview cache

    private bool TryGetPreview(Guid id, out BitmapImage bitmap)
    {
        if (!_previewCache.TryGetValue(id, out bitmap!))
        {
            return false;
        }

        TouchPreview(id);
        return true;
    }

    private void StorePreview(Guid id, BitmapImage bitmap)
    {
        _previewCache[id] = bitmap;
        TouchPreview(id);

        while (_previewOrder.Count > PreviewCacheLimit)
        {
            _previewCache.Remove(_previewOrder[0]);
            _previewOrder.RemoveAt(0);
        }
    }

    private void TouchPreview(Guid id)
    {
        _previewOrder.Remove(id);
        _previewOrder.Add(id);
    }

    /// <summary>
    /// Recomputes bar card geometry. Returns false when nothing moved, so callers can skip the
    /// element pass entirely.
    /// </summary>
    private bool UpdateBarCardSizing()
    {
        if (!IsBarLayout)
        {
            return false;
        }

        var viewportWidth = _historyScroll.ActualWidth;
        var viewportHeight = _historyScroll.ActualHeight;
        if (viewportWidth <= 1)
        {
            viewportWidth = SizeForCurrentPosition().Width - _root.Padding.Left - _root.Padding.Right;
        }
        if (viewportHeight <= 1)
        {
            viewportHeight = Math.Clamp(_settings.BarHeight - 88, 92, 540);
        }

        var targetVisibleCards = viewportWidth switch
        {
            >= 2400 => 10,
            >= 2000 => 8,
            >= 1600 => 6,
            >= 1200 => 5,
            _ => 4
        };
        var spacing = Math.Max(CardSpacing, _historyLayout.Spacing);
        var reserved = 92d;
        var rawWidth = (viewportWidth - reserved - (targetVisibleCards - 1) * spacing) / targetVisibleCards;
        var width = Math.Clamp(rawWidth, 180, 360);

        var rawHeight = viewportHeight - 12;
        var minHeight = Math.Clamp(rawHeight - 10, 90, 520);
        var maxHeight = Math.Clamp(rawHeight + 20, 120, 560);

        if (Math.Abs(width - _barCardWidth) < 0.5 &&
            Math.Abs(minHeight - _barCardMinHeight) < 0.5 &&
            Math.Abs(maxHeight - _barCardMaxHeight) < 0.5)
        {
            return false;
        }

        _barCardWidth = width;
        _barCardMinHeight = minHeight;
        _barCardMaxHeight = maxHeight;
        return true;
    }

    // MARK: - Window plumbing

    private void HidePanel()
    {
        _scroller.Stop();
        ParkWindow();
        _isVisible = false;
        PanelVisibilityChanged?.Invoke(false);
        _hotkeyPanelSession = false;
        AppLog.Trace("Panel hidden (parked off-screen).");
    }

    private void MainWindow_Activated(object sender, WindowActivatedEventArgs args)
    {
        if (_backdropConfiguration is not null)
        {
            _backdropConfiguration.IsInputActive = args.WindowActivationState != WindowActivationState.Deactivated;
        }

        if (_hotkeyPanelSession && args.WindowActivationState == WindowActivationState.Deactivated)
        {
            HidePanel();
        }
    }

    private void ConfigureWindow()
    {
        ExtendsContentIntoTitleBar = false;
        SetTitleBar(null);
        var exStyle = NativeMethods.GetWindowLong(_hwnd, NativeMethods.GwlExStyle);
        exStyle |= NativeMethods.WsExToolWindow;
        exStyle &= ~NativeMethods.WsExAppWindow;
        NativeMethods.SetWindowLong(_hwnd, NativeMethods.GwlExStyle, exStyle);
        NativeMethods.SetWindowPos(_hwnd, IntPtr.Zero, 0, 0, 0, 0,
            NativeMethods.SwpNoMove | NativeMethods.SwpNoSize | NativeMethods.SwpFrameChanged);
        var windowId = Win32Interop.GetWindowIdFromWindow(_hwnd);
        var appWindow = AppWindow.GetFromWindowId(windowId);
        appWindow.Title = "Paster";
        if (AppIcons.WindowIconPath is { } iconPath)
        {
            appWindow.SetIcon(iconPath);
        }

        appWindow.Resize(SizeForCurrentPosition());
        if (AppWindowTitleBar.IsCustomizationSupported())
        {
            appWindow.TitleBar.ExtendsContentIntoTitleBar = true;
            appWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Collapsed;
            appWindow.TitleBar.ButtonBackgroundColor = Colors.Transparent;
            appWindow.TitleBar.ButtonInactiveBackgroundColor = Colors.Transparent;
            appWindow.TitleBar.ButtonHoverBackgroundColor = Colors.Transparent;
            appWindow.TitleBar.ButtonPressedBackgroundColor = Colors.Transparent;
        }

        if (appWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.SetBorderAndTitleBar(false, false);
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
        }
    }

    private void EnsureNativeWindowVisible()
    {
        if (_windowShownOnce)
        {
            return;
        }

        NativeMethods.ShowWindow(_hwnd, NativeMethods.SwShow);
        _windowShownOnce = true;
    }

    private void ParkWindow()
    {
        _root.Visibility = Visibility.Collapsed;
        var screenWidth = NativeMethods.GetSystemMetrics(0);
        var screenHeight = NativeMethods.GetSystemMetrics(1);
        var appWindow = AppWindow.GetFromWindowId(Win32Interop.GetWindowIdFromWindow(_hwnd));
        var size = appWindow.Size;
        ApplyWindowRect(new RectInt32(screenWidth + 120, screenHeight + 120, size.Width, size.Height));
    }

    private void ApplyWindowSizeForCurrentPosition()
    {
        var size = SizeForCurrentPosition();
        if (_lastAppliedSize is SizeInt32 applied &&
            applied.Width == size.Width &&
            applied.Height == size.Height)
        {
            return;
        }

        AppWindow.GetFromWindowId(Win32Interop.GetWindowIdFromWindow(_hwnd)).Resize(size);
        _lastAppliedSize = size;
    }

    private SizeInt32 SizeForCurrentPosition()
    {
        var screenWidth = NativeMethods.GetSystemMetrics(0);
        var screenHeight = NativeMethods.GetSystemMetrics(1);
        return _settings.PanelPosition switch
        {
            PanelPosition.Bottom or PanelPosition.Top => new SizeInt32(screenWidth, Math.Clamp((int)_settings.BarHeight, 160, 600)),
            PanelPosition.Left or PanelPosition.Right => new SizeInt32(420, screenHeight),
            _ => new SizeInt32(PanelWidth, PanelHeight)
        };
    }

    private void PositionForCurrentSetting(bool forceCenter = false)
    {
        ApplyWindowSizeForCurrentPosition();
        if (forceCenter || _settings.PanelPosition == PanelPosition.Center)
        {
            PositionCenter();
            return;
        }

        if (_settings.PanelPosition != PanelPosition.Cursor)
        {
            PositionDocked();
            return;
        }

        NativeMethods.GetCursorPos(out var cursor);
        var screenWidth = NativeMethods.GetSystemMetrics(0);
        var screenHeight = NativeMethods.GetSystemMetrics(1);
        var size = SizeForCurrentPosition();
        var x = Math.Clamp(cursor.X, 12, Math.Max(12, screenWidth - size.Width - 12));
        var y = Math.Clamp(cursor.Y, 12, Math.Max(12, screenHeight - size.Height - 12));
        ApplyWindowRect(new RectInt32(x, y, size.Width, size.Height));
    }

    private void PositionCenter()
    {
        var screenWidth = NativeMethods.GetSystemMetrics(0);
        var screenHeight = NativeMethods.GetSystemMetrics(1);
        var size = SizeForCurrentPosition();
        var x = Math.Max(12, (screenWidth - size.Width) / 2);
        var y = Math.Max(12, (screenHeight - size.Height) / 2);
        ApplyWindowRect(new RectInt32(x, y, size.Width, size.Height));
    }

    private void PositionDocked()
    {
        var screenWidth = NativeMethods.GetSystemMetrics(0);
        var screenHeight = NativeMethods.GetSystemMetrics(1);
        var size = SizeForCurrentPosition();
        var (x, y) = _settings.PanelPosition switch
        {
            PanelPosition.Top => (0, 0),
            PanelPosition.Bottom => (0, Math.Max(0, screenHeight - size.Height)),
            PanelPosition.Left => (0, 0),
            PanelPosition.Right => (Math.Max(0, screenWidth - size.Width), 0),
            _ => (Math.Max(12, (screenWidth - size.Width) / 2), Math.Max(12, (screenHeight - size.Height) / 2))
        };
        ApplyWindowRect(new RectInt32(x, y, size.Width, size.Height));
    }

    private void ApplyWindowRect(RectInt32 rect)
    {
        if (_lastAppliedRect is RectInt32 applied &&
            applied.X == rect.X &&
            applied.Y == rect.Y &&
            applied.Width == rect.Width &&
            applied.Height == rect.Height)
        {
            return;
        }

        AppWindow.GetFromWindowId(Win32Interop.GetWindowIdFromWindow(_hwnd)).MoveAndResize(rect);
        _lastAppliedRect = rect;
    }

    private async void Clear_Click(object sender, RoutedEventArgs e) => await ViewModel.ClearAllAsync();

    private async void Root_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        var ctrl = IsKeyDown(VirtualKey.Control);
        var shift = IsKeyDown(VirtualKey.Shift);
        AppLog.Trace($"Root_KeyDown key={e.Key} alreadyHandled={e.Handled} searchLength={_searchBox.Text?.Length ?? 0}");

        switch (e.Key)
        {
            case VirtualKey.Escape:
                HidePanel();
                e.Handled = true;
                break;
            case VirtualKey.Left when IsBarLayout:
                if (SearchBoxWantsKey(e.Key)) { break; }
                ViewModel.MoveSelection(-1);
                e.Handled = true;
                break;
            case VirtualKey.Right when IsBarLayout:
                if (SearchBoxWantsKey(e.Key)) { break; }
                ViewModel.MoveSelection(1);
                e.Handled = true;
                break;
            case VirtualKey.Up:
                if (IsBarLayout) { e.Handled = true; break; }
                ViewModel.MoveSelection(-1);
                e.Handled = true;
                break;
            case VirtualKey.Down:
                if (IsBarLayout) { e.Handled = true; break; }
                ViewModel.MoveSelection(1);
                e.Handled = true;
                break;
            case VirtualKey.Home:
                if (SearchBoxWantsKey(e.Key)) { break; }
                ViewModel.SelectFirst();
                e.Handled = true;
                break;
            case VirtualKey.End:
                if (SearchBoxWantsKey(e.Key)) { break; }
                ViewModel.SelectLast();
                e.Handled = true;
                break;
            // The routed event has finished bubbling by the time an await resumes, so Handled
            // must be set before yielding rather than after.
            case VirtualKey.Enter when ctrl && shift:
                e.Handled = true;
                await PasteAndHideAsync(true);
                break;
            case VirtualKey.Enter:
                e.Handled = true;
                await PasteAndHideAsync(false);
                break;
            case VirtualKey.Delete or VirtualKey.Back:
                // With text in the box these edit the query instead, as advertised in Settings.
                if (!string.IsNullOrEmpty(_searchBox.Text) || ViewModel.SelectedItem is null) { break; }
                e.Handled = true;
                await ViewModel.DeleteSelectedAsync();
                break;
            case VirtualKey.P when ctrl:
                e.Handled = true;
                await ViewModel.TogglePinSelectedAsync();
                break;
        }
    }

    /// <summary>
    /// True when the search box still has somewhere for the caret to go, in which case the key
    /// belongs to text editing rather than to list navigation.
    /// </summary>
    private bool SearchBoxWantsKey(VirtualKey key)
    {
        if (_searchBox.FocusState == FocusState.Unfocused)
        {
            return false;
        }

        var length = _searchBox.Text?.Length ?? 0;
        if (length == 0)
        {
            return false;
        }

        var caret = _searchBox.SelectionStart;
        var selecting = _searchBox.SelectionLength > 0;
        return key switch
        {
            VirtualKey.Left or VirtualKey.Home => selecting || caret > 0,
            VirtualKey.Right or VirtualKey.End => selecting || caret < length,
            _ => false
        };
    }

    private async Task PasteAndHideAsync(bool plainText)
    {
        HidePanel();
        await ViewModel.PasteSelectedAsync(plainText);
    }

    private static bool IsKeyDown(VirtualKey key)
    {
        return (NativeMethods.GetAsyncKeyState((int)key) & unchecked((short)0x8000)) != 0;
    }

    private string T(string english, string chinese) => IsChinese ? chinese : english;

    /// <summary>Marker row in the flat item source; one instance per section.</summary>
    private sealed class SectionEntry
    {
        public string Title { get; set; } = string.Empty;
    }

    /// <summary>Every mutable part of a card element, so binding never walks the visual tree.</summary>
    private sealed class CardParts
    {
        public required Border Root { get; init; }
        public required RowDefinition BodyRow { get; init; }
        public required Image AppIcon { get; init; }
        public required FontIcon AppIconFallback { get; init; }
        public required TextBlock Source { get; init; }
        public required FontIcon Pin { get; init; }
        public required TextBlock BadgeText { get; init; }
        public required TextBlock TextPreview { get; init; }
        public required Border ImageHost { get; init; }
        public required Image ImagePreview { get; init; }
        public required TextBlock Time { get; init; }
        public required SolidColorBrush Fill { get; init; }
        public required Storyboard FillAnimation { get; init; }
        public required ColorAnimation FillKeyFrame { get; init; }
        public ClipboardItem? Item { get; set; }
        public bool IsHovered { get; set; }
    }

    /// <summary>
    /// Two recycling pools behind one factory, because the flat item source mixes section headers
    /// with cards and ItemsRepeater has no grouping of its own.
    /// </summary>
    private sealed class CardElementFactory(Func<UIElement> createCard, Func<UIElement> createHeader) : IElementFactory
    {
        private readonly Stack<UIElement> _cards = new();
        private readonly Stack<UIElement> _headers = new();

        public UIElement GetElement(ElementFactoryGetArgs args)
        {
            if (args.Data is SectionEntry)
            {
                return _headers.Count > 0 ? _headers.Pop() : createHeader();
            }

            return _cards.Count > 0 ? _cards.Pop() : createCard();
        }

        public void RecycleElement(ElementFactoryRecycleArgs args)
        {
            switch (args.Element)
            {
                case TextBlock header:
                    _headers.Push(header);
                    break;
                case Border card:
                    _cards.Push(card);
                    break;
            }
        }
    }
}
