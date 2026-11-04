# DroidBridge Android companion

Ordinary Android 13+ application; no root or privileged app-streaming permissions.
Use `./build.sh :app:assembleDebug :app:assembleDebugAndroidTest :app:testDebugUnitTest` with
JDK17 and Android SDK37 (runtime target/min remain 35/33). APKs are below `app/build/outputs/apk/`.

The foreground connection service must be started explicitly in the phone UI.
Pairing lasts two minutes and requires approval of the named Mac on the phone.
The full QR/manual link carries the mandatory installation TLS certificate pin;
bare secrets and old pinless links are rejected before sending credentials. See
[TLS.md](TLS.md) for identity, certificate validity and explicit re-pair rules.
The service listens on Android loopback only, port37841, reached by an exact
ADB forward. Android's paired wireless debugging can carry that same transport;
this application does not open a raw LAN listener or silently grant ADB access.

For an installable locally signed release:

```
DROIDBRIDGE_ANDROID_SIGNING="$(./prepare-local-signing.py)" ./build.sh :app:assembleRelease
```

The private signing identity lives in the current user's Library/Application
Support/DroidBridge/AndroidSigning, with private file permissions. Preserve it to
install future updates without uninstalling the companion. It is a local release
identity, not Play App Signing or an independently audited public release key.
An unsigned release is emitted if no signing config is supplied; never distribute
that file as an installable artifact. No credentials or signing material belong
in the repository.

Runtime/instrumentation verification must use only the coordinated owned AVDs,
never the user's physical phone or unrelated emulator. The independent boundary
contract and capability report are in `docs/companion/`.

For release-signed instrumentation, also set `DROIDBRIDGE_TEST_BUILD_TYPE=release`
and build `:app:assembleReleaseAndroidTest`; the test APK uses the same private
local signer. The QA attacker module is never bundled into the product.

The Settings screen offers an explicit lookup of versioned Mac installer metadata.
It contacts only the official GitHub release hosts and sends no phone identity,
trust or content. Download/copy actions stay disabled until the bounded metadata
matches this version, Apple Silicon/macOS26 platform, exact release URL and
SHA-256/signing policy. Android cannot install or approve Mac software. An
unpublished release is shown as unavailable, not as a successful delivery.

Third-party notices are available offline from Settings. The release runtime
classpath contains ZXing core3.5.3, Kotlin standard library2.3.21, Material
Components1.13.0, AndroidX Activity1.11.0 and their transitive runtime dependencies. Exact upstream texts and hashes are in `app/src/main/assets/licenses`;
Mac packaging extracts notices from the actual bundled APK and verifies byte
agreement. Build/test dependencies and the attacker APK are not bundled.

## Consent and public installer lookup

Forgetting a trusted Mac stops companion sharing and commands from that Mac.
ADB authorization and existing scrcpy windows have a separate lifetime. Revoke
USB and wireless debugging in Android developer settings separately to stop that
access; saved external files are not erased.

The explicit official installer metadata lookup has a 10-second elapsed budget
checked between I/O steps and configured connect/read timeouts of up to 5 seconds
per step. An in-flight network operation may finish after the elapsed budget;
this is not an absolute 10-second wall-clock deadline. No device identity, trust
or shared content is included in this public versioned HTTPS lookup.

## Development diagnostics and distribution

Debug and `.dev` development builds use the actual SWIP/DebugDrawer libraries
through the debug-only Settings → Local diagnostics screen. Collection starts
OFF, requires explicit opt-in, stays bounded in memory and never uploads. Release
uses an inert twin and excludes the collectors/inspector. Run
`./verify-release-diagnostics.py app/build/outputs/apk/release/app-release.apk`
to check the packaged DEX boundary.

For isolated source verification when private Maven read credentials are not
available:

```
./prepare-sloopworks.py --workspace /Users/patrick/workspace
./build.sh -PsloopworksLocalMaven="$PWD/build/sloopworks-maven" :app:assembleDevelopment
```

`development` has application ID `dev.droidbridge.companion.dev`, preserving the
ordinary companion install. Its connection service must not run beside another
companion service on the same Android user because both own loopback port37841.
Shipyard Deploy embeds development build identity before signing; its repository
configuration uses the existing trusted development server and NOTIFY channels.
Project registration currently requires an administrator; a local build is not a
published/installed build. See
[the integration contract](../docs/companion/SLOOPWORKS_INTEGRATION.md).
