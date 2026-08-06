using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Paster.Windows.Models;
using Paster.Windows.Native;
using Paster.Windows.Services;
using Paster.Windows.Utilities;
using Paster.Windows.ViewModels;
using System.Globalization;
using Windows.Graphics;
using WinRT.Interop;

namespace Paster.Windows;

public sealed class SettingsWindow : Window
{
    /// <summary>
    /// Wide enough that the QR modules survive the downscale from the source cards and stay
    /// scannable off the screen.
    /// </summary>
    private const double DonateCodeWidth = 240;

    private readonly AppSettings _settings;
    private readonly ClipboardViewModel _viewModel;
    private readonly Action _onSettingsChanged;
    private readonly ComboBox _languageBox = new();
    private readonly ComboBox _positionBox = new();
    private readonly Slider _heightSlider = new();
    private readonly Slider _animationSlider = new();
    private readonly Slider _opacitySlider = new();
    private readonly ToggleSwitch _acrylicToggle = new();
    private readonly NumberBox _historyLimitBox = new();
    private readonly ToggleSwitch _launchAtLoginToggle = new();
    private readonly TextBlock _statusText = new();
    private bool _suppressLaunchAtLoginToggle;
    private bool IsChinese => _settings.Language == AppLanguage.ChineseSimplified ||
                              (_settings.Language == AppLanguage.System &&
                               CultureInfo.CurrentUICulture.TwoLetterISOLanguageName.Equals("zh", StringComparison.OrdinalIgnoreCase));

    public SettingsWindow(AppSettings settings, ClipboardViewModel viewModel, Action onSettingsChanged)
    {
        _settings = settings;
        _viewModel = viewModel;
        _onSettingsChanged = onSettingsChanged;
        Title = T("Paster Settings", "Paster 设置");
        Content = BuildContent();
        ConfigureWindow();
    }

    private UIElement BuildContent()
    {
        var root = new ScrollViewer
        {
            Content = new StackPanel
            {
                Spacing = 16,
                Padding = new Thickness(20),
                Background = ThemeBrushes.SettingsBackground
            }
        };
        var panel = (StackPanel)root.Content;
        root.ActualThemeChanged += (_, _) => ThemeBrushes.Apply(root.ActualTheme == ElementTheme.Dark);

        panel.Children.Add(new TextBlock
        {
            Text = "Paster",
            FontSize = 26,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = ThemeBrushes.PrimaryText
        });

        _launchAtLoginToggle.OnContent = T("On", "开");
        _launchAtLoginToggle.OffContent = T("Off", "关");
        _launchAtLoginToggle.IsOn = StartupService.IsEnabled() ?? _settings.LaunchAtLogin;
        _launchAtLoginToggle.Toggled += LaunchAtLogin_Toggled;

        panel.Children.Add(Section(T("General", "常规"), new UIElement[]
        {
            LabeledControl(T("Launch at login", "开机启动"), _launchAtLoginToggle)
        }));

        panel.Children.Add(Section(T("Shortcuts", "快捷键"), new[]
        {
            LabelValue(T("Show / hide panel", "显示/隐藏面板"), "Alt+C"),
            LabelValue(T("Paste as plain text", "纯文本粘贴"), "Ctrl+Shift+Enter"),
            LabelValue(T("Delete selected", "删除选中项"), T("Del / Backspace when search is empty", "Del / Backspace（搜索框为空）"))
        }));

        var languageOptions = new List<Option<AppLanguage>>
        {
            new(AppLanguage.System, T("System", "跟随系统")),
            new(AppLanguage.ChineseSimplified, T("Chinese (Simplified)", "简体中文")),
            new(AppLanguage.English, T("English", "英文"))
        };
        _languageBox.DisplayMemberPath = nameof(Option<AppLanguage>.Label);
        _languageBox.ItemsSource = languageOptions;
        _languageBox.SelectedItem = languageOptions.First(x => x.Value == _settings.Language);
        _languageBox.SelectionChanged += (_, _) =>
        {
            if (_languageBox.SelectedItem is Option<AppLanguage> option)
            {
                _settings.Language = option.Value;
                Save(T("Language preference saved.", "语言设置已保存。"));
            }
        };

        var positionOptions = new List<Option<PanelPosition>>
        {
            new(PanelPosition.Bottom, T("Bottom", "底部")),
            new(PanelPosition.Top, T("Top", "顶部")),
            new(PanelPosition.Left, T("Left", "左侧")),
            new(PanelPosition.Right, T("Right", "右侧")),
            new(PanelPosition.Center, T("Center", "居中")),
            new(PanelPosition.Cursor, T("Follow cursor", "跟随鼠标"))
        };
        _positionBox.DisplayMemberPath = nameof(Option<PanelPosition>.Label);
        _positionBox.ItemsSource = positionOptions;
        _positionBox.SelectedItem = positionOptions.First(x => x.Value == _settings.PanelPosition);
        _positionBox.SelectionChanged += (_, _) =>
        {
            if (_positionBox.SelectedItem is Option<PanelPosition> option)
            {
                _settings.PanelPosition = option.Value;
                Save(T("Panel position saved.", "面板位置已保存。"));
            }
        };

        _heightSlider.Minimum = 160;
        _heightSlider.Maximum = 600;
        _heightSlider.StepFrequency = 10;
        _heightSlider.Value = Math.Clamp(_settings.BarHeight, 160, 600);
        _heightSlider.ValueChanged += (_, e) =>
        {
            _settings.BarHeight = e.NewValue;
            Save(T($"Bar height: {(int)e.NewValue}px", $"横条高度：{(int)e.NewValue}px"));
        };

        _animationSlider.Minimum = 0.6;
        _animationSlider.Maximum = 2.4;
        _animationSlider.StepFrequency = 0.1;
        _animationSlider.Value = Math.Clamp(_settings.AnimationBounciness, 0.6, 2.4);
        _animationSlider.ValueChanged += (_, e) =>
        {
            _settings.AnimationBounciness = e.NewValue;
            Save(T($"Animation bounciness: {e.NewValue:F1}", $"动画弹性：{e.NewValue:F1}"));
        };

        _acrylicToggle.OnContent = T("On", "开");
        _acrylicToggle.OffContent = T("Off", "关");
        _acrylicToggle.IsOn = _settings.PanelAcrylicEnabled;
        _acrylicToggle.Toggled += (_, _) =>
        {
            _settings.PanelAcrylicEnabled = _acrylicToggle.IsOn;
            _opacitySlider.IsEnabled = _acrylicToggle.IsOn;
            Save(_acrylicToggle.IsOn
                ? T("Frosted glass enabled.", "已开启毛玻璃。")
                : T("Frosted glass disabled.", "已关闭毛玻璃。"));
        };

        _opacitySlider.Minimum = AppSettings.MinPanelOpacity * 100;
        _opacitySlider.Maximum = AppSettings.MaxPanelOpacity * 100;
        _opacitySlider.StepFrequency = 5;
        _opacitySlider.Value = Math.Clamp(_settings.PanelOpacity, AppSettings.MinPanelOpacity, AppSettings.MaxPanelOpacity) * 100;
        _opacitySlider.IsEnabled = _settings.PanelAcrylicEnabled;
        _opacitySlider.ValueChanged += (_, e) =>
        {
            _settings.PanelOpacity = e.NewValue / 100.0;
            Save(T($"Panel opacity: {(int)e.NewValue}%", $"面板不透明度：{(int)e.NewValue}%"));
        };

        panel.Children.Add(Section(T("Panel", "面板"), new UIElement[]
        {
            LabeledControl(T("Language", "语言"), _languageBox),
            LabeledControl(T("Position", "位置"), _positionBox),
            LabeledControl(T("Top / bottom bar height", "顶部/底部横条高度"), _heightSlider),
            LabeledControl(T("Animation bounciness", "动画弹性"), _animationSlider),
            LabeledControl(T("Frosted glass", "毛玻璃"), _acrylicToggle),
            LabeledControl(T("Opacity", "不透明度"), _opacitySlider),
            new TextBlock
            {
                Text = T(
                    "Lower is more see-through. Windows falls back to a solid panel when transparency effects are turned off.",
                    "数值越低越通透。当系统关闭透明效果时，面板会自动回退为纯色。"),
                TextWrapping = TextWrapping.Wrap,
                FontSize = 12,
                Foreground = ThemeBrushes.TertiaryText
            }
        }));

        _historyLimitBox.Minimum = 20;
        _historyLimitBox.Maximum = 2000;
        _historyLimitBox.SmallChange = 20;
        _historyLimitBox.Value = _settings.HistoryLimit;
        _historyLimitBox.ValueChanged += (_, e) =>
        {
            if (!double.IsNaN(e.NewValue))
            {
                _settings.HistoryLimit = (int)e.NewValue;
                Save(T($"History limit: {_settings.HistoryLimit}", $"历史条数上限：{_settings.HistoryLimit}"));
            }
        };

        var clear = new Button { Content = T("Clear All History", "清空全部历史") };
        clear.Click += async (_, _) =>
        {
            await _viewModel.ClearAllAsync();
            _statusText.Text = T("History cleared.", "历史已清空。");
        };

        panel.Children.Add(Section(T("History", "历史"), new UIElement[]
        {
            LabeledControl(T("Limit", "上限"), _historyLimitBox),
            clear
        }));

        panel.Children.Add(Section(T("About", "关于"), new UIElement[]
        {
            new TextBlock
            {
                Text = T(
                    "Native Windows version of Paster. Clipboard data is stored locally only.",
                    "Paster 的 Windows 原生版本。剪贴板数据仅保存在本地。"),
                TextWrapping = TextWrapping.Wrap,
                Foreground = ThemeBrushes.PrimaryText
            }
        }));

        // Wording lifted from the macOS Localizable.strings (about.donate / about.paypal /
        // about.wechat / about.alipay) so both platforms say the same thing.
        var donate = new List<UIElement>
        {
            new TextBlock
            {
                Text = T(
                    "If you find Paster useful, consider buying the author a coffee \u2615\uFE0F",
                    "如果觉得好用，欢迎请作者喝杯咖啡 \u2615\uFE0F"),
                TextWrapping = TextWrapping.Wrap,
                Foreground = ThemeBrushes.PrimaryText
            },
            new HyperlinkButton
            {
                Content = T("Support via PayPal", "使用 PayPal 支持"),
                NavigateUri = new Uri("https://www.paypal.com/paypalme/yinxu0619")
            }
        };
        donate.AddRange(BuildDonateContent());
        panel.Children.Add(Section(T("Support the Author", "赞赏支持"), donate));

        _statusText.Text = T("Settings are saved automatically.", "设置会自动保存。");
        _statusText.Foreground = ThemeBrushes.SecondaryText;
        panel.Children.Add(_statusText);

        return root;
    }

    private void LaunchAtLogin_Toggled(object sender, RoutedEventArgs e)
    {
        if (_suppressLaunchAtLoginToggle)
        {
            return;
        }

        var desired = _launchAtLoginToggle.IsOn;
        if (StartupService.TryApply(desired))
        {
            _settings.LaunchAtLogin = desired;
            Save(desired
                ? T("Launch at login enabled.", "已开启开机启动。")
                : T("Launch at login disabled.", "已关闭开机启动。"));
            return;
        }

        _suppressLaunchAtLoginToggle = true;
        _launchAtLoginToggle.IsOn = !desired;
        _suppressLaunchAtLoginToggle = false;
        _statusText.Text = T(
            $"Could not update launch at login: {StartupService.LastError}",
            $"无法更新开机启动：{StartupService.LastError}");
    }

    /// <summary>
    /// A fresh clone may not have the donation images, so show a note rather than a broken frame
    /// when they are absent.
    /// </summary>
    private IEnumerable<UIElement> BuildDonateContent()
    {
        var donateDir = Path.Combine(AppContext.BaseDirectory, "Assets", "Donate");
        var wechat = Path.Combine(donateDir, "donate_wechat.png");
        var alipay = Path.Combine(donateDir, "donate_alipay.png");
        var previews = new List<UIElement>();

        if (File.Exists(wechat))
        {
            previews.Add(DonatePreview(T("WeChat Pay", "微信支付"), wechat));
        }

        if (File.Exists(alipay))
        {
            previews.Add(DonatePreview(T("Alipay", "支付宝"), alipay));
        }

        if (previews.Count == 0)
        {
            previews.Add(new TextBlock
            {
                Text = T(
                    "Donation QR codes are not bundled with this build. Add donate_wechat.png / donate_alipay.png to Assets\\Donate to show them here.",
                    "此版本未内置赞赏码。将 donate_wechat.png / donate_alipay.png 放入 Assets\\Donate 后即可显示。"),
                TextWrapping = TextWrapping.Wrap,
                Foreground = ThemeBrushes.TertiaryText
            });
        }

        return previews;
    }

    private static UIElement DonatePreview(string title, string imagePath)
    {
        // Width-driven with a free height: the source codes are portrait cards, so a square box
        // would letterbox them down to a module size no phone camera can resolve.
        var image = new Image
        {
            Width = DonateCodeWidth,
            Stretch = Stretch.Uniform,
            HorizontalAlignment = HorizontalAlignment.Left
        };

        try
        {
            image.Source = new BitmapImage(new Uri(imagePath));
        }
        catch (Exception ex)
        {
            AppLog.Error($"Donation image '{imagePath}' could not be loaded.", ex);
            return new TextBlock
            {
                Text = title,
                Foreground = ThemeBrushes.TertiaryText
            };
        }

        var stack = new StackPanel { Spacing = 6, HorizontalAlignment = HorizontalAlignment.Left };
        stack.Children.Add(new TextBlock
        {
            Text = title,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = ThemeBrushes.PrimaryText
        });
        stack.Children.Add(new Border
        {
            CornerRadius = new CornerRadius(10),
            // Deliberately white in both themes: a QR needs a light quiet zone, and a dark plate
            // behind a code supplied as a transparent PNG would make it unscannable.
            Background = new SolidColorBrush(Colors.White),
            BorderBrush = ThemeBrushes.CardBorder,
            BorderThickness = new Thickness(1),
            Padding = new Thickness(6),
            HorizontalAlignment = HorizontalAlignment.Left,
            Child = image
        });
        return stack;
    }

    private void Save(string status)
    {
        _settings.Save();
        _statusText.Text = status;
        _onSettingsChanged();
    }

    private static Border Section(string title, IEnumerable<UIElement> children)
    {
        var stack = new StackPanel { Spacing = 10 };
        stack.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 16,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = ThemeBrushes.PrimaryText
        });
        foreach (var child in children)
        {
            stack.Children.Add(child);
        }

        return new Border
        {
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(14),
            Background = ThemeBrushes.SettingsCard,
            BorderBrush = ThemeBrushes.CardBorder,
            BorderThickness = new Thickness(1),
            Child = stack
        };
    }

    private static Grid LabelValue(string label, string value)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(new TextBlock { Text = label, Foreground = ThemeBrushes.PrimaryText });
        var valueText = new TextBlock
        {
            Text = value,
            Foreground = ThemeBrushes.SecondaryText
        };
        Grid.SetColumn(valueText, 1);
        grid.Children.Add(valueText);
        return grid;
    }

    private static Grid LabeledControl(string label, Control control)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(150) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(new TextBlock
        {
            Text = label,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = ThemeBrushes.PrimaryText
        });
        Grid.SetColumn(control, 1);
        grid.Children.Add(control);
        return grid;
    }

    private void ConfigureWindow()
    {
        var hwnd = WindowNative.GetWindowHandle(this);
        var windowId = Win32Interop.GetWindowIdFromWindow(hwnd);
        var appWindow = AppWindow.GetFromWindowId(windowId);
        appWindow.Title = T("Paster Settings", "Paster 设置");
        if (AppIcons.WindowIconPath is { } iconPath)
        {
            appWindow.SetIcon(iconPath);
        }

        // Resize takes physical pixels while the content is laid out in DIPs, so a fixed size
        // shrinks the window on a scaled display and clips the donation codes.
        var dpi = NativeMethods.GetDpiForWindow(hwnd);
        var scale = dpi == 0 ? 1.0 : dpi / 96.0;
        appWindow.Resize(new SizeInt32((int)(560 * scale), (int)(680 * scale)));
    }

    private string T(string english, string chinese) => IsChinese ? chinese : english;

    private sealed record Option<T>(T Value, string Label);
}
