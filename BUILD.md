# Build and install

## Toolchain

Development host: Apple Silicon, macOS 26.2, Xcode 26.2, Swift 6.2.3. The Swift source targets macOS 13+, but the bundled Homebrew runtime binaries require macOS 26; the packaged release is for Apple Silicon/macOS 26. Source builds targeting older macOS need compatible scrcpy runtime libraries.

Pinned Android streaming protocol: **scrcpy 5.0.1**, client and server together. ADB tested: 37.0.0. Android emulator: dedicated API 35 arm64. See `verification/environment/` for actual host records.

```sh
brew install scrcpy
swift test
scripts/package.sh
```

The packaging script builds release Swift sources, assembles an app bundle, copies ADB, scrcpy, the exact server JAR and their dynamic library dependencies, rewrites library paths, ad-hoc signs, and creates a DMG and checksums. Android SDK/platform-tools must be present during packaging. No Homebrew dependency should be required by an installed bundle.

Install by dragging `DroidBridge.app` from the DMG to `/Applications` or `~/Applications`. Launch it, refresh devices, select an authorized Android device or emulator, choose a backend, and launch an app. USB authorization is an Android security prompt and must be accepted on the device.

## Signing

This build is locally ad-hoc signed. Apple Development and Apple Distribution identities are present; neither is a Developer ID identity suitable for direct notarized distribution. No notarization is claimed. Gatekeeper behavior for downloaded ad-hoc builds may require Finder's Open or Privacy & Security approval. Do not disable Gatekeeper globally.

## Uninstall

Quit DroidBridge, remove its app bundle and any generated Android app wrappers. Remove `~/Library/Application Support/DroidBridge` for saved session intent/recovery receipts and `~/Library/Logs/DroidBridge` for diagnostics. Generated wrappers live in `~/Applications/DroidBridge Apps`. Each generated wrapper contains its own copied runtime and can run independently of the host installation. This does not uninstall Android apps. Keep shared ADB/Android SDK tools if other software uses them.

## Dependencies and redistribution

See [THIRD_PARTY.md](THIRD_PARTY.md). The release includes GPL-enabled FFmpeg libraries used by the separate upstream scrcpy executable. This local artifact is not a notarized public release. Public redistribution requires preserving notices and fulfilling corresponding-source obligations for every bundled library; do not describe a set of download links alone as complete GPL compliance.
