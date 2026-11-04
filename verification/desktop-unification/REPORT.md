# Unified DroidBridge desktop verification

2026-11-04. One Mac management window now contains Apps, Sessions, Handoff,
Notifications and Devices. One toolbar device selector and one visible app catalog
replace the overlapping launcher/Companion dashboards. Android apps still run on
Android in independent native windows; the Android companion and background Mac
broker retain their distinct technical roles.

## Review artifact

- Version 0.2.0, build 20, arm64.
- Tested copy outside the build directory:
  `/Users/patrick/Library/Application Support/DroidBridge/ReviewBuilds/unified-0.2.0-20/DroidBridge.app`.
- Local ad-hoc signature; **not notarized or approved for public distribution**.
- Executable SHA-256:
  `d0a4207cd7dbf9567d5e6e12004d1bbace97ecc31a1e33bd9c966fd73f530b55`.
- [Artifact metadata](installed-artifact.json), [package log](package.log),
  [final strict signature check](final-signature-check.log).

The package script also produced local DMG/ZIP files under `dist/unified-desktop`.
No public upload, push or production deployment was performed. Signing credentials
were not accessed for this work.

## Product and code changes

- Native split-view sidebar, a shared live Android context, content-specific window
  titles and standard View/Devices/Apps/Handoff/Help commands.
- Embedded existing Companion task views; production entry points no longer open
  the standalone Companion management window. Existing transport, trust, receipts
  and command handlers remain the owners of their operations.
- Unified Apps keeps launch, portable Mac wrapper creation, favorites, per-app
  Spotlight selection and pending-export retry. Favorites sort first. Shared
  catalog synchronization remains visibility-bound; there is no second visible
  app list or second catalog client.
- Sessions preserves local native/fallback controls and independent wrapper owner
  routing. Exact local session IDs are omitted from the independent list. Local
  presentation and restoration follow the selected phone's authenticated aliases;
  no-selection recovery explicitly identifies its all-device scope.
- Real Command-Comma Settings: General, Integration and About; remembered pane and
  pane title. New-window defaults and global Spotlight enablement live there.
  Audio, phone screen, profile and bulk setup/progress/cancel/results remain in
  Device Settings. No nonfunctional account or subscription screen was added.
- Offline saved-pairing management remains explicit in Devices and cannot silently
  retarget install/connect actions away from the toolbar's live ADB device.
- Embedded lifecycle tracks the actual host window/page/device/trust. Close,
  navigation and changed trust fence late callbacks. Typed task menu commands use
  the retained buttons and existing handlers.

The [design review and complete feature mapping](../../docs/UNIFIED_DESKTOP_DESIGN.md)
distinguish Apple guidance, product choices, executed checks and remaining limits.
Concurrent Android/release work was preserved.

## Executed verification

| Check | Result and evidence |
| --- | --- |
| `swift test` | 340 tests, 4 skipped, 0 failures; [log](swift-test.log) |
| `scripts/verify-unified-desktop.sh` | PASS: shipping AppKit composition with anonymous XPC fixture, 1000 apps, two fake phone/trust contexts, 32 route/size/appearance cases and 38 captures. One workspace and one Settings window; [results](../unified-desktop/fixture/results.json), [log](../unified-desktop/fixture/run.log). This is not real Android or physical-input acceptance |
| `scripts/package.sh` | PASS in explicit ad-hoc mode, version/build above, pinned scrcpy 5.0.1, current Android release APK, relocated runtime and strict nested signatures. [Log](package.log) |
| Installed real pairing/native video | Actual Android QR decoded privately, comparison code matched and approved on phone, pinned TLS connected, unified app catalog launched real Companion Verification native windows. [Installed evidence](../unified-desktop/installed/), [native video](../unified-desktop/installed/native-android-fixture.png) |
| Phone-to-Mac effects | Profile, explicit clipboard copy, owned-loopback URL opening and three-step desktop preset all applied; [Android effects](../unified-desktop/installed/desktop-actions.json), [instrumentation](../unified-desktop/installed/desktop-android-instrumentation.log) |
| Streaming independence | New decoded frames after explicit Android companion service stop and native resize; both app windows remained alive. Recorded in the installed run's structured events |
| Actual file transport | Three 2 MiB downloads with hash verification; [benchmark](../unified-desktop/installed/actual-transport-performance.json) |
| Actual file Save/Reveal | Physical CUA continuation used native Save, verified 2,097,152 bytes and SHA-256, observed phone completion confirmation, and verified Finder selected the exact saved file. [Continuation](manual-continuation.json), [Handoff image](native-handoff.png) |
| Native pointer and keyboard | Physical CUA launched `dev.droidbridge.testapp` using search/Return, clicked counter to 1 and typed `unifiedreview` on display 10. Changing ticks showed continuing video. [Image](native-input.png), [bounded fixture log](native-input.log) |
| Native window/keyboard behavior | Command-Comma, remembered Settings pane, Command-1/2, scoped Android shortcuts, Command-Control-S, exact session Close, management Close preserving app windows, and Command-L reopening Sessions with both windows observed. [Continuation](manual-continuation.json) |
| Native layout | Actual light Apps, Handoff, all three Settings panes, and minimum-size Sessions inspected. Lower independent-session controls reached by scrolling. [Final Apps](native-apps-final.png), [minimum Sessions](native-sessions-minimum.png), [General](native-settings-general.png), [Integration](native-settings-integration.png), [About](native-settings-about.png) |
| Cleanup | Exact QA host exited, own pairing cleanup passed, no session/icon receipts, no emulator-5580 forwards and only built-in display remained. Prior normal app stayed running. [Cleanup](cleanup.json), [pairing cleanup](../unified-desktop/installed/pairing-cleanup.log). The AVD started for this task was then stopped by exact serial; [log](emulator-stop.log) |

## Scripted-run and environment limits

The full installed script's [original result](../unified-desktop/installed/results.json)
remains **failed**. Its test observer reported menu dispatch success while the
management window was not key and stayed on Sessions, so its subsequent Refresh
Inbox lookup failed. Physical Handoff selection worked immediately in the same
retained process; the actual Save, verification, Finder reveal, keyboard/input,
minimum-size and close/reopen checks then passed. These observations are recorded
separately in [manual-continuation.json](manual-continuation.json); they do not
rewrite the failed automation result.

The observer now waits for app/window focus and verifies the resulting route before
reporting success. That final harness correction compiled but has not received a
new full installed run. Earlier failed attempts are retained separately, including
a private-root validation mistake, reused-pairing setup assumptions, old idle QA
helpers competing for the emulator's event-poll slot, and name-disambiguation in
Android's recipient chooser. The chooser now matches the exact trust-specific
label and scrolls only its observed dialog list.

Only idle, explicitly scoped older QA helpers for emulator-5580 were stopped after
checking their plist arguments and absence of live hosts. Production services and
emulator-5582 were excluded. [Inventory](qa-helper-inventory.json),
[exact cleanup results](idle-qa-helper-cleanup.json). No shared ADB server was killed;
the user's emulator-5554 and physical phones were not operated.

## Remaining release acceptance

This completes the desktop consolidation and the executed review above. It is not
an exhaustive HIG certification. Native system dark mode, VoiceOver, Full Keyboard
Access, Increase Contrast and Reduce Transparency have not all been independently
operated in this installed cohort. Light/dark fixture rendering has its own stated
capture limitations. Existing Spotlight indexing, native notification banners,
fallback/physical-phone gates are not waived. Pixel 10 Pro remains owner-deferred.

Developer ID signing authorization, notarization authentication and accepted public
artifacts remain separate release work, as documented in `AGENTS.md` and the
existing release ledger. Compilation, a local signature or a download label does
not establish public release acceptance.
