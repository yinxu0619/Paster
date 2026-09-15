# Regression checks

Run the macOS checks with Xcode command-line tools:

```sh
bash tests/macos-test.sh
```

They exercise the production model, image processing, selection rules, privacy filters,
window level, panel content reuse across display sizes, and SwiftData persistence. The intentionally corrupt test database emits
Core Data errors; the test verifies that its original bytes survive and the temporary
fallback still works. All databases and executables are created in temporary directories.
The general clipboard and the user's history are never changed.

With .NET 8 installed, the Windows core checks also run on macOS/Linux:

```sh
dotnet run --project windows/tests/Core/Paster.Core.Tests.csproj
```

These cover equal-size image deduplication, RTF/HTML formatting, settings round trips,
legacy SQLite schema migration, blob hydration, pin/clear/history quotas, cancellation,
concurrent writes and nonblocking database lock waits.

The Windows API-dependent services and view model can be compiled without WinUI tooling:

```sh
dotnet build windows/tests/PlatformCheck/Paster.PlatformCheck.csproj
```

This is a compile check, not a replacement for building/running the full WinUI app on
Windows (`windows/scripts/build.ps1` and `windows/scripts/smoke-test.ps1`).

Manual acceptance checks:

- macOS: alternate hotkey invocation between displays with different resolutions and
  scaling (including Retina/non-Retina), in bar, sidebar and cursor modes. The panel
  should fit the target display without resetting selection or pausing to rebuild
  content. Also verify bar height changes and switching between bar/vertical layouts.
- macOS: bottom/top panel with Dock visible and auto-hide enabled; overlap must stay above
  the Dock. Repeat on another display, with the Dock on either side, and in full screen.
  Menus must still appear above the panel and clicking outside must dismiss it.
- macOS: copy in an excluded app and immediately switch apps/open Paster; the copy must
  not appear. Marked confidential/transient payloads must never enter history.
- macOS: copy a large image followed by text; verify capture order, responsiveness and
  that clearing history while processing does not bring the old image back.
- Windows: use the hotkey in editor A, switch to editor B, open history from the tray and
  paste; only B should receive it. If focus cannot be restored, content remains copied
  without sending keys to another window.
- Windows: restore a folder and a mixed selection of files/folders into Explorer.
- Both: search, delete from the middle/end, pin and copy while a query is in progress.
