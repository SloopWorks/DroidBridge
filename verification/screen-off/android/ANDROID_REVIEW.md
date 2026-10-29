# Android screen-off review

Result: physical display OFF with two live, interactive virtual displays is demonstrated. API 37 required a per-virtual-display LOCAL IME policy; its default IME fallback to physical display 0 caused missing keyboard input. See the controlled failure/success/failure evidence below.

Scope: dedicated Android 15/API 35 (`emulator-5580`) and Android 17/API 37 (`emulator-5582`) AVDs; pinned scrcpy 5.0.1. The user's emulator 5554 and physical Pixel were not operated. The final physical Pixel acceptance remains separate.

## Mechanism and policy

Every app session is an Android virtual display. scrcpy 5.0.1's `keep_active` server option periodically reports user activity to that session's display (4-second interval), without changing Android's global stay-awake or screen-timeout settings. `power_on=false` avoids startup waking the phone. The equivalent supported client switches are `--keep-active --no-power-on`.

Turn off only the verified INTERNAL physical display 0 using public shell `cmd display power-off 0`. This blanks the panel; it is not an Android lock request. The virtual displays remain ON and continue rendering and accepting input. A user lock, administrator policy, secure content, OEM restrictions, app-specific display restrictions, and a locked device before connection are separate conditions.

Do not use scrcpy `--turn-screen-off` as the shared policy: each independently owned server registers cleanup that restores the main display, so closing one wrapper could wake the phone while another wrapper remains. Instead, persist explicit per-device intent in DroidBridge, serialize device power operations across processes, and check fresh intent around asynchronous commands. Session termination must not implicitly request screen ON. A user's explicit Screen On clears OFF intent. A later explicit phone interaction may wake it; reconciliation may apply the still-enabled OFF intent again.

## Version differences verified on actual AVDs

| Android | OFF | Explicit ON | Help status |
|---|---|---|---|
| API 35 | `cmd display power-off 0` | `cmd display power-on 0` | display/power help both exit 255 with complete documented help |
| API 37 | `cmd display power-off 0` | `cmd display power-reset 0`, then `cmd power wakeup --display-id 0` if still OFF | display/power help both exit 255 with complete documented help |

API 37 does not advertise `power-on`. `power-reset` clears the override and restores normal policy; it does not wake an already asleep display group. `asleep-on-command-results.json` and settled power/display snapshots show that reset remains OFF/Asleep, followed by public wakeup reaching ON/Awake. A test-only `cmd power sleep --display-id 0` arranged that case. No global settings were changed. The API 35 help omits its implemented power-on and power-off handlers, so help alone cannot establish those legacy capabilities. A bounded no-ID handler probe can recognize the exact missing-display-ID error without actuation; unsupported commands must fail closed. API 37 advertises reset/off and public wakeup. Successful actuation is always followed by physical-state verification. Help exit 255 is acceptable only for a positively recognized help response, never for actuation.

The Core control design was reviewed against these observed commands and fixtures: validate the serial/device, require API 35+, positively identify INTERNAL display 0, fence explicit intent with per-device file locking, verify final state, and use reset plus public wakeup on Android 17. The integration lead is validating its API 35 no-help legacy path separately. It does not issue a POWER toggle, require root, modify phone settings, or stop app sessions on a control failure.

## Reproduction and evidence interpretation

`VerifyScreenOff.swift` launches two real native sessions using production `BridgeSession` and real ADB, hashes decoded CGImage bytes, waits 12 seconds without input while display 0 is OFF, sends clicks/text to each app, resizes one stream, closes one session while the other keeps updating, and checks scoped resource cleanup and unchanged settings. It captures actual server process command lines to verify production `keep_active=true power_on=false`. The test restores its original ON baseline explicitly after all assertions; that restoration is test cleanup, not product close behavior.

`verify-external-screen-off.py` runs two unmodified scrcpy clients and records their streams. `screen-off-sdl.c` is a test-only public SDL event queue fixture on each client's main thread. It validates client mouse/text/raw-key paths under the currently locked Mac desktop; it cannot establish physical Mac keyboard delivery or OS window focus. Decoded recordings, frame timestamps, distinct frame hashes, Android-side input receipts, display snapshots, and per-client command logs distinguish live rendering from an empty window or repeated static screenshot.

Early native feasibility used `adb-keep-active.py` solely to inject the options before the production flag change. Those early logs are historical experiments. Final native JSON includes `usesUnmodifiedProductionADB=true`; rely on that result and `native-production-server-processes.txt` for the production claim. Source/current implementation, not historical evidence, defines behavior.

Twelve seconds covers three keep-active intervals. This is not a prolonged battery/thermal soak or a physical Pixel result.

## Independent upstream fallback startup finding

Two simultaneous CLI launches using scrcpy's default reverse tunnel port exposed a real upstream startup race: one server's log started the other package while its peer never reached a package-specific startup line. Exact logs are preserved under `reverse-start-race/`. The scrcpy 5.0.1 tunnel establishes reverse forwarding before binding its local listening port. A unique server socket identifier alone does not prevent a concurrent same-local-port collision window. The integration lead implemented cross-process per-session port leases and explicit client `--port` selection; its concurrent production-backend verification is separate from this report's serialized CLI fixture. Blindly forcing ADB forwarding does not protect against rebinding because the pinned client's forward command does not use `--no-rebind`.

The external feasibility harness starts each client sequentially through the exact expected package's startup receipt before launching the next. Both apps then run concurrently throughout the OFF test. This avoids conflating this independent upstream startup issue with the panel power mechanism.

## Primary references

- [scrcpy 5.0.1 device documentation](https://github.com/Genymobile/scrcpy/blob/v5.0.1/doc/device.md)
- [Pinned Controller implementation](https://github.com/Genymobile/scrcpy/blob/v5.0.1/server/src/main/java/com/genymobile/scrcpy/control/Controller.java)
- [Pinned Device implementation](https://github.com/Genymobile/scrcpy/blob/v5.0.1/server/src/main/java/com/genymobile/scrcpy/device/Device.java)
- [Android 15 display shell commands](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/android15-release/services/core/java/com/android/server/display/DisplayManagerShellCommand.java)
- [Current Android display shell commands](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/services/core/java/com/android/server/display/DisplayManagerShellCommand.java)
- [Current Android power shell commands](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/services/core/java/com/android/server/power/PowerManagerShellCommand.java)

AOSP `main` is a moving reference; the captured API 37 emulator help and actual command/state receipts are the version-specific executable evidence.

## Android 17 IME root cause and controlled fix

The pinned virtual-display documentation states that IME defaults to the default/physical display. On API 37, both native production controls and public `adb shell input -d <virtual display> text ...` could produce no text even while the correct EditText was focused. Dumps showed input dispatch enabled and unfrozen, an unlocked device, the correct focused application/display and served EditText, but the IME selected display 0. A panel-ON control also reproduced the failure, so it was not exclusive to OFF actuation. Rebooting the dedicated AVD did not resolve it.

The test changed one supported, per-virtual-display option: `--display-ime-policy=local`. Both apps then accepted mouse, SDL text, and raw keys after display 0 was OFF for 12 seconds. The recording visibly shows the soft keyboard in the correct virtual display and each app's distinct typed word. Switching back to the otherwise identical default-fallback command reproduced missing text. This failure → LOCAL success → fallback failure sequence isolates IME placement policy as the actionable cause. It does not claim to identify the internal Android/Gboard defect that drops those default-fallback events.

The production fix uses `--display-ime-policy=local` for Backend A and `display_ime_policy=local` for Backend B. This scopes the change to each owned virtual display, with no global IME changes, phone settings changes, or root. The soft keyboard may consequently appear inside the app's Mac window; hiding system decorations does not imply hiding IME.

| Evidence | Outcome | Receipts |
|---|---|---|
| API 37 default fallback, physical panel OFF | Fail: keyboard absent despite mouse click | `api37/external-failed-*`, `native-api37-run.log` |
| API 37 default fallback, physical panel ON | Same failure | `api37-control-panel-on/` |
| API 37 fresh-boot native default fallback + direct ADB diagnostic | Same failure | `api37-clean-boot/`, `native-api37-clean-boot.log` |
| API 37 external LOCAL, physical panel OFF | Pass: two mapped words/raw keys, live changing frames, independent close, resource cleanup | `api37-local-ime/external-results.json`, `external-input.log`, `external-1-input.png` |
| API 37 fallback repeated after LOCAL | Missing text reproduced | `api37-postlocal-fallback/`, `external-api37-postlocal-fallback.log` |
| API 37 actual production native LOCAL, physical panel OFF | Pass: two mapped words/clicks, resize, independent close, cleanup | `api37-production-local-ime/native-results.json`, `native-production-server-processes.txt`, input/PNG files |
| API 35 actual production native LOCAL, physical panel OFF | Pass: two mapped words/clicks, resize, independent close, cleanup | `api35-production-local-ime/native-results.json`, process/input/PNG files |
| API 35 external LOCAL, physical panel OFF | Pass: two mapped words/raw keys, live changing frames, independent close, cleanup | `api35-local-ime-clock-corrected/external-results.json`, input/PNG files |

API 35's final production native LOCAL run received 193/214 decoded frames and 191/214 distinct frame hashes after OFF, with distinct Android displays 11/12, mapped clicks/text, resize to 896×640, independent close, unchanged settings and scoped cleanup.

API 37's production native run received 194/237 decoded frames and 133/225 distinct full-frame hashes while physical display 0 was OFF. It resized the first stream to 896×640, closed it while the second kept updating, and observed OFF after both sessions closed; only explicit test cleanup restored ON. API 37's external LOCAL recordings contain 353/371 frames after OFF and 254/365 distinct frame hashes, with both session-specific typed words and raw `k` keys. The physical display and virtual-display states are saved alongside each result. No API 37 keyboard pass is inferred from merely enqueueing events.

The final API 35 external LOCAL run received 355/375 frames after OFF and 349/369 distinct frame hashes. Its second recording progressed from PTS 24.371 at first-client close to PTS 27.572 after that close. An earlier assertion incorrectly compared second-stream PTS against harness wall elapsed time; these clocks have different zero points. That failed harness log remains `external-api35-local-ime.log`; the corrected check samples and compares the same second stream's PTS at both boundaries. `api35-final-resource-check.json` independently confirms only physical display 0 remains, no selected-device forwards/reverses/scrcpy servers remain, and both exact native remote JARs are absent. The test restored its original physical ON baseline before releasing the dedicated AVD.

The legacy Android 15 no-ID probe is supported by primary AOSP source: `requestDisplayPower` returns status 1 with `Error: no displayId specified` before calling the service if the display argument is absent. The source's `onHelp` omits the power handlers even though its command switch implements them. The exact device probe and Core control results are integration-lead evidence, separate from these streaming tests.

Additional primary reference: [scrcpy 5.0.1 virtual-display and IME policy documentation](https://github.com/Genymobile/scrcpy/blob/v5.0.1/doc/virtual-display.md).

## Re-run commands (dedicated AVDs only)

Build the project first (`swift build`), then compile the native evidence harness against that same debug candidate:

```sh
swiftc -parse-as-library -I .build/arm64-apple-macosx/debug/Modules \
  verification/screen-off/android/VerifyScreenOff.swift \
  .build/arm64-apple-macosx/debug/DroidBridgeCore.build/*.o \
  .build/arm64-apple-macosx/debug/DroidBridgeStreaming.build/*.o \
  -o .build/verify-screen-off
DROIDBRIDGE_TEST_SERIAL=emulator-5580 \
DROIDBRIDGE_SCREEN_OFF_EVIDENCE="$PWD/verification/screen-off/android/api35-production-local-ime" \
  .build/verify-screen-off
```

Use emulator-5582 and a distinct evidence directory for API 37. Never run two harnesses against the same device simultaneously: Android task affinity can move a package between displays. Each device needs the two repository probe packages installed (`dev.droidbridge.testapp`, `dev.droidbridge.testapp2`). These are not phone-user applications.

Compile the public SDL fixture, then run the pinned-client evidence test:

```sh
clang -dynamiclib -Wall -Wextra -I/opt/homebrew/include -undefined dynamic_lookup \
  verification/screen-off/android/screen-off-sdl.c -o .build/screen-off-sdl.dylib
codesign --force --sign - .build/screen-off-sdl.dylib
DROIDBRIDGE_TEST_SERIAL=emulator-5582 DROIDBRIDGE_TEST_LOCAL_IME=1 \
  python3 verification/screen-off/android/verify-external-screen-off.py
```

Removing `DROIDBRIDGE_TEST_LOCAL_IME` intentionally reproduces the failed default policy; use a distinct suffix such as `DROIDBRIDGE_TEST_EVIDENCE_SUFFIX=-fallback-control` to preserve successful evidence. `DROIDBRIDGE_CONTROL_PANEL_ON=1` runs the panel-ON control. The native harness always requires all three actual production server options and cannot silently inject them through an ADB shim.
