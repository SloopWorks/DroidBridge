# Android platform evidence

Executed 2026-10-27 on dedicated emulator-5580 (API35 Android15 AOSP arm64, Pixel7 profile). No commands targeted the user's emulator-5554. `avd-config.ini` records the dedicated configuration. `emulator.log` has Android Emulator's own noisy unscoped internal timeout-setting attempts (it refuses these because two emulators exist); DroidBridge commands always specify the serial.

Reproduce: start `scripts/android-emulator.sh`, wait for ADB boot completion, run `scripts/android-build-testapp.sh`, then `scripts/android-verify.py`.

`core-result.json`, per-process command JSON and `backend-a-{0,1,2}.log` establish three simultaneous virtual displays (IDs5/6/7 during the last run). `concurrent-tasks.txt` and `concurrent-displays.txt` are actual Android dumps while all processes ran. The applications were Settings, WebView Shell browser, and the purpose-built test app. `backend-a-*.mp4` are captured scrcpy encoded streams, not synthetic images. `concurrent-streams-contact-sheet.png` combines decoded frame snapshots from those three recordings at 1 second (normalized to720×1080 for the contact sheet); it is a contact sheet, **not a macOS desktop screenshot**.

`probe-input.log` independently records Android-side button click and the full injected word on display7. This smoke test injects display-scoped ADB input to isolate Android functionality. It does **not** prove macOS keyboard/focus or scrcpy-control injection; those require the separate backend/GUI tests. Probe coordinates for720x1080/240dpi are button center(300,225), text field(260,295).

`display-resize.txt` records Android's independent display resize from720x1080 to900x1200 while two other displays remained active. The final scrcpy log reports both frame dimensions. This uses `wm size -d`; backend-driven resize must be verified separately.

`after-stop-displays.txt` has only display0 and `after-stop-forwards.txt` is empty: all three test process sessions cleaned up their displays and forwards. The dedicated emulator intentionally remains running for integrated QA.

`swift-discovery-tests.log`: six tests, zero failures, one live-test skip because environment flag was absent. Later live test attempted while other agents edited shared InputGeometry and failed compilation there; the lead reruns the exact integrated candidate.

`host-screenshot-black-unusable.png` is a captured but entirely black host screen and must **not** count as GUI screenshot evidence. The live MP4 decoded snapshots establish Android pixels only. Initial command attempt failed correctly because scrcpy5.0.1 rejects `--window-width/--window-height` with `--flex-display`; the rerun omits these flags.

Physical Pixel10Pro remains untested. See COMPATIBILITY.md and PIXEL_VERIFICATION.md.
