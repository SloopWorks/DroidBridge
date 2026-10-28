# DroidBridge

DroidBridge runs Android applications on Android while presenting them in separate macOS windows. The launcher discovers authorized USB ADB devices and running emulators, enumerates launchable apps, and offers two session backends:

- **Native**: scrcpy 5.0.1 server, H.264 transport, VideoToolbox decoding, and AppKit windows with per-session input.
- **scrcpy**: the upstream scrcpy client manages each app's virtual display and interactive window.

Use the packaged application in `dist/` after building. See [BUILD.md](BUILD.md) for reproducible build and installation steps, [TESTING.md](TESTING.md) for executed checks, and [verification/REPORT.md](verification/REPORT.md) for evidence and outstanding acceptance items. Physical Pixel verification is described in [PIXEL_VERIFICATION.md](PIXEL_VERIFICATION.md).

Device content stays on the Mac and Android device. No account, cloud service, root, or Android system modification is required. USB debugging grants broad device access: authorize only Macs you trust. Apps that prohibit capture, secondary displays, or additional tasks may not work; see [COMPATIBILITY.md](COMPATIBILITY.md).

## Use

Open DroidBridge, select a connected device, and choose **Native AppKit** or **scrcpy fallback**. Search by app name or package, select an app, and click **Launch App** (or double-click it). Launch another app the same way. Close a native window or use the session's Close button to release its display. Use **Restore Previous Sessions** after relaunch; the reconnect checkbox controls restoration after an interrupted connection. **Create Mac App…** creates a separate launchable wrapper under `~/Applications/DroidBridge Apps` for Finder, Dock, and Spotlight indexing.

The current release disables audio and uses generic launcher/wrapper icons. It includes its runtime tools, so the installed application does not require Homebrew. Diagnostics are local under `~/Library/Logs/DroidBridge`.

After a device reboot, discovery and restoration wait for Android boot completion and package services. Interrupted sessions are checked on later four-second polls. Automatic restoration permits three failed launches per outage, with at least eight seconds after each failed attempt; the session remains visible if retries pause. Closing it cancels retry. Turn the reconnect checkbox off to hold interrupted sessions without admitting new ones.
