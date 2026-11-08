# Independent Android app icons and launch progress

Implemented and verified locally on November 7, 2026. Independent macOS/Swift review accepted this feature build; see [REVIEW.md](REVIEW.md).

## Result

Launch App, Return and double-click now resolve an independent Mac application instead of placing the Android window in the management process. Matching running wrappers take priority across managed, manual and private locations. Stopped wrappers must match the selected phone/package/backend and pass freshness/signature checks. Otherwise DroidBridge builds a private wrapper with the Android MAIN/LAUNCHER activity's full-size icon and a stable device/package/backend identity. Existing manual settings and Spotlight choices are preserved.

An app-named spinner/banner appears synchronously before asynchronous work, survives device-status refresh and workspace navigation, and offers preparation cancellation. Stages cover lookup, icon extraction, preparation and opening. Successful Launch Services handoff confirms opening; the wrapper's local loading window owns connection/video progress. Reopening focuses the existing process/session. Independent app session state remains visible without companion pairing and is rediscovered after restarting management. Missing/stale presentation is never retained as a fresh Running claim.

All filesystem, copy, hashing, signing and presentation-store work runs outside MainActor. Preparation and shutdown drain owned tasks; exact process start time and bundle identity fence snapshots and app actions. Per-app publication uses a cancellable, bounded kernel lock. Local presentation records grant no command or process-control authority.

## Review artifact

`/Users/patrick/Library/Application Support/DroidBridge/ReviewBuilds/app-launch-icons-22/DroidBridge.app`

- Version 0.2.0, build 22, local ad-hoc signing.
- Executable SHA-256: `9d9bc9eb5a2d44be74f3ac7441c7d71e754cc1c950a951d67c546ec8c74e9757`.
- Built through `scripts/package.sh`, copied/published outside `.build`, and run there.
- `codesign --verify --deep --strict` succeeds. Embedded architecture/wrapper documents match source.
- Detailed metadata: [artifact.json](artifact.json). Source fingerprints: [source-sha256.json](source-sha256.json).
- The existing installed/running user copies were preserved. Quit those copies before opening the review application to avoid macOS reopening an older application with the same management bundle identifier.

## Executed verification

| Gate | Evidence and result |
| --- | --- |
| Build | `swift-build.log`; `swift build` passes. |
| Full unit suite | `swift-test-final.log`: 357 tests executed, 4 skipped, 0 failures. |
| Registry | `registry/swift-test-directory-hint.log`: 13 tests, 0 failures. Includes generation/PID-start fencing, bounded/unsafe files, directory-hint equivalence, actual backend changes and cancelled lock waits. |
| Resolver/factory | `resolver/run.log`, `resolver/resolver-results.json`: 21 checks pass. Includes live-over-stopped selection, wrong phone/backend exclusion, deterministic identities, invalid paths/metadata/icons, bounded preparation contention, cancellation, staging cleanup and released-lock reuse. These are metadata/factory fixtures, not Android-video evidence. |
| Actual Android/native/fallback | `runtime-final/run.log`, `runtime-final/results.json`, `runtime-final/Logs/`: all 12 recorded runtime cases pass using the shipping launcher/factory, Launch Services and the dedicated emulator. Native admission requires a real decoded frame and the test additionally awaits visible decoded content. Fallback requires an actual SDL video texture and a regular Player identity. |
| Icons and independent applications | Runtime compares actual Android PNG to bundled ICNS, and running NSRunningApplication icons to Launch Services' presentation. Native icon pixel errors are zero and icons differ substantially from the generic DroidBridge icon. Two apps have distinct regular identities. Fallback Player identity/icon is also checked. |
| Reuse/progress/lifetime | Runtime verifies synchronous visible progress, periodic-status resistance, progress across navigation, cancellation before admission and during icon extraction, same PID/session reuse and unhide, independent-app survival after management shutdown, unpaired rediscovery, missing-status clearing, and exact app closure. |
| Packaged button/UI | CUA operated the external packaged application's actual Launch App button for `dev.droidbridge.testapp7`. `packaged-android-window.png` shows actual changing Android test content; `packaged-sessions.ax.txt` and `packaged-sessions.png` show Running without pairing. The actual Close App button removes the row (`packaged-close.ax.txt`). `ui-main.log` records repeat handoff to the same PID 94032. |
| Standalone factory compatibility | `standalone-wrapper-typecheck.log`: the original standalone wrapper-verification compilation remains valid; the factory has no dependency on management-controller code. |
| Packaging | `package-final-accepted.log`: package, pinned 5.0.1 runtime, Player and strict signature checks pass. |
| Resource cleanup | `final-resource-cleanup.json`: display count returned to baseline, forwards restored, no Android scrcpy servers remain. Only owned DroidBridge_API35 / emulator-5580 was stopped. `artifact-checks-and-cleanup.json` records removal of the exact isolated QA broker job and test roots. Shared ADB, production helper jobs and emulator-5554 were preserved. |

Commands and fixture details are in the executable scripts and captured logs:

```sh
swift build
swift test
scripts/verify-app-launch-resolver.sh
DROIDBRIDGE_LAUNCH_REVIEW_APP='<external review app>' scripts/verify-app-launch-icons.sh
DROIDBRIDGE_BUILD_NUMBER=22 DROIDBRIDGE_SIGNING_MODE=adhoc \
  DROIDBRIDGE_OUTPUT_DIR='<external ReviewBuilds/app-launch-icons-22>' \
  DROIDBRIDGE_COMPANION_APK='<repo>/AndroidCompanion/app/build/outputs/apk/release/app-release.apk' \
  ADB_PATH='<repo>/.build/adb-runtime/adb' scripts/package.sh
```

The dedicated emulator was started with `emulator -avd DroidBridge_API35 -port 5580 -no-window -no-audio -no-boot-anim -no-snapshot-save`; its output is `emulator.log`. No physical-phone operation was performed.

## Retained failed attempts and scope

- Initial runtime exposed URL directory hints comparing unequal for the same application path. Path-based app identity and regression tests fix this without relaxing PID/start or bundle identity checks.
- A fallback verifier compared `/private/tmp` with `/tmp` without normalizing; its path check was corrected. Another verifier sampled Running before initial black frames yielded visible content; it now explicitly awaits `native_content_presented` before accepting native presentation. Final tests retain both video gates.
- One package attempt correctly stopped when inputs changed during compilation. Another selected an already bundled ADB without source dependency origins; the final package uses the complete source-built `.build/adb-runtime` cohort and passes provenance/load-closure checks.
- Actual Dock/Cmd+Tab visual capture is **not certified**: CUA's Dock target timed out and its window screenshot does not expose the system switcher overlay. Running regular application identities/icons, Launch Services reuse, actual named windows and Android pixels were executed and verified separately.
- Physical Pixel 10 Pro acceptance remains deferred to the owner under AGENTS.md. This is an ad-hoc local build, not a Developer ID/notarization or publication acceptance claim. No push, upload or production deployment was performed.
- Prior uncommitted connection-recovery work was preserved; the current changes remain uncommitted for review.
