# Android desktop display implementation and verification

Executed 2026-10-28 on dedicated AVDs: Android 15/API35 (`emulator-5580`) and Android 17/API37 (`emulator-5582`). No physical Pixel was attached or touched. Existing emulator-5554 was neither stopped nor controlled.

## Implementation

`SessionConfiguration.showSystemDecorations` defaults to true. Old saved configurations decode their missing field as true; changing the launcher preference does not reinterpret saved descriptors. The external backend adds `--no-vd-system-decorations` only for false. The native backend supplies exact pinned scrcpy 5.0.1 server option `vd_system_decorations=true/false`.

The installed 5.0.1 `--help`, upstream `doc/virtual-display.md`, client server argument builder and server `NewDisplayCapture.java` confirm the option. The Android flag is applied to this newly created virtual display only. It removes the platform's navigation/taskbar and default virtual launcher UI. It cannot remove controls drawn by the Android app itself, remove its action bar, force a different multi-window layout, or hide the IME through this option. With decorations disabled and no Android app running, the display may produce no frames; DroidBridge explicitly launches a package. Closing an app can therefore leave a blank surface until another app is launched or the session closes.

No root, phone-wide immersive setting, policy override, system image change, or force-stop was used. The phone's main display configuration is not changed.

## Evidence

`api35/` and `api37/` contain actual decoded frames, dumpsys display/window facts, input logcat receipts and session logs. These are video frames from live Android sessions, not mockups. Test sources are retained here for independent reproduction.

- Native API35 final lead rerun: both flags passed live video, mouse/text, secondary activity, actual Back return without a Return-button fallback, 896×640 resize and post-resize click, Settings capture and exact selected-device forward/display cleanup. The final reports record 127/115 decoded frames and 123/113 distinct frame hashes. `../onboarding/final-desktop-native35.log` records the completed run.
- Native API37 final: both flags passed mouse/text, actual Back return, secondary activity, 896×640 resize, post-resize click, Settings and exact selected-device cleanup. The final reports record 140/119 decoded frames and 126/110 distinct frame hashes. No Return-button fallback was needed.
- External client: real unmodified scrcpy 5.0.1, both flags on both Android releases, actual H.264 recordings. Public SDL main-thread mouse/text/key events reached Android. A fixed initial window geometry isolates coordinate routing; a separate `--flex-display` pass uses public SDL_SetWindowSize and recorded frames change from 720×1080 to 448×320 on both releases and both flag choices. See `adaptive-recording-evidence.json`.
- API37 external final report records 155/201 frames and full cleanup. The final lead API35 rerun with selected-serial cleanup passed 286/262 recorded frames, mouse/text, both decoration choices, flexible resize from 720×1080 to 448×320 and exact forward/reverse/display cleanup. See `../onboarding/final-desktop-external35.log` and `api35/external-results.json`. An earlier adaptive run had compared *all devices'* ADB forwards and falsely failed when an independent API37 session changed its own forward; the retained `external35-run.log` is historical failed-harness evidence, superseded by the final selected-device run.

The API35 decorated display has FLAG_SHOULD_SHOW_SYSTEM_DECORATIONS and NavigationBar with bottom bounds `[0,1008][720,1080]`; disabling it removes that flag and the virtual navigation window/inset. The decoded blue probe content then fills the full 1080 pixels. API37 decorated frames visibly contain status/taskbar UI; desktop frames remove it, including in real Settings. The app's own EditText underline/buttons remain as expected.

## Harness findings and limits

Early fixed-delay native Back checks were premature relative to Android activity/frame updates; the first raw-key experiment also overlapped a second client using the same package and was invalid because Android task affinity can move/reuse a task across displays. Those failures were not accepted as product evidence. Final API37 tests run one harness at a time and wait for actual secondary/Main frame content. Both normal `.back` operations then passed, so no speculative Back protocol change was made.

Initial SDL input with flex geometry had a coordinate-fixture failure (counter click but no typing). Fixed geometry reuses the previously qualified public SDL fixture; flex resize is measured separately using only a window resize event. This distinguishes Android capability from test-coordinate assumptions. SDL fixture events prove client event handling, not physical OS keyboard/focus or Cmd+Tab behavior under a locked desktop.

The task's final integrated GUI, automatic onboarding and packaged artifact remain owned by the lead/macOS/systems workers and independent QA. These component observations alone do not claim the complete new application release passed.

## Reproduce

Build the existing probe for each dedicated serial with `DROIDBRIDGE_TEST_SERIAL=emulator-5580 scripts/android-build-testapp.sh`. Then run `DROIDBRIDGE_TEST_SERIAL=emulator-5580 verification/desktop-mode/run-native.sh` and `DROIDBRIDGE_TEST_SERIAL=emulator-5580 verification/desktop-mode/run-external.sh` **sequentially**. Substitute emulator-5582 for API37. The external helper is test-only; no application protocol or capture implementation is substituted. Do not run two harnesses with the same package on the same device concurrently.

Primary sources:

- https://github.com/Genymobile/scrcpy/blob/v5.0.1/doc/virtual-display.md
- Local pinned `Vendor/scrcpy/app/src/server.c` and `server/src/main/java/com/genymobile/scrcpy/video/NewDisplayCapture.java`
- https://developer.android.com/reference/android/hardware/display/DisplayManager

## Bulk onboarding Android expert review

Use `(device serial, package name)` as the durable application identity. Labels are neither unique nor stable, and an application label can differ from a launcher alias label. The existing icon helper resolves the actual launcher alias/resource through Android, rather than host APK guesses.

Only authorized state `device` admits work; `offline`, `unauthorized`, recovery or bootloader are visible availability facts. Boot completion and package-service readiness must precede package discovery and launch. Device disappearance or a package/icon extraction failure must not erase accepted wrappers or silently rebind them to a different device. An uninstalled package and an unavailable device are different states.

scrcpy list-apps enumerates enabled applications with a launch intent. It supplies package-level application names, and package identity remains canonical if Android offers multiple launcher activities. Keep icon extraction bounded using the existing admission/cleanup provider; an all-app operation must not launch one process per app simultaneously. Report per-app failures and support later retry. A wrapper copies a large runtime, so whole-device onboarding should retain its capacity reserve/cancellation and use safe copy-on-write cloning where available. Never use a launch probe or force-stop to determine availability: package and boot queries suffice.
