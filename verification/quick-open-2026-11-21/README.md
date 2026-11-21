# Automatic opening verification — 2026-11-21

The confirmed trigger is **device connection**, with the feature off by default.
Settings → General → Quick Access saves an exact device and one destination:
DroidBridge controls, a specific Android app, or the current device screen.

## Executed validation

- `swift build` passed. Full `swift test` passed: **390 tests, 4 skipped,
  0 failures**. The final targeted `swift test --filter QuickOpenTests` passed
  **4 tests**, including explicit recovery of malformed preferences. Logs are
  in `../quick-access/swift-test.log`, `quick-open-final-tests.log` and
  `admission-build.log`.
- `scripts/package.sh` passed with the exact environment in
  `package-command.json`; `package-final.log` records the final release build,
  runtime inventory and strict signature checks. This is an **ad-hoc signed
  local test artifact**, without a notarization claim.
- `scripts/verify-quick-access.sh` passed against the packaged host. See
  `runtime.log`, `runtime-results.json`, `android-commands.json` and
  `session-logs-passed/` for executed commands and their outputs.
- `scripts/verify-quick-open-cold.py --hold-for-review` exercises the packaged
  background helper with separate mode-700 QA storage. A real dedicated emulator
  startup, without a manual application launch, opened the exact copied app and
  reached native running video. `cold-live-run.log`, `cold-results.json` and
  `cold-commands.json` record the execution. Emulator startup time is included
  in the cold launch measurement; it is not a warm device-connect latency claim.
- The design agent inspected composed live AppKit Settings through CUA: all
  three destination labels, saved device, off/on states, disabled controls,
  wrapping, scrolling and keyboard access. See `../quick-access/design-review.md`
  for the exact UI sequence and observations. The cached Settings PNGs in this
  directory are **not** faithful composed captures and are excluded from visual
  acceptance; the CUA transcript contains the live screenshots.
- The held cold test also received a composed **live native-window** review:
  AppKit title chrome, complete Display-0 probe and Android navigation were
  visible, with ticks advancing **173 → 184** between screenshots. The exact
  review app was then quit. `cleanup.json` confirms its and the helper's exit,
  no owned forwards, and preservation of the original app/wrapper processes.
  `qa-broker-cleanup.json` records termination of only the two exact isolated
  test brokers and removal of their exited private QA scopes.

## Runtime observations

- Controls became the actual frontmost application and key window; process IDs
  match in `runtime-results.json`.
- Disabled, other-device and booting observations did not open a window.
  Repeated polls and readiness fluctuations did not refocus it; disconnect and
  reconnect rearmed the action.
- Display-0 native video decoded at **1080 × 1920** with changing pixel hashes.
  Resizing the Mac window preserved phone geometry. Reopening reused the same
  window. Closing during a pending reopen did not create a replacement.
- A specific app reached actual running native video in its independent wrapper.
  Reopening reused its exact PID. Disabling during wrapper preparation prevented
  a late Launch Services handoff.
- Missing app and disconnected-device messages named the problem and supplied
  a Settings or retry action. A real disconnect also showed a Retry affordance
  in the composed native window.
- The runtime harness drained owned sessions and the independent wrapper, with
  unchanged ADB-forward and Android-display counts.

## Artifact and scope

The final app was copied outside `.build`, signature-verified, and executed at:

`/Users/patrick/Library/Application Support/DroidBridge/ReviewBuilds/quick-open-2026-11-21/DroidBridge.app`

Its exact executable SHA-256 and copy verification are in `copied-artifact.json`;
the cold test verifies that same digest. `final-source-sha256.json` records the
implementation sources. The existing installed management app and unrelated
wrapper processes were preserved. No user automatic-opening preference was
enabled by these isolated tests.

Only **DroidBridge_API35 / emulator-5580**, running Android 15, was controlled.
The deterministic fixture is `dev.droidbridge.testapp20261121`, built from the
repository's Android test app. The existing default test package had a different
signer and was preserved; the unique fixture avoided uninstalling it. Generated
debug signing files are in ignored `.build/quick-access-fixtures`, outside this
evidence tree. No command targeted emulator-5554 or killed the shared ADB server.

Physical Pixel 10 Pro verification remains deferred to the owner. Developer ID
key authorization and notarization remain separate owner-side release work.
Nothing was pushed or publicly uploaded.

## Retained unsuccessful attempts

The initial package and one UI compilation raced concurrent source changes;
their logs are retained, and successful builds followed the source freeze.
Initial harness failures exposed a minimize/reopen timing assumption and the
macOS `/private/tmp` versus `/tmp` URL alias; the harness was corrected and rerun.
The first cold review outlived the exec-owned emulator, providing a real
disconnect/Retry observation; `--hold-for-review` retains it for the final live
review. These intermediate logs are not acceptance evidence.
