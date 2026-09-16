# Paster for Windows

Native Windows 11 implementation of Paster, aligned with the existing macOS app. The Windows version is built incrementally: every round compiles, runs, and preserves prior work.

## Install

Download `Paster-Windows-x64.zip` from [Releases](https://github.com/yinxu0619/Paster/releases/latest), unzip the whole folder, and run `Paster.Windows.exe`. There is no installer and the build is self-contained, so no .NET or Windows App SDK runtime is required. Because the binary is unsigned, SmartScreen may warn on first launch — choose **More info → Run anyway**.

Paster runs from the **system tray** with no taskbar entry. Press `Alt+C` to show or hide the panel, or left-click the tray icon. To quit, right-click the tray icon and choose **Quit Paster**.

## Features

Implemented in `src/Paster.Windows`:

- WinUI 3 unpackaged desktop app on .NET 8, single-instance.
- SQLite local storage under `%LOCALAPPDATA%\Paster.Windows\clipboard.db`. Nothing leaves the machine.
- Native clipboard listener via `AddClipboardFormatListener` and `WM_CLIPBOARDUPDATE`, with capture of text, URL, RTF/HTML rich text, images, and file paths.
- Native global hotkey via `RegisterHotKey`; default is `Alt+C`.
- Source app name, executable path, and extracted shell icon shown on each card.
- Panel positions: bottom / top (full-width horizontal bar), left / right (full-height sidebar), centre, and follow-cursor, each with a slide-in composition animation.
- Virtualised card list (`ItemsRepeater`) with pinned / history sections, relative timestamps, image thumbnails, hover and selection states, and smooth inertial wheel scrolling on both axes.
- Search with debounce, keyboard navigation (`←→` / `↑↓`, `Home`/`End`), Enter paste, `Ctrl+Shift+Enter` plain paste, `Del` delete, `Ctrl+P` pin, `Esc` hide, and a right-click card menu.
- Paste by writing the Windows clipboard and sending `Ctrl+V` with `SendInput` to the previously focused window.
- Settings window: language, panel position, bar height, animation bounciness, frosted-glass (acrylic) toggle and opacity, history limit, clear all, storage statistics with compact / clear decoded cache / show in Explorer, and launch at login via `HKCU\...\Run`.
- Storage hygiene: 240px JPEG thumbnails, background regeneration of oversized legacy thumbnails, and automatic `VACUUM` at launch when free space is large.
- System tray icon with a context menu (Show History, Clear History, Settings, Quit).
- Light and dark theme support, following the system theme at runtime.
- Simplified Chinese and English, following the system language or an explicit choice.

Still outstanding relative to macOS: a hotkey recorder UI, the excluded-apps editor, the full-preview window, drag-to-resize on the bar, and MSIX packaging.

## Requirements

- Windows 11 recommended; Windows 10 21H2 or newer should work.
- Visual Studio 2022 17.8+ with:
  - .NET desktop development
  - Windows App SDK / WinUI workload
  - Windows 11 SDK
- .NET 8 SDK or newer.

## Open In Visual Studio

1. Open `windows/Paster.Windows.sln`.
2. Select `x64`.
3. Set `Paster.Windows` as the startup project.
4. Press `F5`.

Paster starts into the system tray with no visible window. Press `Alt+C` to show or hide the clipboard panel, or left-click the tray icon.

## Build And Run From Command Line

If PowerShell says `dotnet` is not recognized, install the .NET SDK first:

```powershell
cd D:\coding\Paster\windows
powershell -ExecutionPolicy Bypass -File .\scripts\install-dotnet-sdk.ps1
```

Then build:

```powershell
cd D:\coding\Paster\windows
.\scripts\build.ps1 -Configuration Debug
dotnet run --project .\src\Paster.Windows\Paster.Windows.csproj -c Debug -p:Platform=x64
```

## Publish An Unpackaged EXE

For a directly runnable folder with `Paster.Windows.exe`:

```powershell
cd D:\coding\Paster\windows
powershell -ExecutionPolicy Bypass -File .\scripts\install-dotnet-sdk.ps1
.\scripts\publish-unpackaged.ps1 -Configuration Release
```

The output is:

```text
windows\artifacts\publish\Paster.Windows-win-x64\Paster.Windows.exe
```

This publish path uses `--self-contained true` and `WindowsAppSDKSelfContained=true` so the folder is suitable for unpackaged debugging and sharing as a zip during development. Keep all files in the publish folder together when running the exe.

## GitHub Actions Builds

[Windows build](https://github.com/yinxu0619/Paster/actions/workflows/windows-build.yml)
compiles the complete WinUI application on a Windows Server 2022 runner. It runs automatically
for changes under `windows/` (or to the workflow itself) pushed to `main` and for pull requests
into `main`. You can also select **Run workflow** on the Actions page.

Each successful run provides a **Paster-Windows-x64** artifact. Download it from the run's
**Artifacts** section (sign in to GitHub), extract the entire ZIP, and run `Paster.Windows.exe`.
The package includes .NET and Windows App SDK dependencies. Build artifacts are kept for
30 days; they are separate from the manually published GitHub Releases.

The workflow runs the core regression checks, compiles Windows services, publishes the app,
and verifies that it completes startup and stays running for 20 seconds. Diagnostic logs are
uploaded even on failure and kept for 14 days. GUI behavior such as pasting into another app
and multi-monitor placement still needs manual testing.

The SDK is restricted to stable .NET 8 feature bands by `global.json`, so newer SDKs preinstalled
on the runner do not silently change the build toolchain. No repository secrets are required.

## First Run Notes

- The app does not need network access and does not upload clipboard data.
- Clipboard history is stored locally in SQLite.
- Windows may restrict synthetic input in elevated or secure desktops. For best results, run Paster at the same privilege level as the target app.
- Some file clipboard payloads can only be restored if the original files still exist.

## MSIX Packaging

The project includes `Package.appxmanifest` and has MSIX tooling enabled. After the branding assets are finalized in a later round:

1. Open the solution in Visual Studio.
2. Right-click `Paster.Windows`.
3. Choose `Publish` or `Create App Packages`.
4. Select sideloading or Microsoft Store packaging.
5. Build the `.msix` bundle from the Release x64 configuration.

For CI or command-line packaging, use Visual Studio Build Tools with Windows App SDK MSIX tooling installed, then run an MSBuild publish/package target from the Release x64 configuration.

## Incremental Plan

1. ~~MVP: recording, SQLite persistence, hotkey panel, search, paste, delete, pin.~~ Done.
2. ~~Panel parity: cursor/top/bottom/left/right/center placement, horizontal bar, sidebars, wheel scrolling, slide-in animations.~~ Done, except drag-to-resize.
3. ~~Content parity: app icons, image thumbnails, richer file/URL cards.~~ Done, except the full preview window.
4. ~~Settings and privacy: history limit, launch at startup, clear history.~~ Done, except the hotkey recorder and excluded-apps editor.
5. ~~Tray and lifecycle: resident tray icon, context menu, quit/settings actions.~~ Done.
6. ~~Localization and about: Simplified Chinese and English, language switch, donation images and PayPal link.~~ Done, via in-code strings rather than `.resw`.
7. Packaging polish: MSIX package validation and a signed release. Not started; the shipped build is unpackaged and unsigned.
