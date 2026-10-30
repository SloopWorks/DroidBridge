# DroidBridge launcher redesign verification

Release: **0.1.6 build 11**, Apple Silicon, macOS 26.2. Implemented on base
`c35682b92732ba3e030edb822a5b9c7eafeda45e` (see the exact full base in
`release-inputs.json`). The installed executable SHA-256 is
`55fe5f6725dfe5bfbf0c3d9f77aaae93899aecbb54c34f79165e01b97e04811f`.

The macOS expert designed and independently reviewed the persistent Device /
Rendering / Spotlight sidebar, searchable application workspace, selected-app
actions and independently scrolling session cards. Source correctness and real
installed workflows were independently reviewed separately from compilation.
See `../../LAUNCHER_UX_DESIGN.md`, `MACOS_REVIEW.md` and `qa/QA_REVIEW.md`.

## Executed checks

| Check | Result | Evidence |
|---|---|---|
| Unit suite | 124 executed, 4 opt-in tests skipped, 0 failures | `unit.log`; actual Android checks below cover live transport separately |
| Default/minimum layout, light/dark | Pass, 1000 applications and 40 session cards; every action reachable with independent scrolling | `qa/results.json`, `qa/frozen-source.log`, eight `qa/*.png` |
| Selection, case/package search, no match | Pass; preserves selection where possible and disables launch when no match exists | source QA and `installed/gui/result.json` |
| Readiness, unauthorized/stale/failed discovery | Pass in explicit state fixtures; unread/unavailable catalogs never imply zero installed apps | `qa/QA_REVIEW.md`, `qa/results.json` |
| Emulator/app discovery | Pass, real dedicated emulator-5580, 16 launchable apps and real Android icons | `installed/gui/launcher-ready.png`, `installed/gui/result.json` |
| Two simultaneous native windows | Pass; distinct window numbers, separate actual decoded probe captures and changing content | `installed/gui/native-first-before.png`, `native-first-after.png`, `native-second.png`, `launcher-two-native.png`, session JSONL |
| Mouse/keyboard routing | Pass, separate `LauncherFirst` and `LauncherSecond` receipts on separate Android display IDs | `installed/gui/android-input.log` |
| Resize and independent close | Pass; new Android click receipt after resizing; closing one native window preserves the other | `installed/gui/android-resized-input.log`, `native-first-resized.png`, action receipts |
| Backend selector | Pass; real scrcpy Settings alongside a native app, actual `Texture (VideoToolbox): 720x1080` | `installed/gui/launcher-native-and-fallback.png`, scrcpy session log, result |
| Sidebar setup/Cancel/resume/Details | Pass; actual 16-app cohort finishes with 16 current, 0 errors and 0 pending updates | `installed/gui/onboarding-records.json`, `launcher-onboarding-complete.png`, result and action receipts |
| Create Mac App | Pass; button produces an independently signed bundle and Android ICNS from the installed host | `installed/gui/result.json`; test bundle retained under `.build/launcher-created-wrapper/` |
| Session-card stability, menu scope, shutdown discovery drain | Pass; unchanged controls retain identity/responder; Find refuses non-launcher context; current and superseded finite I/O tasks drain | `qa/frozen-source.log`, source QA report |
| Existing loading/race/cancel regressions | Pass; real decoded fixture frame, startup input fence, close/reopen behavior, late launch catch, onboarding cancellation | `regression/run.log`, `regression/launch-ux/results.json` |
| Installed wrapper startup | Pass, five real-emulator launches: three native, two scrcpy, including Launch Services | `installed/wrapper-loading/result.json`; first loading window 0.23–0.29 s, no launcher flash, native same-window handoff, restored 420×560 content geometry |
| Graceful resource cleanup | Pass; exact before/after selected-device displays/forwards/reverses restored | `installed/gui/result.json`, all five wrapper cases |
| Parent crash cleanup | Pass for both backends; virtual displays return to baseline, owned processes/forwards drain | `installed/crash/results.json`, server/session logs |
| Installation and runtime dependencies | Pass; mounted produced DMG, copied app to `~/Applications/DroidBridge.app`, ran that copy, strict deep signature and 23 Mach-O dependency trees checked with isolated PATH | `installed/dmg-mount.log`, `installed/package.json`, `package.log` |

The sidebar reuses the existing preference and phone-screen actions. Their
target/action wiring and readiness are checked by source QA; this redesign does
not introduce a new phone-power implementation. Existing Android 15/17
screen-off evidence remains under `../screen-off/`.

## Reproduce

Use the dedicated emulator-5580, never the owner's emulator-5554. Coordinate
exclusive UI/persistence ownership. Build/install the release first.

```bash
swift test
scripts/verify-launcher-redesign.sh
python3 scripts/verify-installed-launcher.py
DROIDBRIDGE_QA_OUTPUT=verification/launcher-redesign/regression/launch-ux scripts/verify-launch-ux.sh
DROIDBRIDGE_QA_OUTPUT=verification/launcher-redesign/regression/launch-race scripts/verify-launch-race.sh
scripts/verify-onboarding-cancel.sh
python3 scripts/verify-installed-launch-ux.py --output verification/launcher-redesign/installed/wrapper-loading
python3 scripts/verify-installed.py "$HOME/Applications/DroidBridge.app" --output verification/launcher-redesign/installed/crash --wrapper --mode crash
python3 scripts/verify-package.py "$HOME/Applications/DroidBridge.app" --output verification/launcher-redesign/installed/package.json
```

The installed launcher harness preserves prior session/preference bytes and
permissions, preserves its two window geometry keys, and archives its newly
created test wrapper outside Applications. Accepted managed records receive the
normal installed-version update; they are not overwritten with historical
catalog bytes. Tests use only the dedicated emulator's probe packages and
Settings. Test-only dylibs use public AppKit actions/drawing and do not ship.

`release-inputs.json` binds production/document inputs and installed executable;
`SHA256SUMS` binds the DMG and ZIP. Signing is **ad hoc**, not Developer ID or
notarization. Gatekeeper trust is not inferred from a valid local signature.

## Observations and limits

The crash tests recorded approximately 156 MiB RSS for a native host, 129 MiB for
a fallback host and 95 MiB for its Player in individual samples. These are
observations, not a sustained performance or memory-leak benchmark. Source QA
exercises large lists and checks that normal polling reuses unchanged session
controls; no new UI polling timer was added.

The desktop was locked. Captures are actual AppKit view renders, with real
Android video inside the native windows. They are not full desktop captures,
and do not establish physical foreground focus, keyboard shortcut delivery,
interactive Spotlight/Dock clicks or Cmd+Tab behavior. Menu-key context is
explicitly simulated in the source harness. Physical Pixel 10 Pro verification
remains the owner's stage in `../../PIXEL_VERIFICATION.md`.

`qa/` and `failures/` retain rejected source/test attempts. Initial source review found
truthful-count, button-readability, discovery-state, menu-scope and task-drain
issues; these were corrected before release. Installed harness corrections were
test assumptions: prefix search matching both probe packages, nested log fields,
retained resize counters/geometry, asynchronous text receipts, signature changes
after wrapper re-signing, and an absolute output path required by Launch
Services. Those failures were not substituted with mocks or reported as passes.
