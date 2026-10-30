# Build and install

## Toolchain

Development host: Apple Silicon, macOS 26.2, Xcode 26.2, Swift 6.2.3. The Swift source targets macOS 13+, but the bundled Homebrew runtime binaries require macOS 26; the packaged release is for Apple Silicon/macOS 26. Source builds targeting older macOS need compatible scrcpy runtime libraries.

Pinned Android streaming protocol: **scrcpy 5.0.1**, client and server together. ADB tested: 37.0.0. Android emulator: dedicated API 35 arm64. See `verification/environment/` for actual host records.

```sh
brew install scrcpy meson ninja pkg-config cmake protobuf brotli lz4 zstd libusb
scripts/build-adb-runtime.sh
scripts/build-audio-client.sh
scripts/build-icon-helper.sh
swift test
scripts/package.sh
```

The packaging script builds/signs the Android release with the persistent local signing identity (or verifies an explicit DROIDBRIDGE_COMPANION_APK), builds release Swift sources and the original DEX icon helper, assembles an app bundle, builds the pinned source ADB runtime and copies it with scrcpy, the exact server JAR, the dedicated audio client and their dynamic library dependencies, rewrites library paths in private build staging before app assembly, ad-hoc signs, and creates a DMG and checksums. Android SDK platform 35, build-tools 35.0.0, platform-tools and a JDK must be present during packaging. The icon helper uses the same pinned Android build tools as the integration fixture. No Homebrew or SDK dependency should be required by an installed bundle.

For an update, quit the old DroidBridge main application before replacing it. Open the new main app once to repair existing managed app names automatically, even with the phone disconnected. Running wrappers wait until they quit; do not run old and new main app versions concurrently during migration. Progress and retry errors appear in the onboarding area and Onboarding Details.

Install by dragging `DroidBridge.app` from the DMG to `/Applications` or `~/Applications`. Launch it, refresh devices, select an authorized Android device or emulator, choose a backend, and launch an app. USB authorization is an Android security prompt and must be accepted on the device.

## Signing

This build is locally ad-hoc signed. Apple Development and Apple Distribution identities are present; neither is a Developer ID identity suitable for direct notarized distribution. No notarization is claimed. Gatekeeper behavior for downloaded ad-hoc builds may require Finder's Open or Privacy & Security approval. Do not disable Gatekeeper globally.

## Uninstall

Quit DroidBridge and its wrappers. If bulk onboarding was used, first unload the owned per-user availability helper, then remove its plist:

```sh
launchctl bootout "gui/$(id -u)/app.droidbridge.availability"
rm "$HOME/Library/LaunchAgents/app.droidbridge.availability.plist"
```

An absent job/plist can be ignored. Remove the host app bundle and generated Android app wrappers under `~/Applications/DroidBridge Apps`. Remove `~/Library/Application Support/DroidBridge` for managed inactive apps, helper generations, shared preferences and saved intent/recovery receipts; remove `~/Library/Logs/DroidBridge` for diagnostics. Back up any previous wrapper generations you want to retain before removing support data. Each wrapper contains its pinned runtime using independent copy-on-write files where supported. Managed wrappers also require their catalog and an available authorized device. This does not uninstall Android apps. Keep shared ADB/Android SDK tools if other software uses them.

The helper retains at most eight immutable runtime generations. Upgrades preserve the configured generation, live process leases and unknown/in-use files. Verified unused generations can retire through a recoverable journal; interrupted copies and deletions are resumed only after their exact file identities are checked. A capacity refusal remains visible when safe reclamation cannot make room. Keep the helper store for automatic retry rather than deleting generations manually. Availability logs rotate with a 1 MiB current file and one previous file.

## Dependencies and redistribution

See [THIRD_PARTY.md](THIRD_PARTY.md). The release includes GPL-enabled FFmpeg libraries used by the separate upstream scrcpy executable. This local artifact is not a notarized public release. Public redistribution requires preserving notices and fulfilling corresponding-source obligations for every bundled library; do not describe a set of download links alone as complete GPL compliance.

The audio client builds pinned scrcpy commit
`a60891aea193d92e7e5c3942700eca63f9d19a5f` from its Git archive, with the tracked
`scripts/patches/audio-output-ready.patch`. The patch adds positive output
readiness and fenced supervised transport identity/cleanup; the video Player is
unchanged. Build cache is `.build/audio-client`; package versions and bundled
notices bind the source and patch. Developer overrides use
`DROIDBRIDGE_AUDIO_CLIENT`. Installed applications use only bundled tools.


## Companion service and release source

The companion broker is an independent per-user LaunchAgent. Before uninstall,
use Companion → Connection → Forget Pairing on This Mac for each saved phone,
then remove this Mac from the phone's Trusted Macs if the phone is available.
This deletes companion trust separately from Android debugging authorization;
existing ADB windows can continue until closed or debugging access is revoked.
Unload only `gui/$(id -u)/dev.droidbridge.companion.broker` and remove only
`~/Library/LaunchAgents/dev.droidbridge.companion.broker.plist`. Quit wrappers
before removing the shared support directory. Do not stop a shared ADB server.
QA-scoped jobs have different labels and storage; the verification scripts clean
only their own jobs.

The source ADB recipe pins four archives plus three compatibility patches and
builds protobuf/Abseil statically while retaining dynamic libusb. It emits
`.build/adb-runtime/adb-runtime.json`, notices, source inputs and
BUILD_PROVENANCE.json. Packaging verifies each signed binary and exact relative
load closure, copies those bytes unchanged and verifies them again. The installed
application and private background services need no Homebrew paths.

For public source delivery, collect the exact installed Homebrew recipes/sources
with `scripts/collect-corresponding-source.py --runtime <packaged Runtime>`, then
run `scripts/package-corresponding-source.py --commit <exact candidate> --app
<packaged app> --output <source archive>`. The latter requires the matching source
ADB provenance, archives and committed build recipes. Generate release installer
metadata with `scripts/create-release-manifest.py` only after the actual DMG and
app have been verified. Preserve separate SHA-256 checksums. A successful source
packaging script does not replace independent distribution review.
