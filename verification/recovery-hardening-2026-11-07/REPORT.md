# Connection recovery hardening — 7 November 2026

## Result

Implemented and verified automatic recovery for stream failures that occur while ADB still reports the device connected. The running app's native window survives recovery. Sleep waits, finite retry admission, explicit cancellation and exact-resource cleanup are verified with the deterministic Android application on `DroidBridge_API35` / `emulator-5580`.

The packaged **0.2.0 build 21**, copied outside `.build` and executed there, passed both native AppKit and scrcpy recovery tests, including an actual scoped ADB transport interruption. This is an **ad-hoc signed local build**, not a notarized/public release.

Artifact: `/Users/patrick/Library/Application Support/DroidBridge/ReviewBuilds/connection-recovery-21/DroidBridge.app`.

Main executable SHA-256: `b3f5899d289f6c665b073c375a045425e23330f0f013af24ab878a4abdb6cd5f`.

The previously running build-20 copies were not replaced or terminated. Use build 21 after quitting those copies when ready; the old processes cannot acquire the new recovery behavior without relaunch. No physical phone interaction was performed by the agent during this implementation.

## Changes

- Typed native socket closure/error and unexpected supervised process exit now enqueue recovery directly. Recovery does not depend on a discovery poll observing the phone absent.
- Both video and control-channel closure are observed; socket failure diagnostics distinguish EOF from an operating-system error. Intentional shutdown remains fenced.
- Recovery drains predecessor cleanup before admitting its replacement and transfers the same native NSWindow. Frame attachment clears old image/loading/input state and rejects callbacks from a replaced session.
- An interrupted chain permits at most three automatic launches, spaced at least eight seconds apart. A briefly running successor retains the consumed budget. Sixty stable seconds allow a fresh budget at the next interruption. Manual Retry explicitly starts a fresh budget.
- Positive system sleep detection shows wake/unlock guidance and waits without opening another video server or spending retry attempts. No automatic wake, lock bypass, global stay-awake setting or screen-timeout change was introduced. Unknown OEM power output permits ordinary bounded admission rather than fabricating sleep.
- Wakefulness is independent of physical panel power. Explicit phone-screen-off use and recovery with that preference enabled remain functional.
- A native, accessibility-labeled Retry button replaces generic backend-switch advice. Disabled recovery, sleep wait and exhausted recovery have actionable messages.
- Close, Quit and manual Retry recheck exact session ownership after suspension. Invalid configuration and a normally closed fallback window do not initiate automatic recovery.
- Native resource/recovery events make subsequent incidents traceable. If the supervisor removes the same forward concurrently, GUI cleanup confirms the exact owned mapping is gone instead of retaining a false failure receipt; foreign mappings are never retried for deletion.

## Requirement-to-evidence audit

| Requirement | Executed evidence |
| --- | --- |
| Recover without device absence | `fixture/fixture-results.json`, three real owned Android server terminations while `get-state` remains `device`; decoded content in successor AppKit views. |
| Finite recovery under repeated drops | Fixture attempts remain 1, 2, 3 across running successors; fourth interruption stays paused even after its delay expires. `fixture/retry-limit-window.png` inspected. |
| Manual Retry and automatic-recovery preference | Shipping native Retry button clicked after exhaustion; fresh session in the same window. Recovery disabled produces zero automatic launches; re-enabling resumes. |
| Sleep waits and wake recovery | Three recovery polls while asleep consume zero attempts; waking the dedicated emulator resumes decoded content. Initial sleeping launch is classified before server staging. `fixture/waiting-for-wake-window.png` inspected. |
| Preserve intentional panel-off use | `screen-off/fixture-results.json`: frames continue with physical display 0 off; a real interrupted session recovers while screen-off intent remains enabled. |
| Preserve minimized window | Screen-off fixture's second recovery retains the same window number and its minimized state. |
| Do not resurrect closed sessions | Fixture closes the sleeping window, and separately closes during a delayed real power probe; no replacement is admitted. Quit during that probe leaves owned sessions stopped. |
| Permanent failures remain terminal | Invalid configuration stays failed with no automatic budget. Four focused tests include a supervised, renderer-ready fallback process exiting normally with no recovery request. |
| Exact resource cleanup | Fixture ends with zero session forwards, Android servers and receipts. Existing foreign-forward ownership tests pass. Packaged acceptance observes remote shell cleanup settle within 0.25 seconds after host exit, and verifies zero remaining scrcpy displays/forwards. |
| Shipping artifact, native backend | `installed/results.json`: real decoded AppKit content after exact owned-server failure and after `adb -s emulator-5580 reconnect`; same host PID and native window survive. |
| Shipping artifact, fallback backend | Same installed result: supervised SDL-client failure and scoped ADB reconnect both produce a decoded/rendered successor; host PID survives. |
| Build/unit checks | `build.log`, final fixture build logs, `unit-tests.log`: full suite **343 tests, 4 skipped, 0 failures**. A subsequently added normal-fallback-exit regression passes among **4 focused recovery tests** in `final-recovery-tests.log`; executable product sources were unchanged by that test addition. |
| Release packaging/signature | `package.log`: `scripts/package.sh` succeeded. `artifact.json`: build 21, deep/strict codesign verification succeeds on the external copy, bundled architecture document matches source. |
| Isolation | `final-processes.txt`: shared ADB server remains PID 15163, original GUI processes remain. Only emulator-5580 was controlled; emulator-5554 was not accessed. The dedicated emulator started for this work was shut down after verification. QA broker launch agents were removed by exact scope/label. |

The packaged second-interruption tests resumed decoded content in approximately **12.0 seconds native / 12.4 seconds fallback**, including the carried retry delay and polling. These are observed emulator results, not a physical-device latency guarantee.

## Commands

Full output is retained beside this report and inside each fixture/installed directory.

```text
swift build
swift test
swift test --filter 'ConnectionRecoveryTests|HiddenIMEArgumentTests|NativeStartupExitTests|DeviceReadinessTests'
swift test --filter ConnectionRecoveryTests
DROIDBRIDGE_TEST_PACKAGE=dev.droidbridge.testapp7 DROIDBRIDGE_TEST_OUTPUT=<repo>/.build/recovery-testapp7 scripts/android-build-testapp.sh
bash scripts/verify-connection-recovery.sh
DROIDBRIDGE_RECOVERY_EVIDENCE=<repo>/verification/recovery-hardening-2026-11-07/screen-off bash scripts/verify-connection-recovery.sh --screen-off-check
DROIDBRIDGE_BUILD_NUMBER=21 DROIDBRIDGE_SIGNING_MODE=adhoc DROIDBRIDGE_OUTPUT_DIR=<repo>/dist/connection-recovery DROIDBRIDGE_COMPANION_APK=<repo>/dist/DroidBridge.app/Contents/Resources/Companion/DroidBridgeCompanion.apk ADB_PATH=<repo>/.build/adb-runtime/adb scripts/package.sh
ditto <repo>/dist/connection-recovery/DroidBridge.app <external-artifact-path>
codesign --verify --deep --strict --verbose=2 <external-artifact-path>
python3 scripts/verify-recovery-installed.py <external-artifact-path> --output verification/recovery-hardening-2026-11-07/installed
git diff --check
adb -s emulator-5580 emu avd name
adb -s emulator-5580 emu kill
```

Fixture scripts record their compile and runtime commands. Android fault injection targets a receipt-verified exact `app_process` PID/scid or the exact supervised fallback client. Transport tests use serial-scoped reconnect; the pinned ADB source's `format_host_command` emits `host-serial:emulator-5580:reconnect`. No shared-server restart or unscoped device actuation is used.

The existing test-app signing key was no longer present after prior cleanup, so updating the old deterministic package failed signature matching. A separate `dev.droidbridge.testapp7` fixture was installed instead; existing Android app data was not cleared.

## Retained failed attempts

- `unit-tests-attempt-1.log`: 28 assertions exposed sleep probing before the existing SDK rejection gate. The implementation was corrected to validate the SDK first. Full and focused suites subsequently pass.
- `fixture-attempt-1`: Android's shell parent also contains the server arguments; PID selection was tightened to the exact `app_process` executable before any fault injection.
- `fixture-attempt-2`: an overly strict one-receipt assumption exposed duplicate supervisor/GUI cleanup contention. Cleanup now verifies absence after a concurrent removal, and fault injection uses the session's exact logged resource identity. Final online cleanup leaves no receipts.
- `fixture-attempt-3`: requesting sleep while an active virtual display keeps the system awake was an invalid test precondition. The interruption/sleep scenario now ends the failed virtual display before sleeping, matching the incident. An additional independent panel-off test verifies healthy screen-off behavior is preserved.
- `installed-run-attempt-1.log`: verifier failed on an empty `forward --list` line after the native runtime checks had completed; parser corrected.
- `installed-run-attempt-2.log`: verifier sampled Android cleanup before its asynchronous shell teardown completed. Final verifier retains bounded cleanup snapshots and requires all servers/displays/forwards to disappear; native and fallback both pass. No permanent leak was observed.

## Remaining owner checks

Physical Pixel 10 Pro / Android 17 USB, sleep/wake and sustained-use acceptance remains owner-deferred as required by AGENTS.md. This implementation repairs software recovery; it does not establish whether the incident's USB link-change interrupts came from a cable, port, accessory or device/host USB behavior. Recovering a virtual display recreates its Android task; unsaved application state is governed by Android/the app and is not replayed by DroidBridge.

No online trial/backend service, recurring cost, push, public upload, Developer ID signing or notarization was introduced.
