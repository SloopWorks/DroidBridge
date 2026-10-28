# Final installed wrapper verification — 2026-10-28

The final run used `/Users/patrick/Applications/DroidBridge.app`, installed from the read-only 0.1.1 DMG. Its main executable SHA-256 was `33c6fe59e2a1a16e434ffadcbaf5361a0c12ad02409a2ec702f35fc3f9af1f83`.

Reproduce from the repository with:

```bash
DROIDBRIDGE_TEST_HOST="$HOME/Applications/DroidBridge.app" scripts/test-macos-wrappers.sh
```

`run.log` records the final PASS. The harness compiles the shipping wrapper creator and uses the exact installed runtime/executable to create and launch native Settings and a scrcpy launcher-alias fixture concurrently on emulator-5580. It validates transactional creation, byte-preserved existing launch configuration, retained backup generation, rejection of invalid icons and unrelated bundles, and refusal to overwrite a destination created concurrently. Completed signed test bundles remain at the path in `wrapper-root.txt`.

`session-events.json` contains the native decoded-first-frame running state and `native_window_presented(reason=first_frame, visible=true, minimized=false)` before hiding its launcher. `fallback-video.log` records the upstream decoder's live Texture size and application/display binding. The test-only unbuffered stdout shim changes buffering only; it does not replace capture, input, or lifecycle behavior.

`identities.json` records two distinct regular `NSRunningApplication` frontend identities. The scrcpy wrapper's parent is accessory while its personalized Player is regular. Both frontend names/icons use their Android applications. Original Android bitmaps survive PNG→ICNS conversion with mean absolute channel error below 0.2/255. macOS 26 composes legacy ICNS artwork inside a system container, so running icon pixels are compared to the public NSWorkspace rendering of that exact bundle (zero error), and are independently required to differ from the generic DroidBridge host icon. Exported `*-android-icon.png` and `*-running-icon.png` permit visual review.

The Mac was locked. These tests establish separate regular application identities, icon artwork, native NSWindow visibility/non-minimized state, and actual live streams. They do not establish user-observed Dock/Cmd+Tab switching, OS activation/key-window success, or physical Pixel behavior. The native receipt honestly records `app_active=false` and `key=false` under this environment.

`owned-example-migration.json` additionally records actual updates of the two task-owned pre-existing Settings/Clock 0.1.0 examples. Their original launch.json bytes were preserved, prior complete bundles retained under `.DroidBridge Backups`, final executable code payloads matched, and deep/strict signatures passed. Per-wrapper signing identifiers change embedded Mach-O signature bytes; code equality was checked after removing signatures only from temporary copies. No unrelated application was modified. The actual user's ChatGPT wrapper and Pixel were not available locally and were not claimed migrated or tested.

Earlier failed test output is preserved: `initial-update-failure.log` used URL equality sensitive to directory markers and `/var` aliases; `buffered-output-*.log` assumed immediate upstream stdout; `initial-pixel-normalization-failure.log` compared raw artwork directly with macOS's composed icon. Each expectation was corrected and the complete test rerun against the final installed build. `initial-template-pass.log` belongs to an earlier packaged candidate and is not the final release evidence.

Both owned test processes were asked to quit normally and awaited; test persistence was restored to its prior bytes. QA separately owns process teardown, failure retention, explicit window close, and complete installed-application regression coverage.
