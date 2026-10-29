# Android and macOS compatibility

The pinned transport is scrcpy **5.0.1** (client and server must match). The native backend speaks its private, version-specific protocol; upgrading requires protocol review and real-device regression tests. The fallback uses its public CLI.

## Verified environment

- Apple Silicon macOS host, Swift/AppKit; exact host/build versions are in verification/environment/.
- Dedicated AVD `DroidBridge_API35`, serial `emulator-5580`, Android 15 / API35 AOSP arm64-v8a image; configuration in `verification/android/avd-config.ini`.
- Dedicated AVD `DroidBridge_API37`, serial `emulator-5582`, Android 17 / API37 arm64 image: actual native Settings video/resize/cleanup smoke and launcher-icon extraction passed. This is narrower coverage than the API35 full suite; see `verification/launcher-fix/`.
- Three concurrent scrcpy virtual displays: Settings (`com.android.settings`), WebView Shell browser (`org.chromium.webview_shell`), and DroidBridge Test (`dev.droidbridge.testapp`). Logs and MP4 streams under `verification/android` establish display creation and actual frames.
- The pre-existing user emulator `emulator-5554` was never stopped or reset. An initial launcher check opened and closed Settings on a separate virtual display there; subsequent integration and QA use only the dedicated emulator. Operations always use an explicit serial.

Android 10/API29 or later is required for scrcpy virtual displays. Feature detection inspects the actual installed CLI for `--new-display` and `--flex-display`, and Android API level. A successful capability query is a preflight signal; only a successful launch proves a given device/app combination.

## Platform constraints

Apps execute on Android. No root, system-image modification, capture upload, or translation is used. USB debugging and host authorization are required. Secure/DRM video can be blank; work policy may deny input/capture. An app can refuse secondary displays, enforce portrait/minimum bounds, or require features absent on an emulator. Android `singleTask` and task-affinity behavior can move an existing instance between displays; opening the same package in several sessions is not guaranteed to produce separate instances.

The native input path uses scrcpy SDK input injection rather than UHID/AOA. Android's key-character map limits text injection, especially emoji/complex composition; clipboard paste is available where supported. IME display placement is Android-controlled. The fallback preserves scrcpy's own keyboard/clipboard/drag-and-drop behavior. Audio forwarding is disabled for independent sessions in this release.

scrcpy 5.0.1 rejects `--window-width` and `--window-height` together with `--flex-display`; configure initial Android bounds via `--new-display=WxH/DPI` instead. Virtual displays are destroyed with their contents when sessions close. This can terminate the app's task; opening again starts a new display/task.

The optional system-decoration toggle uses scrcpy 5.0.1's virtual-display option on both backends. Actual Android 15 and 17 emulator tests cover showing/hiding navigation/taskbar surfaces, changing frames, input and resize. It does not change phone-wide navigation settings, remove app-drawn controls, force a different app layout or hide the IME. See `verification/desktop-mode/ANDROID_REVIEW.md`.

## Physical Pixel 10 Pro

The owner reports DroidBridge working on Pixel 10 Pro and ChatGPT working from the main launcher, with a missing-window issue in its standalone wrapper. The matching structured log proves native decoding, but not foreground window state. The 0.1.1 wrapper presentation fix requires the focused physical retest in `verification/launcher-fix/PIXEL_RETEST.md`; the developer currently has no attached Pixel. A Pixel's encoder, display density, thermal limits, task policy and USB transport can differ from either emulator. Emulator evidence must not be presented as physical Pixel evidence. No change to the Pixel's desktop-mode or root settings is required.

See `verification/REPORT.md` and independent QA evidence for the final backend-specific acceptance status.

## Phone screen off

Physical screen controls require Android 15/API35 or newer and advertised shell display-power commands. Android 17 removes `power-on`; DroidBridge detects `power-reset` and display-scoped `cmd power wakeup --display-id 0` instead of assuming API level alone defines syntax. Stock Android15 help omits its functioning legacy power commands; only that observed API35 compatibility path uses the known legacy syntax, with strict command and actual state verification. Actual main display state must be verified. Both backends select local IME policy; the default physical-display fallback was experimentally isolated as the cause of Android17 typing failures. Native and fallback virtual displays use scrcpy5.0.1 keep-active/no-power-on behavior without changing global stay-awake or timeout settings. Turning the main panel off is separate from locking the device; Android authentication, enterprise policy and capture restrictions still apply. Physical Pixel behavior remains an owner verification stage.
