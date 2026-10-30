# macOS audio integration review

Verdict: **native macOS integration accepted for the tested scope**. No remaining
macOS blocker found in the reviewed build. Fallback and cross-wrapper live
acceptance are separate Systems/QA work and are not implied by this verdict.

Reviewed installed DroidBridge **0.1.8 build 14**, macOS 26 / Apple Silicon:

- Host SHA-256: `08d5e7011d4febb88d8fc56eab9f65f9bd3ae5525df60d944dcf57bbadc27865`
- Audio client SHA-256: `398f98a0aad488b2e99dd3cfe1b8368c4ab423ecb9ed1ed775536313d0a5f9bc`
- Installed metadata and both hashes rechecked offline after native tests.
  `codesign --verify --deep --strict` passed. The release uses ad-hoc signing;
  this review makes no Developer ID or notarization claim.

## Source and desktop behavior

Reviewed `AudioControls.swift`, Launcher state/cleanup integration, `LauncherUI.swift`,
AppDelegate menus, wrapper factory Runtime copying/version metadata, and package
assembly. Public AppKit controls preserve the existing launcher and native windows.
Audio failures do not change video session state or replace native content.

The sidebar explicitly scopes routing to **device-wide Android audio, including
apps outside DroidBridge**. Its selection follows the selected device. The Audio
menu follows the focused native session, then an independent wrapper's immutable
serial, then the launcher selection. Native wrapper menus are constructed without
opening the launcher. A requested/actual route mismatch reports a transition;
Phone ownership failures remain actionable. “Output initialized” does not claim
that a person heard sound. Long errors wrap within five lines, retain the complete
tooltip, and expose Retry Audio / Use Phone; the actual installed failure capture
was visually inspected.

UI/controller/router access stays on MainActor. Weak callbacks avoid a controller
retain cycle. Reconciliation admits only actually running video sessions on ready
devices. `applicationShouldTerminate` returns `terminateLater` and awaits audio
shutdown plus existing video/helper cleanup before replying. No audio status
callback admits or stops video. The 32-device limit is retained; an unknown device
at capacity requests safe Phone routing without inventing a saved 33rd entry.
Preference read refusal drains this host while retaining the last accepted route
map. Audio intent uses its separate `audio-preferences.json` authority, protecting
it from older wrappers that rewrite the global preference envelope.

Wrapper factories copy the complete Runtime, including audio client/dependencies,
and derive source version/build from the host. Accepted managed wrappers therefore
have an existing maintenance upgrade path; existing manual copies need explicit
Create / Update. Factory/runtime propagation is source-reviewed here; actual
multi-wrapper audio ownership/menu tests remain with Systems.

## Executed evidence

`native/api35/result.json` and `native/api37/result.json` both have
`acceptance: true` against the exact host hash above. These are actual installed
GUI runs, not mocked audio transports. Apps launched through device/search/Launch
controls. Local Vision OCR located real Android tone buttons inside decoded native
frames; public AppKit clicks produced fresh frequency/display-bound Android logs.

Each emulator passed 13 phases: Phone/no capture; initialized Mac silence; 997 Hz;
1499 Hz; simultaneous tones; Stop/silence; distinct Mac + Phone playback/dup argv
and silence/tone/Stop controls; panel OFF with continued decoded video/tone;
Phone releasing audio/tunnel while two videos remain; audio-only termination;
actual Retry; and actual Use Phone recovery. Two distinct native windows continued
to update during audio transitions/failure. One audio client was checked despite
two video sessions.

API 35 recorded **221**, API 37 **217** aggregate successful SDL PCM blocks;
**zero dropped frames**. Exact current audio PID, unchanged production argv, and
actual bundled SDL mapping were checked. No raw PCM was recorded. The calibrated
frequency checks and retained failed attempts are explained in
`native/CALIBRATION.md`; arbitrary gain assumptions were corrected without
changing Android volume or weakening production limits. The earlier build-13 PTY
READY parser failure remains failed; build 14's normalized complete-marker gate
passed actual initialization.

Both runs restored preferences, saved sessions, owned window geometry, panel
state and exact display/forward/reverse baselines, with no cleanup errors.
Android global/input settings were unchanged; system_server PIDs were stable.
Evidence copies include only the target emulator's session events/logs;
unrelated ADB inventory rows are redacted with counts in each report.

No-device shipping UI fixtures also passed route/error/transition/capacity,
preference refusal, shutdown, long-error layout and menu-scope assertions
(`ui-run.log`). These are supplemental UI checks, not audio playback evidence.

## Boundaries

Physical speaker/phone audibility, physical OS focus and Pixel hardware behavior
remain unverified here. The desktop was locked; public AppKit/decoded-content
checks establish app behavior without claiming human focus or Cmd+Tab interaction.
No operation targeted a physical device or emulator-5554 in this review/run.

The upstream SDL Player has its own menubar; this change does not add an Audio
menu inside Player. Fallback sessions use the main DroidBridge launcher for route
controls, while native wrappers have their own Audio menu. Full fallback and
cross-wrapper ownership/transfer acceptance must use their separate live reports.
