# Companion pairing recovery on macOS

On installed build 23, clicking **Devices → Pair Phone…** left the Devices window in front. The action only set “Select an authorized ADB device first” in the Devices status text. The running server’s `adb devices -l` returned an empty list at reproduction. The old host-selection handler also closed an open scanner whenever the selected serial changed. The cause of the Pixel’s loss of ADB connectivity was not established.

## Executed checks

| Command or interaction | Observed result |
| --- | --- |
| `swift build` | Debug app compiled and linked. |
| `swift test` | 385 tests, four opt-in skips, zero failures. |
| `swiftc -parse-as-library -I "$BIN/Modules" <shipping UI sources> scripts/verify-unified-desktop.swift <Core and Streaming objects> -o "$QA/verify-unified-desktop"` and the executable with a private `--companion-qa-root` | AppKit fixture passed. The missing-device click attached a sheet with Refresh Devices and Connect over Wi-Fi. Clearing the selected phone kept the same scanner visible. Selecting another phone paused it, returning to the original phone restored its instructions, and a repeated Pair click reused the window. |
| `DROIDBRIDGE_BUILD_NUMBER=26 DROIDBRIDGE_SIGNING_MODE=adhoc DROIDBRIDGE_OUTPUT_DIR="$REVIEW" DROIDBRIDGE_COMPANION_APK="$APK" ADB_PATH="$ADB" scripts/package.sh` and `codesign --verify --deep --strict "$REVIEW/DroidBridge.app"` | External app package built and passed signature verification. The app executable SHA-256 was `ccbc99c077625799c45a2384d3bf3543c20e6509d334110532d7bf5166fe091e`. |
| External build 26 launched with `--companion-qa-root "$QA" --serial emulator-5582` and operated via macOS accessibility | With no phone in scope, clicking Pair Companion showed “Connect your Android phone first.” The sheet’s Connect over Wi-Fi button opened the Wireless debugging QR setup window. |
| `emulator -avd DroidBridge_API35 -port 5580 -no-window -no-audio -no-boot-anim -read-only -no-snapshot-save` and the `InstalledFlow` driver from `scripts/verify-companion-installed.py` | The first run timed out during APK installation while the shared ADB server was being restarted by another process. The retry used a private loopback ADB server on port 15537, with the exact emulator registered and the test-only broker scoped to that socket. The packaged Mac app installed and opened the bundled Android companion, accepted the current link from its QR, displayed the same comparison code as Android, and reported authenticated pairing after the emulator approved it. |
| macOS accessibility and window screenshot of the deterministic **Companion Verification** app | The installed driver searched for the test app window in the launcher process and timed out. The separate wrapper process showed the live Android fixture UI. Its session log recorded `running`, `native_content_presented`, and `app_display_bound` for `emulator-5580` and `dev.droidbridge.companionfixture`. |

The tests used isolated Mac storage and the dedicated emulator. Camera permission and the physical Pixel were outside this run. Pairing secrets, QR images, and the comparison code were omitted from the report.
