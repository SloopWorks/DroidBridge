# Testing DroidBridge

Use the dedicated `DroidBridge_API35` emulator on port 5580. The user's existing emulator-5554 is outside the test boundary and must never be stopped or reset. Physical Pixel 10 Pro acceptance is the only manual device stage; see PIXEL_VERIFICATION.md.

## Reproduce

```sh
scripts/android-emulator.sh # run in a separate persistent terminal; foreground emulator supervisor
scripts/android-build-testapp.sh
scripts/build-icon-helper.sh
android/icon-helper/fixture/build.sh
swift test
scripts/verify-wrapper-failure.sh # no-device shipping launcher/video fixture, failure retention and presentation
DROIDBRIDGE_TEST_ICONS=1 DROIDBRIDGE_TEST_SERIAL=emulator-5580 swift test --filter AndroidIconProviderTests
DROIDBRIDGE_TEST_HOST="$HOME/Applications/DroidBridge.app" scripts/test-macos-wrappers.sh # actual creator, live signed wrappers, Android icons and update safety
scripts/verify-launch-race.sh # deterministic no-device startup cancellation race
DROIDBRIDGE_INTEGRATION=1 DROIDBRIDGE_TEST_SERIAL=emulator-5580 swift test --filter StreamingTests
DROIDBRIDGE_QA_LIFECYCLE=1 DROIDBRIDGE_TEST_SERIAL=emulator-5580 swift test --filter QALifecycleTests
scripts/verify-appkit.sh
python3 scripts/verify-sdl-input.py "$HOME/Applications/DroidBridge.app" # test-only client events; no locked-host OS-focus claim
python3 scripts/verify-package.py "$HOME/Applications/DroidBridge.app"
python3 scripts/verify-installed.py "$HOME/Applications/DroidBridge.app" # exclusive DroidBridge GUI/emulator sessions
python3 scripts/verify-wrapper-close.py "$HOME/Applications/DroidBridge.app"
python3 scripts/verify-reconnect.py "$HOME/Applications/DroidBridge.app" # restarts only DroidBridge_API35/5580
```

Run emulator-dependent tests serially. Probe apps have single Android package identities; simultaneous independent test runners launching the same package can move the task to a different display. Close GUI probe sessions before running integration tests. Lifecycle tests compare forward/display baseline snapshots and therefore require exclusive ownership of DroidBridge sessions on the dedicated emulator, while retaining unrelated baseline sessions. Never globally remove ADB forwards or kill the ADB server.

`scripts/android-verify.py` verifies the actual scrcpy virtual-display path and stores Android display/task/input evidence. Read its command-line help before invoking it. `StreamingTests` verifies scrcpy's pinned binary protocol, actual VideoToolbox frame decode, changing pixels, input receipts, concurrent displays, resize and forward cleanup. Default `swift test` explicitly skips hardware-dependent tests; a green unit suite alone does not certify streaming.

`QALifecycleTests` adds invalid package/serial/display admission, nonexistent application refusal, cancellation during startup, repeated decoded start/stop cycles, terminal state checks, owned forward cleanup and virtual-display count restoration. An isolated delayed-forward regression checks cleanup admitted after shutdown begins; SessionRecoveryTests checks exact cleanup ownership and offline retry receipts. `scripts/verify-supervisor.py` independently kills a real helper parent and verifies exact child/cleanup behavior.

`scripts/verify-appkit.sh` compiles the shipping `NativeWindow.swift` against the current core/streaming objects, creates two actual AppKit NSWindows, renders decoded Android frames through the shipping NSView, dispatches mouse and keyboard NSEvents through NSWindow, checks Android log receipts, resizes and repeats input. It captures rendered NSView bitmap PNGs without requiring screen-recording permission. This harness complements GUI launcher automation; it does not substitute for selecting apps and backend controls in the installed launcher.

`scripts/verify-package.py` validates deep/strict ad-hoc signatures, arm64 Mach-O dependency paths and bundled runtime executables with PATH limited to system tools. Ad-hoc signature validity is not Developer ID trust or notarization. Separately launch the copied application outside `dist` and verify GUI sessions using its bundled runtime; capture screenshots and exact installation path. `verify-installed.py` starts live sessions with isolated PATH and tests SIGKILL of the host, graceful AppKit termination, and exact supervised-child failure for both backends; it checks process, ADB forward/reverse, and virtual-display cleanup and records CPU/RSS samples. `verify-wrapper-close.py` copies the installed Mach-O into a QA wrapper and injects a test-only public-API NSWindow close action, then requires live decoded video, normal app exit and cleanup. `verify-reconnect.py` shuts down and boots only the dedicated AVD, checks that the same host PID survives six seconds without the device, and requires a new running session after reconnection for each backend.

## Evidence policy

See verification/REPORT.md for the acceptance matrix, verification/review/ for independent results, verification/android/ for emulator evidence and verification/streaming/ for decoded-frame and input receipts. A screenshot is accepted only when it visibly contains real application content. Black screen-capture images are failed evidence and must be replaced with permitted UI screenshots or actual AppKit view captures. Input pass claims require Android receipts tied to the intended display; ADB-injected input alone does not prove Mac window event routing.

A release must rerun the unit and actual integration tests after code changes, rebuild the package, verify its exact bundle, mount/copy the installer outside the build directory, and launch that installed copy. Record blocked/unexecuted scenarios explicitly. Cmd+Tab and Spotlight behavior must be observed; independent bundle IDs alone are insufficient evidence.

## Device app onboarding and display decorations

See [the onboarding report](verification/onboarding/REPORT.md) and [Android display review](verification/desktop-mode/ANDROID_REVIEW.md). `scripts/verify-managed-apps.sh` exercises the shipping factory, signatures, actual Spotlight friendly-name/index queries, noindex transitions, per-device identities, cross-process contention and measured COW copies. Its 1000-record benchmark is synthetic catalog metadata, not a claim that 1000 real Android apps were installed or indexed.

`scripts/verify-device-onboarding.sh` exercises the shipping bounded coordinator against the entire real dedicated-emulator catalog, including Android icon extraction and current-record resume. It installs the real per-user helper, so coordinate exclusive ownership and preserve prior shared preferences/catalog state. Tests must distinguish the harness process exiting from main GUI and wrapper lifetime checks.

Run `verification/desktop-mode/run-native.sh` and `run-external.sh` sequentially with `DROIDBRIDGE_TEST_SERIAL=emulator-5580` or the dedicated API37 serial `emulator-5582`. They verify both decoration values, actual changing frames, Android input, activity transitions, resize and exact selected-device cleanup. Never overlap clients using the same Android package on one device: task affinity can move a task and invalidate input/frame results. Wait for observed frame/input conditions rather than treating a fixed delay as evidence of navigation failure.

The focused launch-race harness compiles the shipping launcher and delays a fake ADB resolve command, then checks that polling interruption survives the late startup catch. It complements actual emulator reboot tests. The SDL test injects only public client events into two unchanged bundled Players, validates separate Android mouse/text/raw-key receipts, inspects real recorded frames, and verifies cleanup; it does not establish OS focus under a locked desktop.

The 0.1.1 wrapper report is [verification/launcher-fix/REPORT.md](verification/launcher-fix/REPORT.md). `verify-wrapper-failure.sh` compiles the shipping launcher and uses bounded fake transports, including a real VideoToolbox-decoded H.264 frame. It verifies retained clean exits before/after running, precise error preservation, replacement-session quit-timer fencing, bounded/drained icon work, native window restoration at first frame, and reopening without duplicate sessions. It complements actual Android tests and is not a ChatGPT package test.

`test-macos-wrappers.sh` uses the actual creator and installed runtime on dedicated emulator-5580. It checks PNG/ICNS content, atomic updates and backups, unrelated/destination-race refusal, live native video and fallback Texture/display binding, and separate regular native/Player application identities. ICNS pixels are compared with Android's source bitmap; running icons are compared with macOS's presented bundle icon, which may add a platform container. The generated code must match the installed executable after removing only signatures from temporary comparison copies; signatures differ because they seal distinct bundles. Direct Cmd+Tab interaction remains a separate unlocked-desktop check.

## Clean managed app names

`swift test --filter ManagedAppsTests.testNaming` checks collision reservations, Unicode/case behavior, foreign paths, two-phase compatibility and late Launch Services effects. The installed-app migration and actual Spotlight evidence are recorded under `verification/clean-app-names/`. A metadata name assertion does not establish a running copied executable; acceptance must launch a final clean-name wrapper with the current executable and receive a real frame.

## Physical phone screen control

`swift test --filter PhoneDisplayPower` covers parser certainty, command capability changes, latest-intent races, per-device mutexes and preferences. Real Android15/17 streams, input, display-state evidence and final installed GUI checks live under `verification/screen-off/`. Test primary display0OFF separately from virtual-display liveness; command exit0 and window existence alone are insufficient. Preserve user emulator5554 and all unrelated devices.

## Launch presentation

`scripts/verify-launch-ux.sh` verifies immediate branded loading, prior geometry, same-window frame handoff, input gating, close cancellation and reopen using shipping UI and an actual decoded fixture frame. `verification/launch-ux/` separately records actual emulator and exact installed-bundle loading-to-video evidence. Public AppKit instrumentation under a locked desktop does not prove an interactive Spotlight/Dock click or OS focus. Android splash pixels are app-controlled; DroidBridge manufactures only the local loading screen from the saved Android launcher icon.
