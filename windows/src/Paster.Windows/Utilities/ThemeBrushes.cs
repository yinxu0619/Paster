using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Paster.Windows.Utilities;

/// <summary>
/// The single palette both windows paint from.
///
/// Two things drive the design. First, cards are built by a recycling element factory, so a card
/// must never allocate its own brushes - every element shares the instances below. Second, the app
/// has to follow the system light/dark theme at runtime, and WinUI has no code-behind equivalent of
/// a <c>{ThemeResource}</c> binding. Retinting the shared <see cref="SolidColorBrush"/> instances in
/// place solves both: <see cref="Apply"/> mutates <see cref="SolidColorBrush.Color"/> and every
/// element already referencing that brush repaints, with nothing rebuilt or rebound.
///
/// Card fills are the exception. They animate between three states per element, and an animation
/// needs a brush it exclusively owns, so cards animate a private brush between the
/// <see cref="CardBackgroundColor"/> / <see cref="CardHoverColor"/> / <see cref="CardSelectedColor"/>
/// values published here and re-read them when <see cref="Changed"/> fires.
/// </summary>
public static class ThemeBrushes
{
    private sealed record Entry(SolidColorBrush Brush, Color Light, Color Dark);

    // Declared before the brushes below: C# runs static field initialisers in textual order and
    // Register() populates this list.
    private static readonly List<Entry> Entries = [];

    public static readonly SolidColorBrush PrimaryText = Register(Rgb(32, 39, 52), Rgb(232, 235, 241));
    public static readonly SolidColorBrush SecondaryText = Register(Rgb(91, 99, 115), Rgb(166, 173, 187));
    public static readonly SolidColorBrush TertiaryText = Register(Rgb(120, 128, 145), Rgb(142, 150, 165));
    public static readonly SolidColorBrush SourceText = Register(Rgb(45, 55, 72), Rgb(219, 224, 233));
    public static readonly SolidColorBrush SectionHeaderText = Register(Rgb(110, 118, 135), Rgb(150, 158, 174));

    public static readonly SolidColorBrush CardBorder = Register(Argb(150, 225, 229, 236), Argb(150, 74, 78, 88));
    public static readonly SolidColorBrush CardBorderSelected = Register(Rgb(55, 112, 255), Rgb(96, 152, 255));

    public static readonly SolidColorBrush BadgeBackground = Register(Argb(230, 232, 238, 255), Argb(230, 45, 58, 88));
    public static readonly SolidColorBrush BadgeText = Register(Rgb(43, 85, 180), Rgb(150, 184, 255));
    public static readonly SolidColorBrush PinAccent = Register(Rgb(214, 118, 20), Rgb(255, 176, 66));
    public static readonly SolidColorBrush ImagePlaceholder = Register(Argb(140, 240, 242, 246), Argb(140, 52, 55, 62));

    /// <summary>
    /// Replaces the stock 2px accent underline on the search box, which reads as a heavy bar
    /// against the rounded cards.
    /// </summary>
    public static readonly SolidColorBrush SearchFocusBorder = Register(Rgb(126, 160, 232), Rgb(96, 130, 196));

    public static readonly SolidColorBrush SettingsBackground = Register(Rgb(246, 247, 251), Rgb(28, 29, 34));
    public static readonly SolidColorBrush SettingsCard = Register(Rgb(255, 255, 255), Rgb(40, 42, 48));

    /// <summary>
    /// Root fill painted over the acrylic backdrop. Its alpha is owned by the user's opacity
    /// setting rather than by the theme, so it is retinted through <see cref="SetPanelOpacity"/>.
    /// </summary>
    public static readonly SolidColorBrush PanelBackground = new(Argb(70, 246, 247, 251));

    private static double _panelOpacity = 0.45;
    private static bool _acrylicActive = true;

    public static bool IsDark { get; private set; }

    /// <summary>Raised after a theme flip, for state that cannot be expressed as a shared brush.</summary>
    public static event Action? Changed;

    public static Color CardBackgroundColor { get; private set; } = Argb(242, 255, 255, 255);
    public static Color CardHoverColor { get; private set; } = Argb(242, 238, 241, 248);
    public static Color CardSelectedColor { get; private set; } = Argb(245, 226, 236, 255);

    /// <summary>Tint fed to <c>DesktopAcrylicController</c>.</summary>
    public static Color AcrylicTint => IsDark ? Rgb(24, 25, 30) : Rgb(250, 250, 253);

    /// <summary>Opaque colour the OS substitutes when transparency effects are unavailable.</summary>
    public static Color AcrylicFallback => IsDark ? Rgb(32, 33, 38) : Rgb(243, 244, 248);

    public static void Apply(bool dark)
    {
        IsDark = dark;
        foreach (var entry in Entries)
        {
            entry.Brush.Color = dark ? entry.Dark : entry.Light;
        }

        // Cards stay near-opaque in both themes. The frosted look comes from the gaps between
        // cards, not from the cards themselves, which have to keep text readable over whatever
        // wallpaper happens to be behind the panel.
        CardBackgroundColor = dark ? Argb(232, 42, 44, 51) : Argb(238, 255, 255, 255);
        CardHoverColor = dark ? Argb(240, 56, 59, 68) : Argb(244, 236, 240, 248);
        CardSelectedColor = dark ? Argb(245, 40, 62, 106) : Argb(247, 226, 236, 255);

        ApplyPanelBackground();
        Changed?.Invoke();
    }

    /// <summary>
    /// 0 keeps the root fill clear so the blurred desktop shows through; 1 lays a solid theme
    /// colour over it. The acrylic controller is driven from the same value. With no acrylic behind
    /// it the root has to be fully opaque, otherwise the panel would show raw desktop pixels.
    /// </summary>
    public static void SetPanelOpacity(double opacity, bool acrylicActive)
    {
        _panelOpacity = Math.Clamp(opacity, 0, 1);
        _acrylicActive = acrylicActive;
        ApplyPanelBackground();
    }

    private static void ApplyPanelBackground()
    {
        if (!_acrylicActive)
        {
            PanelBackground.Color = AcrylicFallback;
            return;
        }

        var alpha = (byte)Math.Round(_panelOpacity * 120);
        PanelBackground.Color = IsDark
            ? Color.FromArgb(alpha, 26, 27, 32)
            : Color.FromArgb(alpha, 246, 247, 251);
    }

    private static SolidColorBrush Register(Color light, Color dark)
    {
        var brush = new SolidColorBrush(light);
        Entries.Add(new Entry(brush, light, dark));
        return brush;
    }

    private static Color Rgb(byte r, byte g, byte b) => Color.FromArgb(255, r, g, b);

    private static Color Argb(byte a, byte r, byte g, byte b) => Color.FromArgb(a, r, g, b);
}
