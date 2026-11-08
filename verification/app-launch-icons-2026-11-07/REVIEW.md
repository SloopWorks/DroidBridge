# Independent macOS / Swift review

Status: accepted for the reviewed local build. No unresolved blocking code findings remain for automatic Android app wrappers and visible launch progress. This is feature acceptance, not public-release or physical-device certification.

The review covered `AppLaunch.swift`, `AppLaunchSessions.swift`, `MacAppWrapper.swift`, `DesktopAppSessions.swift`, and their launcher/UI integration. Existing connection-recovery changes were preserved.

Findings resolved during review:

- Matching running wrappers now take precedence across managed, manual and private-cache locations. Exact phone/package/backend checks prevent retargeting saved wrappers.
- Preparation shows immediate app-named progress across navigation, supports cancellation before Launch Services handoff, and drains owned work during shutdown. Handoff confirms opening without claiming running video.
- Sessions rediscovers live wrappers after management-app restart without companion pairing. Missing/stale snapshots and absent initial status cannot retain a false Running claim; actual fallback backend is represented.
- PID/start-time and bundle identity checks protect process actions. Directory URL hints no longer break equivalent process identity. Snapshot publication remains bounded, atomic and generation fenced.
- Detached polling receives cancellation. Per-app preparation uses a private, validated, close-on-exec kernel lock with bounded cancellable contention and release on failure.

Evidence inspected:

- `swift-test-final.log`: 357 tests, 4 skipped, zero failures. The registry tests exercise ownership, generation fencing, directory URL hints, malformed/unsafe files, backend changes, bounded locking and cancellation.
- `resolver/resolver-results.json` and `resolver/run.log`: 21 fixture checks, including live-cache preference, wrong phone/backend rejection, icon dimensions, and preparation-lock contention/cancellation. Held-lock timeout was 1.017 seconds; cancellation returned in approximately 0.000056 seconds. These checks make no Android or application-launch claims.
- `runtime-final/results.json`, `runtime-final/run.log`, and the shipping-source harness: real emulator native decoded-content presentation, two independent regular app identities, Android-to-ICNS and running application icon pixel error of zero, same process/session reuse and unhide, progress across navigation, cancellation, unpaired rediscovery, missing-status handling, and exact application close. The scrcpy case separately checks application launch and video texture output plus its regular Player identity.
- `packaged-android-window.png` shows the named Android app with live probe content; `packaged-sessions.png` shows its Running row while the companion is unpaired. `ui-main.log` records repeated packaged launches returning PID 94032. `packaged-close.ax.txt` records the session row disappearing.
- `final-resource-cleanup.json` records restoration of display/forward state and shutdown of only the owned API35 emulator on port 5580, with shared ADB and emulator-5554 preserved.

The artifact is `/Users/patrick/Library/Application Support/DroidBridge/ReviewBuilds/app-launch-icons-22/DroidBridge.app`, version 0.2.0, build 22. I independently checked its executable SHA-256 as `9d9bc9eb5a2d44be74f3ac7441c7d71e754cc1c950a951d67c546ec8c74e9757`, verified all 145 entries in `source-sha256.json` against current files, and reran `codesign --verify --deep --strict` successfully. The packaged application was run outside the build directory.

Limitations: signing is ad hoc; notarization is not established. Physical Pixel acceptance remains owner-deferred. Actual Dock and Cmd+Tab visual inspection was not completed: the evidence proves separate regular application identities and Android icon pixels programmatically, not visual switcher acceptance. No push, public distribution or production acceptance is implied.
