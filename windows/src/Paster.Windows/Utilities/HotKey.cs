using Paster.Windows.Native;
using Windows.System;

namespace Paster.Windows.Utilities;

/// <summary>
/// Single place that turns a RegisterHotKey modifier mask plus virtual key into something a user
/// can read, so the panel footer, the startup status line, the tray and the settings recorder all
/// agree instead of each hard-coding "Alt+C".
/// </summary>
public static class HotKey
{
    /// <summary>Win, Ctrl, Alt, Shift then the key, matching how Windows itself writes shortcuts.</summary>
    public static string Describe(uint modifiers, int virtualKey, bool chinese)
    {
        var parts = new List<string>(4);
        if ((modifiers & NativeMethods.ModWin) != 0) { parts.Add("Win"); }
        if ((modifiers & NativeMethods.ModControl) != 0) { parts.Add("Ctrl"); }
        if ((modifiers & NativeMethods.ModAlt) != 0) { parts.Add("Alt"); }
        if ((modifiers & NativeMethods.ModShift) != 0) { parts.Add("Shift"); }
        parts.Add(KeyName(virtualKey, chinese));
        return string.Join("+", parts);
    }

    /// <summary>
    /// True when the mask carries at least one modifier. A bare key cannot be a global hotkey:
    /// it would fire while the user is typing anywhere in Windows.
    /// </summary>
    public static bool HasModifier(uint modifiers) =>
        (modifiers & (NativeMethods.ModWin | NativeMethods.ModControl | NativeMethods.ModAlt | NativeMethods.ModShift)) != 0;

    /// <summary>Modifier keys are the combination, never the key being combined.</summary>
    public static bool IsModifierKey(VirtualKey key) => key is
        VirtualKey.Control or VirtualKey.LeftControl or VirtualKey.RightControl or
        VirtualKey.Menu or VirtualKey.LeftMenu or VirtualKey.RightMenu or
        VirtualKey.Shift or VirtualKey.LeftShift or VirtualKey.RightShift or
        VirtualKey.LeftWindows or VirtualKey.RightWindows;

    /// <summary>Reads the live modifier state, which key events do not carry in WinUI.</summary>
    public static uint CurrentModifiers()
    {
        uint modifiers = 0;
        if (IsDown(NativeMethods.VkControl)) { modifiers |= NativeMethods.ModControl; }
        if (IsDown(NativeMethods.VkMenu)) { modifiers |= NativeMethods.ModAlt; }
        if (IsDown(NativeMethods.VkShift)) { modifiers |= NativeMethods.ModShift; }
        if (IsDown(NativeMethods.VkLWin) || IsDown(NativeMethods.VkRWin)) { modifiers |= NativeMethods.ModWin; }
        return modifiers;
    }

    private static bool IsDown(int virtualKey) => (NativeMethods.GetKeyState(virtualKey) & 0x8000) != 0;

    private static string KeyName(int virtualKey, bool chinese)
    {
        var key = (VirtualKey)virtualKey;
        if (key is >= VirtualKey.A and <= VirtualKey.Z)
        {
            return key.ToString();
        }

        if (key is >= VirtualKey.Number0 and <= VirtualKey.Number9)
        {
            return ((int)key - (int)VirtualKey.Number0).ToString();
        }

        if (key is >= VirtualKey.NumberPad0 and <= VirtualKey.NumberPad9)
        {
            return "Num" + ((int)key - (int)VirtualKey.NumberPad0);
        }

        if (key is >= VirtualKey.F1 and <= VirtualKey.F24)
        {
            return "F" + ((int)key - (int)VirtualKey.F1 + 1);
        }

        return key switch
        {
            VirtualKey.Space => chinese ? "空格" : "Space",
            VirtualKey.Enter => chinese ? "回车" : "Enter",
            VirtualKey.Tab => "Tab",
            VirtualKey.Back => chinese ? "退格" : "Backspace",
            VirtualKey.Delete => "Delete",
            VirtualKey.Insert => "Insert",
            VirtualKey.Home => "Home",
            VirtualKey.End => "End",
            VirtualKey.PageUp => "PageUp",
            VirtualKey.PageDown => "PageDown",
            VirtualKey.Left => chinese ? "左方向键" : "Left",
            VirtualKey.Right => chinese ? "右方向键" : "Right",
            VirtualKey.Up => chinese ? "上方向键" : "Up",
            VirtualKey.Down => chinese ? "下方向键" : "Down",
            _ => KeyFromChar(virtualKey) ?? $"0x{virtualKey:X2}"
        };
    }

    /// <summary>Punctuation keys have no friendly name in <see cref="VirtualKey"/>.</summary>
    private static string? KeyFromChar(int virtualKey) => virtualKey switch
    {
        0xBA => ";",
        0xBB => "=",
        0xBC => ",",
        0xBD => "-",
        0xBE => ".",
        0xBF => "/",
        0xC0 => "`",
        0xDB => "[",
        0xDC => "\\",
        0xDD => "]",
        0xDE => "'",
        _ => null
    };
}
