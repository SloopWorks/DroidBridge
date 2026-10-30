# Android and macOS compatibility

The pinned transport is scrcpy **5.0.1** (client and server must match). The native backend speaks its private, version-specific protocol; upgrading requires protocol review and real-device regression tests. The fallback uses its public CLI.

## Verified environment

- Apple Silicon macOS host, Swift/AppKit; exact host/build versions are in verification/environment/.
- Dedicated AVD `DroidBridge_API35`, serial `emulator-5580`, Android 15 / API35 AOSP arm64-v8a image; configuration in `verification/android/avd-config.ini`.
- Dedicated AVD `DroidBridge_API37`, serial `emulator-5582`, Android 17 / API37 arm64 image: actual native Settings video/resize/cleanup smoke and launcher-icon extraction passed. This is narrower coverage than the API35 full suite; see `verification/launcher-fix/`.
- Three concurrent scrcpy virtual displays: Settings (`com.android.settings`), WebView Shell browser (`org.chromium.webview_shell`), and DroidBridge Test (`dev.droidbridge.testapp`). Logs and MP4 streams under `verification/android` establish display creation and actual frames.
- The pre-existing user emulator `emulator-5554` was never stopped or reset. An initial launcher check opened and closed Settings on a separate virtual display there; subsequent integration and QA use only the dedicated emulator. Operations always use an explicit serial.

DroidBridge requires Android 13/API33 or later. Although Android 10 introduced virtual displays, Android 10/11 lack hidden-IME policy, while the pinned scrcpy runtime does not request trusted virtual displays on Android 12/12L. These versions are refused before session staging. An unreadable Android API level also fails closed. Feature detection inspects the actual installed CLI for `--new-display` and `--flex-display`, and Android API level. A successful capability query is a preflight signal; only a successful launch proves a given device/app combination.

## Platform constraints

Apps execute on Android. No root, system-image modification, capture upload, or translation is used. USB debugging and host authorization are required. Secure/DRM video can be blank; work policy may deny input/capture. An app can refuse secondary displays, enforce portrait/minimum bounds, or require features absent on an emulator. Android `singleTask` and task-affinity behavior can move an existing instance between displays; opening the same package in several sessions is not guaranteed to produce separate instances.

The native input path uses scrcpy SDK input injection rather than UHID/AOA. Android's key-character map limits text injection, especially emoji/complex composition; clipboard paste is available where supported. Both backends explicitly suppress the Android software keyboard on their virtual displays with scrcpy's `hide` IME policy. Android IME composition/suggestions are unavailable; application-drawn custom keypads are app content and are unaffected. The fallback preserves scrcpy's own keyboard/clipboard/drag-and-drop behavior. Audio uses a shared device-wide client, not per-window/per-app streams; both video backends keep their own audio disabled to avoid duplicate capture. Mac routes the whole permitted output; Mac + Phone uses playback capture and apps can opt out. Calls, protected audio and vendor policy may prevent capture; no microphone source is selected as a fallback.

scrcpy 5.0.1 rejects `--window-width` and `--window-height` together with `--flex-display`; configure initial Android bounds via `--new-display=WxH/DPI` instead. Virtual displays are destroyed with their contents when sessions close. This can terminate the app's task; opening again starts a new display/task.

The optional system-decoration toggle uses scrcpy 5.0.1's virtual-display option on both backends. Actual Android 15 and 17 emulator tests cover showing/hiding navigation/taskbar surfaces, changing frames, input and resize. It does not change phone-wide navigation settings, remove app-drawn controls, force a different app layout or hide the IME. See `verification/desktop-mode/ANDROID_REVIEW.md`.

On Android 15/API35, the fallback disables mouse-hover forwarding to avoid an observed Android InputDispatcher crash when clicking across virtual-display navigation windows. Clicks, drags, scrolling and keyboard input remain enabled; other Android versions retain hover. The failure and controlled mitigation are recorded under `verification/hidden-ime/`, with the matching upstream report [scrcpy issue 5477](https://github.com/Genymobile/scrcpy/issues/5477).

## Physical Pixel 10 Pro

The owner reports DroidBridge working on Pixel 10 Pro and ChatGPT working from the main launcher, with a missing-window issue in its standalone wrapper. The matching structured log proves native decoding, but not foreground window state. The 0.1.1 wrapper presentation fix requires the focused physical retest in `verification/launcher-fix/PIXEL_RETEST.md`; this release’s automated verification operates only dedicated emulators. A Pixel's encoder, display density, thermal limits, task policy and USB transport can differ from either emulator. Emulator evidence must not be presented as physical Pixel evidence. No change to the Pixel's desktop-mode or root settings is required.

See `verification/REPORT.md` and independent QA evidence for the final backend-specific acceptance status.

## Phone screen off

Physical screen controls require Android 15/API35 or newer and advertised shell display-power commands. Android 17 removes `power-on`; DroidBridge detects `power-reset` and display-scoped `cmd power wakeup --display-id 0` instead of assuming API level alone defines syntax. Stock Android15 help omits its functioning legacy power commands; only that observed API35 compatibility path uses the known legacy syntax, with strict command and actual state verification. Actual main display state must be verified. Both backends select hidden IME policy, avoiding a software keyboard inside Mac windows and the physical-display fallback that prevented Android17 typing with the panel off. Native and fallback virtual displays use scrcpy5.0.1 keep-active/no-power-on behavior without changing global stay-awake or timeout settings. Turning the main panel off is separate from locking the device; Android authentication, enterprise policy and capture restrictions still apply. Physical Pixel behavior remains an owner verification stage.


## Companion upgrade boundary

The0.2 companion broker, dashboard and canonical USB/Wi-Fi capture leases apply
to updated0.2 launcher/wrapper/audio hosts. Before installing or pairing, quit
older DroidBridge main apps and copied wrappers, then open the updated host and
allow managed wrapper maintenance to finish. Running wrappers are preserved and
wait for a later retry. Independently created manual wrappers need Create / Update
Mac App again before using companion controls.

Older hosts lack the companion registry and canonical alias lease protocol.
Their independent Android debugging sessions are not implicitly stopped by
forgetting companion trust, and mixing old capture hosts with the new cohort
has no cross-version duplicate-capture guarantee. Do not switch USB/Wi-Fi while
an old host is still running. The new cohort's two-alias/audio/crash fences are
separately verified; they do not establish interoperability with an unmodified
older executable. Android debugging authorization remains separate from
companion trust and must be revoked separately when removing that access.
