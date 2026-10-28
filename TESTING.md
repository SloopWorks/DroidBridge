# Testing DroidBridge

Use the dedicated `DroidBridge_API35` emulator on port 5580. The user's existing emulator-5554 is outside the test boundary and must never be stopped or reset. Physical Pixel 10 Pro acceptance is the only manual device stage; see PIXEL_VERIFICATION.md.

## Reproduce

```sh
scripts/android-emulator.sh # run in a separate persistent terminal; foreground emulator supervisor
scripts/android-build-testapp.sh
swift test
DROIDBRIDGE_INTEGRATION=1 DROIDBRIDGE_TEST_SERIAL=emulator-5580 swift test --filter StreamingTests
DROIDBRIDGE_QA_LIFECYCLE=1 DROIDBRIDGE_TEST_SERIAL=emulator-5580 swift test --filter QALifecycleTests
scripts/verify-appkit.sh
python3 scripts/verify-package.py "$HOME/Applications/DroidBridge.app"
python3 scripts/verify-installed.py "$HOME/Applications/DroidBridge.app" # exclusive DroidBridge GUI/emulator sessions
```

Run emulator-dependent tests serially. Probe apps have single Android package identities; simultaneous independent test runners launching the same package can move the task to a different display. Close GUI probe sessions before running integration tests. Lifecycle tests compare forward/display baseline snapshots and therefore require exclusive ownership of DroidBridge sessions on the dedicated emulator, while retaining unrelated baseline sessions. Never globally remove ADB forwards or kill the ADB server.

`scripts/android-verify.py` verifies the actual scrcpy virtual-display path and stores Android display/task/input evidence. Read its command-line help before invoking it. `StreamingTests` verifies scrcpy's pinned binary protocol, actual VideoToolbox frame decode, changing pixels, input receipts, concurrent displays, resize and forward cleanup. Default `swift test` explicitly skips hardware-dependent tests; a green unit suite alone does not certify streaming.

`QALifecycleTests` adds invalid package/serial/display admission, nonexistent application refusal, cancellation during startup, repeated decoded start/stop cycles, terminal state checks, owned forward cleanup and virtual-display count restoration. An isolated delayed-forward regression checks cleanup admitted after shutdown begins; SessionRecoveryTests checks exact cleanup ownership and offline retry receipts. `scripts/verify-supervisor.py` independently kills a real helper parent and verifies exact child/cleanup behavior.

`scripts/verify-appkit.sh` compiles the shipping `NativeWindow.swift` against the current core/streaming objects, creates two actual AppKit NSWindows, renders decoded Android frames through the shipping NSView, dispatches mouse and keyboard NSEvents through NSWindow, checks Android log receipts, resizes and repeats input. It captures rendered NSView bitmap PNGs without requiring screen-recording permission. This harness complements GUI launcher automation; it does not substitute for selecting apps and backend controls in the installed launcher.

`scripts/verify-package.py` validates deep/strict ad-hoc signatures, arm64 Mach-O dependency paths and bundled runtime executables with PATH limited to system tools. Ad-hoc signature validity is not Developer ID trust or notarization. Separately launch the copied application outside `dist` and verify GUI sessions using its bundled runtime; capture screenshots and exact installation path.

## Evidence policy

See verification/REPORT.md for the acceptance matrix, verification/review/ for independent results, verification/android/ for emulator evidence and verification/streaming/ for decoded-frame and input receipts. A screenshot is accepted only when it visibly contains real application content. Black screen-capture images are failed evidence and must be replaced with permitted UI screenshots or actual AppKit view captures. Input pass claims require Android receipts tied to the intended display; ADB-injected input alone does not prove Mac window event routing.

A release must rerun the unit and actual integration tests after code changes, rebuild the package, verify its exact bundle, mount/copy the installer outside the build directory, and launch that installed copy. Record blocked/unexecuted scenarios explicitly. Cmd+Tab and Spotlight behavior must be observed; independent bundle IDs alone are insufficient evidence.
