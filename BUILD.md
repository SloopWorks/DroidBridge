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
DROIDBRIDGE_VERSION=0.2.0 DROIDBRIDGE_BUILD_NUMBER=10 scripts/package.sh
```

Build numbers identify a cohort; increment the example for a new release candidate.
The packaging script builds/signs the Android release with the persistent local signing identity (or verifies an explicit DROIDBRIDGE_COMPANION_APK), builds release Swift sources and the original DEX icon helper, assembles an app bundle, builds the pinned source ADB runtime and copies it with scrcpy, the exact server JAR, the dedicated audio client and their dynamic library dependencies, rewrites library paths in private build staging before app assembly, ad-hoc signs, and creates a DMG and checksums. Android SDK platform 35/build-tools 35.0.0 and JDK 17 must be present during packaging; AndroidCompanion/build.sh uses the checked-in Gradle wrapper. The icon helper uses the same pinned Android build tools as the integration fixture. No Homebrew or SDK dependency should be required by an installed bundle.

For an update, quit the old DroidBridge main application before replacing it. Open the new main app once to repair existing managed app names automatically, even with the phone disconnected. Running wrappers wait until they quit; do not run old and new main app versions concurrently during migration. Progress and retry errors appear in the onboarding area and Onboarding Details.

Install by dragging `DroidBridge.app` from the DMG to `/Applications` or `~/Applications`. Launch it, refresh devices, select an authorized Android device or emulator, choose a backend, and launch an app. USB authorization is an Android security prompt and must be accepted on the device.

## Signing

The current candidate is locally ad-hoc signed. No Developer ID signature or notarization was used or is claimed. A valid development/distribution identity is not itself a Developer ID/notarization credential. Gatekeeper behavior for downloaded ad-hoc builds may require Finder's Open or Privacy & Security approval. Do not disable Gatekeeper globally.

## Uninstall

First use **Phone → Companion… → Connection → Forget Pairing on This Mac** for
each saved phone, then remove this Mac from the phone's Trusted Macs. Stop the
phone connection service. Quit DroidBridge, all wrappers and audio hosts. The
broker can outlive the GUI, so unload **both** owned per-user services before
removing shared data:

```sh
launchctl bootout "gui/$(id -u)/dev.droidbridge.companion.broker"
launchctl bootout "gui/$(id -u)/app.droidbridge.availability"
rm "$HOME/Library/LaunchAgents/dev.droidbridge.companion.broker.plist"
rm "$HOME/Library/LaunchAgents/app.droidbridge.availability.plist"
```

Ignore an absent job/plist; investigate any other failure before deleting its
runtime. These are production labels. QA scopes have distinct labels/storage and
must remove only their own jobs. Do not stop a shared ADB server.

Remove the host application and generated wrappers under
`~/Applications/DroidBridge Apps`. Back up wrappers/settings you want to keep.
Removing `~/Library/Application Support/DroidBridge` deletes inactive managed
apps, helper/broker runtime generations, shared settings, companion staging and
saved intent/recovery data. Remove `~/Library/Logs/DroidBridge` for video logs.
User-saved files outside these locations remain. Pairing credentials should have
been removed by Forget before deleting support data.

Optionally uninstall the Android companion through Android App info. Other
Android applications remain installed. Forget/Revoke and uninstall do not revoke
USB/wireless debugging access: remove those authorizations separately in Android
developer settings if no longer wanted. Retain SDK/ADB tools used by other apps.

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

The companion broker is an independent per-user LaunchAgent. See the ordered
uninstall procedure above; quitting the GUI alone does not remove its service or
trust. Upgrade/re-pair behavior is described below.

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

### Build the Android companion separately

```sh
AndroidCompanion/build.sh :app:testDebugUnitTest :app:assembleDebug
DROIDBRIDGE_ANDROID_SIGNING="$(AndroidCompanion/prepare-local-signing.py)" \
  AndroidCompanion/build.sh :app:assembleRelease
```

The installable release is
`AndroidCompanion/app/build/outputs/apk/release/app-release.apk`. Packaging can
instead accept an already verified signed APK via `DROIDBRIDGE_COMPANION_APK`;
it checks that signature and records the exact bytes. The private local Android
signing material lives outside Git under
`~/Library/Application Support/DroidBridge/AndroidSigning`. Back it up securely:
another signer cannot update the existing app in place. Never publish the key or
signing properties. Unsigned APK output is not an installable release.

After installation use **Phone → Companion… → Install / Update Android
Companion** through an authorized device. Start the phone service explicitly and
pair separately. Android 13+ is required. See `AndroidCompanion/README.md` and
`docs/companion/BOUNDARY_CONTRACT.md` for build/protocol details.

### Update and removal details

Before an update quit every old main app, copied wrapper and audio host. Replace
the installed app, open it once, and allow managed maintenance to finish. Update
manual wrappers with Create / Update Mac App. A new ad-hoc broker can be refused
by an old Keychain ACL: the app reports that promptly. Forget local pairing,
remove its phone Trusted Mac entry, and approve a fresh QR/full-link pairing.
Export/profile settings are retained separately; do not delete the support folder
to repair credentials. Same-signed Android updates preserve installation identity;
uninstall/data-clear replaces identity and requires pairing again.

To fully remove the companion, first Forget each phone from Mac Connection and
remove the Mac from each phone's Trusted Macs. Stop the phone service. The broker
may remain alive after quitting the GUI; unload its exact job as described above
before deleting support files. Remove the Android companion through Android App
info if desired. This does not remove other Android apps, saved received files,
USB authorizations or wireless-debugging pairings. Revoke those debugging grants
separately if access is no longer wanted. Do not kill the shared ADB server or
manually prune runtime generations.

For a public release, publish only the exact reviewed artifact/source cohort,
with its versioned manifest and checksums. The compiled 0.2 delivery controls pin
the official `v0.2.0` assets; a missing public asset is shown as unavailable.
Validate the actual unauthenticated HTTPS download and a fresh installed copy
before marking delivery accepted. Current publication/install status belongs to
`verification/companion/RELEASE_CANDIDATE.json`, not this build recipe.
