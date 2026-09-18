# Regression checks

Run the macOS checks with Xcode command-line tools:

```sh
bash tests/macos-test.sh
```

They exercise the production model, image processing, selection rules, privacy filters,
window level, panel content reuse across display sizes, entrance interruption and Reduce Motion,
SwiftData persistence, and the
separate image storage (legacy inline images are migrated on open and cascade on delete),
thumbnail regeneration, the decoded-thumbnail cache, storage statistics and VACUUM
compaction with the container open. The intentionally corrupt test database emits
Core Data errors; the test verifies that its original bytes survive and the temporary
fallback still works. All databases and executables are created in temporary directories.
The general clipboard and the user's history are never changed.

For visible macOS navigation checks (temporarily takes keyboard focus):

```sh
bash tests/macos-motion-test.sh --full-width
```

This shows a synthetic panel on the display containing the pointer, checks minimal
edge scrolling, reversing direction, Home/End, repeated End after manual scrolling,
and each entrance mode, then closes it. Omit `--full-width` for a 940-point test window.
It uses an in-memory database and a separate bundle identifier; it never launches the
clipboard monitor or registers a global hotkey. Requires access to the macOS GUI.

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

- macOS motion: in Settings → Animations, try Smooth / Elastic / Fade / Off and toggle
  list animations. Repeat with system Reduce Motion enabled. Quickly open, dismiss, and
  reopen the panel; shadows must remain stable, with no late animation after hiding.
- macOS navigation: move among visible horizontal cards (the row should stay still),
  pass either edge, then reverse. Test Home/End and repeated navigation after manually
  scrolling away. Reopening restores selection without a second scrolling animation.
- macOS input: trackpad scrolling and momentum must move continuously without changing
  selection; a discrete mouse wheel still steps through items. Repeat with animations off.

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
