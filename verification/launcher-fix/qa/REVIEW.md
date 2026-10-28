# Independent QA review — DroidBridge0.1.1

Review date:2026-10-28. Final installed candidate main SHA256:
`6de35eea781f59398375fe882248ec21aaab2c66be1d35963498161cec3d9c6b`.
The app was installed outside the build directory at `~/Applications/DroidBridge.app` from the packaged read-only DMG. Its main hash matches `dist/DroidBridge.app`.

## Verdict

**PASS for the tested macOS/emulator release scope.** Independently executed source, native streaming, installed lifecycle, icon crash recovery, recreated wrapper identity/icon/presentation, and package checks pass against the exact final candidate. No outstanding confirmed release blocker remains. The final creator code payload manifest matches the installed executable after signature-only normalization; both live wrapper frontends were independently checked.

Physical Pixel/ChatGPT foreground behavior and actual Dock/Cmd+Tab interaction remain unverified. The Mac is locked; visibility receipts must not be described as OS foreground-focus proof.

## Executed final gates

| Gate | Result | Evidence |
|---|---|---|
| Full suite with every device opt-in enabled |37 tests,0 failures,0 skips;52.38 seconds|`full-suite-final.log`|
| Two actual native app streams, independent mouse/text, real resize and cleanup |Pass|`streaming-final/` and full-suite log|
| Shipping launcher first-frame presentation, Reopen reuse, retained failures and stale retry timer |Pass|`failure-retention.log`, `presentation.json`, case `.log/.jsonl` files|
| Icon cache128, queue64, concurrency2; canceled providers and tracked refresh awaited at quit |Pass|`failure-retention.log`|
| Actual installed host killed after real icon push; successor recovers exact files/receipt |Pass; ownerSIGKILL, successor exit0|`icon-crash-recovery/results.json`, `staged-receipt.json`|
| Both installed backends × host crash, normal quit, stream-child crash |6/6 pass|`installed-final/results.json`|
| Both installed backends in wrapper mode, real stream child killed |2/2 pass; hosts survive beyond old three-second close deadline|`wrapper-failure-final/results.json`|
| Actual installed Mach-O in QA wrapper, public NSWindow close |Pass; exit0; decoded frame before close; explicit window_close cause|`wrapper-close-final/results.json`, `.jsonl`|
| Strict bundle signature,22 Mach-O dependency trees, isolated-PATH tool versions |Pass|`package-final.json`, `package-final.log`|
| Final owned resource audit |60 exact host/childPIDs absent; no owned receipts/forwards; one base display; crash icon paths recovered|`final-resource-check.json`|
| Final recreated native/fallback wrappers, active update refusal, source Android artwork and separate running identities |Pass|`../wrappers/`, `final-created-wrapper-native.jsonl`|
| Android17/API37 actual Settings native stream and resized frame |Pass;45 decoded frames,896×640 after settling|`api37/results.json`, `api37/settings-resized.png`|

The full suite command was:

```sh
DROIDBRIDGE_TEST_SERIAL=emulator-5580 DROIDBRIDGE_TEST_ICONS=1 \
DROIDBRIDGE_INTEGRATION=1 DROIDBRIDGE_QA_LIFECYCLE=1 \
DROIDBRIDGE_EVIDENCE="$PWD/verification/launcher-fix/qa/streaming-final" swift test
```

Reproduction scripts: `scripts/verify-wrapper-failure.sh`, `verify-installed-icon-recovery.py`, `verify-installed.py`, `verify-wrapper-close.py`, `verify-package.py`, and `verify-api37-native.swift`. Installed checks use the application path plus separate `--output` directories; wrapper failure checks use `--wrapper --mode child-crash`.

## Findings resolved and independently verified

- **Stale wrapper-close timer:** retry/reconnect removes the old intent, but the replacement may itself end before the old timer fires. New admission now cancels that timer; termination requires an empty session dictionary. The shipping-source test waits beyond the deadline and still finds the replacement's recovery controls.
- **Lost initiating error:** startup cancellation after an asynchronous native transport failure used to replace its specific cause. The launcher preserves the existing failed-session reason. A real socket handshake plus deliberately invalid packet size proves the exact failure and counters survive suspended startup settlement.
- **Clean process exit before a first frame:** now becomes failed startup with explicit phase, exit status and log path. Both the unit regression and shipping launcher require meaningful exit0 context rather than generic CancellationError.
- **Unreviewable unexpected exit:** native/external terminal sessions remain retained, visibly expose Retry/other-backend/Log controls, and restore regular wrapper activation policy. Explicit close retains the documented release-and-exit policy.
- **Native wrapper presentation gap:** the first decoded-frame transition explicitly activates and reveals/deminiaturizes the native host. A deterministic shipping-source test hides/minimizes a host while waiting for a genuine VideoToolbox-decoded synthetic H264 frame, then verifies visible/nonminimized state. Reopen reveals the same session without a new Android admission.
- **Icon task lifetime and bounds:** shutdown cancels and awaits providers, wrapper construction and refresh/recovery tasks; existing sessions stop before waiting for refresh. The executed fake-tools test waits for two real provider cleanup commands and an already-running1.5-second discovery subprocess. Cache and queue bounds are asserted.
- **Icon crash ownership gap:** actual hostSIGKILL reproduced stranded icon files on the earlier candidate. The final provider writes a durable owner/serial/UUID receipt before remote writes; startup/poll recovery validates exact derived paths, skips live owners and exact outstanding producers, retains offline requests, caps work/time/diagnostics and rotates its128-receipt cursor. The delayed-writer, concurrent cleanup and cursor regressions execute in the37-test suite. An actual installed staged-push crash/relaunch test proves recovery and final drain.
- **Wrapper publication cancellation gap:** a final cancellation check now follows the awaited running-app snapshot, before synchronous atomic publication. Complete signed bundles replace matching wrappers atomically; prior launch intent and complete prior generations are retained. Malformed icons, unrelated bundles and destination races are refused by the creator harness. The final live-update test also receives the expected quit-first refusal and verifies the running wrapper launch configuration bytes remain unchanged.
- **Semantic icon identity:** the test separately compares stored ICNS pixels to the actual Android-rendered PNG, then running NSRunningApplication icon to macOS's platform presentation and to the generic host. Valid NSImage alone is insufficient. Independently inspected Settings gear and purple/yellow launcher-alias images. The earlier apparent mismatch was a test normalization error plus platform icon plating; initial failed evidence is retained.

## Evidence integrity and limitations

The initial32-test run failed a global-empty-temp assertion. Paired PNG mtimes13:53–13:56 predated the14:04 suite; pushed JARs preserve their source mtime and cannot date admission. The failed log and inventory remain in `full-suite-initial-baseline-failure.log` and `remote-temp-inventory.txt`. The live test now asserts no new files relative to its pre-request baseline. No unscoped prefix deletion was used.

Before durable receipts, actual hostSIGKILL produced two requests' JAR/PNG files per backend. At the QA verification stage, historical files with no ownership receipt were deliberately preserved. After all tests, the lead removed24 exact known legacy test paths from the recorded inventory and earlier owned crash cases; no prefix deletion was used (`../release/legacy-test-temp-cleanup.json`). The final candidate may also leave icon files immediately afterSIGKILL, accompanied by durable receipts; successor recovery removes them after any admitted producer retires. The aggregate final check proves the exact crash paths from the final session tests are absent afterward. This is recovery evidence, not a claim thatSIGKILL runs app cleanup.

The user's ChatGPT JSONL shows starting → running after two seconds → stopping/stopped roughly103 seconds later, without failed state. Native running requires a decoded frame. The user reports the wrapper window never appeared, no intentional disconnect, and launching ChatGPT from the main launcher works. These facts support investigating Mac presentation; they do not identify the historical stop caller or establish an Android app/codec restriction. New presentation and stop-cause receipts make future diagnosis explicit. No physical Pixel serial is reproduced here. The final API37 receipt-aware icon subset was independently read:8 tests,0 failures,0 skips (`../icons/api37-final-receipt-tests.log`).

`presentation.json` records visible=true/minimized=false but key=false/app_active=false under the locked host. This proves AppKit visibility restoration, not an observed frontmost window, Dock click or Cmd+Tab action. The API37 Settings smoke sends a scroll command but does not independently assert its Android UI receipt. Android17 emulator success is not physical Pixel/ChatGPT certification. Wallpaper-themed monochrome icons are outside the tested icon semantics.

The application is locally ad-hoc signed; strict signature success does not imply Developer ID trust or notarization. The earlier stale diagnostics version header was corrected in the final recovery-aware build. Existing emulator5554 was not stopped or modified by QA.

The full final-created native wrapper log was independently read beyond the startup snapshot. `final-created-wrapper-native.jsonl` proves decoded running → native_window_presented(visible=true) → launcher_hidden(native_window_visible=true) in order. The final wrapper manifest records installed main6de35eea… and normalized unsigned code efb62a3bf2df91df4aefe62d9be87ee1f21b026c7ca5d219c4ea7282f612bdaa for the installed executable and both generated wrappers.

For stop diagnosis, use the first session_stop_requested reason. Normal application quit first records application_quit; AppKit's subsequent destruction of native windows can emit a later session_close(window_close). That secondary close fact does not establish an intentional user close.

The lead subsequently completed final known-example migration, stopped only dedicated AVDs5580/5582 with name guards, and preserved emulator5554. Final cleanup evidence is `../release/handoff-cleanup.json`. QA issued no further device operations after release.
