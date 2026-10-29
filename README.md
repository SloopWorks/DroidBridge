# DroidBridge

DroidBridge runs Android applications on Android while presenting them in separate macOS windows. The launcher discovers authorized USB ADB devices and running emulators, enumerates launchable apps, and offers two session backends:

- **Native**: scrcpy 5.0.1 server, H.264 transport, VideoToolbox decoding, and AppKit windows with per-session input.
- **scrcpy**: the upstream scrcpy client manages each app's virtual display and interactive window.

Use the packaged application in `dist/` after building. See [BUILD.md](BUILD.md) for reproducible build and installation steps, [TESTING.md](TESTING.md) for executed checks, and [verification/REPORT.md](verification/REPORT.md) for evidence and outstanding acceptance items. Physical Pixel verification is described in [PIXEL_VERIFICATION.md](PIXEL_VERIFICATION.md).

Device content stays on the Mac and Android device. No account, cloud service, root, or Android system modification is required. USB debugging grants broad device access: authorize only Macs you trust. Apps that prohibit capture, secondary displays, or additional tasks may not work; see [COMPATIBILITY.md](COMPATIBILITY.md).

## Use

Open DroidBridge, select a connected device, and choose **Native AppKit** or **scrcpy fallback**. Search by app name or package, select an app, and click **Launch App** (or double-click it). Launch another app the same way. Close a native window or use the session's Close button to release its display. Use **Restore Previous Sessions** after relaunch; the reconnect checkbox controls restoration after an interrupted connection. **Create / Update Mac App…** creates a separate launchable wrapper under `~/Applications/DroidBridge Apps` for Finder, Dock, and Spotlight indexing.

Created Mac apps use the launcher activity's icon rendered by Android, including adaptive and vector icons. Each wrapper is a separate Mac application with its own name, icon and process. Run **Create / Update Mac App…** again to update an existing matching wrapper after installing a new DroidBridge version; quit that wrapper first. Updates preserve its launch settings and keep the previous bundle under `~/Applications/DroidBridge Apps/.DroidBridge Backups`. The main launcher's app list loads Android icons asynchronously; unavailable icons have a diagnostic tooltip.

Unexpected session exits keep the wrapper's diagnostics visible instead of silently quitting. Use its retry or fallback controls to start a fresh session. Explicitly closing the session still releases its resources and ends the wrapper.

**Enable device apps in Spotlight** is on by default. Click **Add All Device Apps to Spotlight** to prepare the selected device's apps. The operation runs with bounded background work and progress; use **Cancel** to stop admission, then click Add All again to resume. **Onboarding Details** retains individual errors; apps whose Android icons cannot be extracted are reported for retry. Managed apps are available only while their device is authorized and ready. A per-user availability helper maintains their visibility even after the launcher closes; offline apps move to a private `.noindex` store, and stale results cannot start an Android session. See [APP_ONBOARDING_DESIGN.md](APP_ONBOARDING_DESIGN.md) for ownership, migration and availability behavior.

Existing managed Mac apps are repaired automatically after installing this update and opening DroidBridge. A compatibility pass updates their copied code at the original paths before a second pass removes the visible hash suffixes. Android icons, backend choices and launch settings are retained; no phone connection is needed for this maintenance. Quit running wrappers to let their updates finish. Later releases also refresh accepted wrappers’ copied runtime from the new host using these saved assets. Unique apps use `App Name.app`; only name collisions on the same device receive a readable package suffix.

**Keep phone screen off during Mac sessions** is an opt-in setting saved separately for each device (Android 15+). Select the device, enable the checkbox, and open an Android app. Use **Phone → Turn Phone Screen Off / On** for immediate control; native wrappers expose the same menu. For an SDL fallback window, use DroidBridge’s main launcher/menu. The Mac windows keep receiving video and input while only the physical Android display is off. Closing a Mac app does not turn the phone screen back on; use the explicit On action. Android 17 uses its supported display-reset/wake commands, detected at runtime. This does not unlock the phone, bypass a PIN or remove secure-content restrictions.

**Show Android system decorations** applies to new sessions on either backend. Turn it off to remove Android's virtual-display navigation/launcher surfaces when using Mac app switching. App-drawn controls and the Android keyboard remain controlled by Android. The setting does not change the phone screen or global Android settings.

The current release disables audio. It includes its runtime tools and icon helper, so the installed application does not require Homebrew or an Android SDK installation. Diagnostics are local under `~/Library/Logs/DroidBridge`. See [WRAPPER_DESIGN.md](WRAPPER_DESIGN.md) for the implementation and verification boundaries.

The [0.1.1 verification report](verification/launcher-fix/REPORT.md) covers the wrapper fixes, Android icons and independent review. The focused [Pixel wrapper retest](verification/launcher-fix/PIXEL_RETEST.md) explains the one-time update for existing copied wrappers and the additional window/stop diagnostics.

The [0.1.2 onboarding verification report](verification/onboarding/REPORT.md) records bulk creation, Spotlight availability, helper recovery, performance and independent review. [Android display evidence](verification/desktop-mode/ANDROID_REVIEW.md) covers the system-decoration option on Android 15 and 17.

After a device reboot, discovery and restoration wait for Android boot completion and package services. Interrupted sessions are checked on later four-second polls. Automatic restoration permits three failed launches per outage, with at least eight seconds after each failed attempt; the session remains visible if retries pause. Closing it cancels retry. Turn the reconnect checkbox off to hold interrupted sessions without admitting new ones.
