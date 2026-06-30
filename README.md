# Paster — Native macOS Clipboard Manager

[中文 README](README.zh-CN.md)

A native macOS clipboard history manager. Records clipboard content in the background, opens a panel with a global hotkey, supports text / rich text / images / files / URLs, with local-only storage and no network access.

> This project was built through multiple incremental iterations to deliver V1.0 (macOS). All code extends prior work without rewriting core logic.

## Download

**macOS 14.0+** — get the latest pre-built app from [Releases](https://github.com/yinxu0619/Paster/releases/latest):

1. Download `Paster.zip` and unzip
2. Drag `Paster.app` to Applications
3. If macOS blocks the app on first launch: `xattr -d com.apple.quarantine /Applications/Paster.app`
4. Grant **Accessibility** permission (System Settings → Privacy & Security → Accessibility) for auto-paste
5. Paster lives in the **menu bar** (no Dock icon). Click the icon or press `⌘⇧V` to open the panel

## Features

- **Persistent clipboard history**: Monitors the system clipboard in the background and records plain text, rich text, images, file paths, and URLs. Each entry includes type label, timestamp, and source app name + icon. Data stays 100% local (SwiftData) — no network, no uploads.
- **Global hotkey**: Default `⌘⇧V` to open the panel from any app; **customizable in Settings**; auto-hides on focus loss; close with `Esc` or the hotkey again.
- **Configurable panel position**: Follow cursor (floating), bottom / top / left / right / center of screen, each with slide-in animation from the corresponding edge.
  - **Bottom / Top**: Full-width horizontal bar rising from the screen edge; bar height adjustable via **Settings slider (with preview)** or **drag the top edge** after opening; cards scale with height; **mouse wheel / trackpad** navigates selection horizontally.
  - **Left / Right**: Full-height vertical sidebar.
- **Multiple paste modes**: Paste with formatting, paste as plain text, copy again; context menu and keyboard shortcuts; **plain-text paste shortcut configurable in Settings** (default `⌘⇧↩`).
- **Search & organization**: Real-time keyword search and source app filter; pinned items in a separate Pinboard group at the top.
- **Full keyboard control**: `↑↓` (horizontal bar: `←→`) to select, `Home`/`End` for first/last, Return to paste, `⌘⇧↩` for plain text, `⌘⌫` to delete, `⌘P` to pin, `⌘Y` for full preview, `Esc` to close; search field auto-focused on open.
- **Privacy & settings**: Excluded apps list (sensitive apps not recorded), history limit, clear all, launch at login, menu bar icon.
- **Polish**: Card layout, image thumbnails, hover/selection effects, slide-in animations, dark/light mode and multi-display support.
- **About page**: App info and donation QR codes (WeChat / Alipay / PayPal).
- **Localization**: Simplified Chinese / English — switch in Settings or follow system language.

## Tech Stack

| Item | Choice |
| --- | --- |
| Language | Swift 5+ |
| UI | SwiftUI + AppKit (global hotkeys, clipboard monitoring, menu bar, NSPanel) |
| Storage | SwiftData (local) |
| Architecture | MVVM |
| Minimum OS | macOS 14.0 |

## Project Structure

```
Paster/
  App/         PasterApp.swift (entry), AppDelegate.swift (menu bar / hotkeys / panel / preview / settings)
  Models/      ClipboardItem.swift (@Model), ClipboardItemType.swift, PanelPosition.swift,
               PlainPasteShortcut.swift, AppLanguage.swift
  Services/    PersistenceManager.swift, ClipboardMonitor.swift, HotKeyManager.swift,
               PasteService.swift, AppSettings.swift
  ViewModels/  ClipboardViewModel.swift, SettingsViewModel.swift
  Views/       PanelRootView.swift, ClipboardCardView.swift, SearchBarView.swift,
               SettingsView.swift, PreviewView.swift, AboutView.swift, HotKeyRecorder.swift
  Window/      FloatingPanel.swift (NSPanel)
  Utilities/   ImageUtils.swift, AppIconProvider.swift, KeyCodeTranslator.swift,
               Localization.swift
  Resources/   Assets.xcassets, Paster.entitlements, Paster.icns, Donate/ (QR codes),
               zh-Hans.lproj/ en.lproj/ (localization)
scripts/       build_check.sh (compile/type-check), build_app.sh (manual .app packaging),
               make_icon.swift / make_icns.swift (icon generation)
```

## Data Flow

```
NSPasteboard --changeCount poll--> ClipboardMonitor --write--> SwiftData
                                                              |
HotKey(⌘⇧V) --open--> FloatingPanel --PanelRootView(@Query)<--+
                                          |
                       Return/double-click --> hide panel -> activate target app -> PasteService simulates ⌘V
```

## Build & Run

Requirements: macOS 14.0+, Xcode 16+.

1. Open `Paster.xcodeproj`.
2. Select the `Paster` scheme, press `⌘R` to run.
3. First launch permissions:
   - **Accessibility** (System Settings → Privacy & Security → Accessibility): required to simulate `⌘V` paste.
   - The app lives in the menu bar (no Dock icon). Click the icon or press `⌘⇧V` to open the panel.

> Note: Each rebuild (ad-hoc signing changes) may require **re-granting Accessibility**. If an old Paster entry exists in the list, remove it and add the new build again — otherwise simulated `⌘V` is silently ignored (clipboard updates but paste does not happen).

### Command-line verification

```bash
bash scripts/build_check.sh
```

The script tries `xcodebuild` first; if Xcode CLI tools are broken on the machine, it falls back to `swiftc -typecheck` with SwiftData macro plugins for full type checking.

### Package as .app

```bash
bash scripts/build_app.sh
```

Compiles all sources with `swiftc`, assembles `build/Paster.app` (icons, donation QR codes, localization, ad-hoc signing) and `build/Paster.zip`. If the icon does not refresh in Finder:

```bash
touch build/Paster.app && killall Finder Dock
```

## Shortcuts

| Action | Shortcut |
| --- | --- |
| Open / hide panel | `⌘⇧V` (customizable) |
| Close panel | `Esc` |
| Select | `↑` / `↓` (horizontal bar: `←` / `→`, or mouse wheel / trackpad) |
| First / last item | `Home` / `End` |
| Paste (keep formatting) | `Return` |
| Paste plain text | `⌘⇧↩` (configurable in Settings) |
| Delete selected | `⌘⌫` |
| Pin / unpin | `⌘P` |
| Full preview | `⌘Y` |
| Open Settings | `⌘,` |

## Privacy

All clipboard data is stored locally in SwiftData. The app makes no network requests. Add password managers and other sensitive apps to the excluded list in Settings — their clipboard content will not be recorded.

## Support the Author

If you find Paster useful, consider buying the author a coffee ☕️

<table>
  <tr>
    <td align="center"><img src="Paster/Resources/Donate/donate_wechat.png" width="220" alt="WeChat Pay"><br/>WeChat Pay</td>
    <td align="center"><img src="Paster/Resources/Donate/donate_alipay.png" width="220" alt="Alipay"><br/>Alipay</td>
  </tr>
</table>

Or support via [PayPal](https://www.paypal.com/paypalme/yinxu0619).

## Roadmap

- V1.0 (this repo): Native macOS version.
- V2.0 (planned): Windows 11 (WinUI 3 + C#), aligned with macOS core features and interaction.

## License

MIT
