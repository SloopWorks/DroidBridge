# Independent screen-power review

**Verdict: approve DroidBridge 0.1.4 build 9 for the documented emulator-tested screen-power feature.** Physical Pixel panel/lock behavior and direct OS focus remain manual acceptance items. No claim of physical Pixel testing, Developer ID signing, or notarization is made.

The exact installed executable tested is `~/Applications/DroidBridge.app/Contents/MacOS/DroidBridge`, SHA-256 `3f3b6245a37fe1513250a60b605f5033712f585df2ff0e78124105fe6cdd06f9`. It was installed outside the build directory from the final DMG. The package audit and install transcript are `../package-final.json` and `../install.log`; runtime versions and contained Mach-O dependencies were checked by the lead. The three independent installed UI tests below verify this same executable hash before launch.

## Independent executable checks

| Check | Result | Evidence |
|---|---|---|
| Queued and in-flight latest intent, both ON/OFF directions | Pass | `core-tests.log`; `Tests/DroidBridgeCoreTests/PhoneDisplayPowerQATests.swift` (14 tests) |
| Deferred panel updates cannot preserve a stale forced override | Pass | Controlled OFF→ON and ON→OFF fixtures assert actual command targets, not merely stale state samples |
| Real cross-process mutex, bounded busy/cancellation, separate-device progress | Pass | Independent Python child holds actual `flock`; no Android command is admitted on cancelled/stale requests |
| AOD states, API35 legacy scope, API37 reset/wake, missing/unsupported state, exit-zero false success | Pass | 14 independent Core tests; unknown state is refused; unadvertised legacy commands limited to API35 |
| Installed API35 Phone menu and checkbox ON/OFF | Pass | `installed-api35/result.json`; real native app launched through its table/Launch button |
| Installed API35 failed ON remains retryable | Pass | `installed-api35-on-retry/result.json`, `receipt-9.json`; one exact armed ON call failed via test-only pass-through ADB proxy, visible retry text appeared, OFF intent cleared, panel stayed OFF initially, then real ON succeeded |
| Installed API37 Phone menu and checkbox ON/OFF | Pass | `installed-api37/result.json`; real runtime API37 reset path; the separately recorded asleep Core test verifies wakeup |
| Per-device UI preference and physical-state isolation | Pass | API37 run selects API35 and back; checkbox/persisted flag and other primary display state remain unchanged |
| Live native content while primary display OFF | Pass | Each installed run captures `off-first.png` then `off-second.png` while OFF; hashes differ, with no failed/stopping/stopped event between; inspected actual probe content rather than a black screenshot |
| Installed host termination/resource cleanup | Pass | All three own hosts exit 0; each selected device returns to one display and its empty forward baseline; original preference/session bytes and file permissions restored |
| Added checkbox layout | Pass for geometry | `ui-layout.json`, `layout.log`; all tracked views contained and unhidden. Effective minimum is 900×754 content/900×786 frame. Locked-host bitmap limitations prevent a full paint/readability claim |

The installed action fixture uses public AppKit menu `performActionForItemAtIndex`, checkbox `performClick`, table selection and the real Launch button. Its native NSView draws are real decoded Android content. These are in-process control-path tests, **not physical mouse delivery or OS-focus tests**. Baseline runs use bundled ADB unmodified; only the explicitly labeled ON-retry run substitutes a pass-through test proxy to fail one command.

The final full suite log (`../unit-final.log`) records **121 tests, four explicitly device-gated skips, zero failures**. This is not described as 121 live-device tests. Actual Android integration is separately evidenced below.

The final identity audit (`approval.json`) independently recomputes all **43 production input hashes** from `../release.json`: zero mismatches, with the installed hash above unchanged. I also inspected and asserted the lead's exact-artifact two-cycle relaunch result (`../relaunch/result.json`): both launches automatically reapplied persisted OFF intent, decoded a native frame, exited gracefully, kept the panel OFF on close and restored scoped resource baselines. This supplements, rather than substitutes for, the independent UI runs.

## Reviewed integration evidence

I inspected the Android API35/API37 component reports, native server argv and input logs, and actual native API37 PNG. Production native API37 uses `keep_active=true`, `power_on=false`, `display_ime_policy=local`; two distinct displays 8/9 receive `PanelOffA`/`PanelOffB` and click receipts. During physical-display OFF it records 194/237 frames with 133/225 distinct frame hashes, resize to 896×640, continued remaining stream after first close, unchanged Android settings and exact resource cleanup (`../android/api37-production-local-ime/`). The API35 native result likewise records both apps accepting text/clicks and live frames while OFF.

Final production fallback callers request startup concurrently, then the per-device gate serializes initialization. The retained port leases differ (46001/46000), and logs bind apps to distinct displays 17/16. Android-side receipts contain `1ProductionAk` and `2ProductionBk` with their exact display IDs and click receipts. Recordings contain changing real frames, primary display 0 remains OFF through the idle/input/first-close/final-close checks, settings remain unchanged, and scoped forward/reverse/display baselines return (`../concurrent-fallback/result.json`, `frames.json`, `a-input.log`, `b-input.log`, `*-production-argv.json`; final run `../concurrent-fallback-final.log`). I inspected a decoded fallback PNG as well.

The earlier failures remain evidence, not passes: API37 keyboard failed with the previous IME policy, and A/B/A control runs isolated that policy effect. A later fallback fixture used coordinates from a different frame geometry and clicked a gap rather than the EditText; `../harness-geometry-failure.png` and its log are retained. The final fixture maps actual geometry and obtains display-bound input receipts. Neither queued SDL events nor an agent's assertion alone are treated as Android input proof.

## Source review and remediation

- Physical display parsing positively identifies one INTERNAL display 0; committed/virtual state is not substituted. Known AOD states are modeled, while unknown/missing/ambiguous state fails closed. Actuation verifies ON/OFF and never treats exit zero alone as confirmation.
- Persisted per-device intent is re-read under the cross-process mutex and after asynchronous operations. Both directions reconcile after effects; explicit ON writes the reset/ON command even if a delayed sample still says ON. Phone-control failures do not terminate app sessions.
- Explicit ON failures retain a live-process retry request with bounded backoff and visible diagnostics. Closing the last session never implicitly wakes the phone. Quitting the host cancels its pending requests; a pending ON is not a durable cross-relaunch job, as documented.
- The port review found a crash-startup lifetime gap in a GUI-only lease. It was remediated by inheriting the same open file description as supervisor stdin and closing, rather than explicitly unlocking, the parent's reference. This keeps the lease until supervised descendants exit. The real-child pre-listener lifetime regression passes. Port/type/owner checks and `O_NOFOLLOW` protect lock-file handling; already bound foreign ports are skipped.
- The startup gate is per-device, finite, cancellable and not inherited by the client; apps continue concurrently after initialization. Its `.running` receipt is an exact server launch-request/display receipt. The server emits that line before `Device.startApp`; it is **not independently proof of decoded video**. Actual acceptance above requires frame recordings/native images and Android receipts. Client INFO logs are buffered on macOS, so requiring a live Texture logfile line alone would be unreliable.
- PIN bypass, POWER-key toggles, root access, shared ADB-server shutdown and global stay-awake/screen-timeout setting writes are not part of this feature.

No release-blocking issue remains in the reviewed screen-power scope. Hardware panel brightness, Pixel-specific restrictions, secure apps, long battery/thermal soak and physical OS switching remain outside this emulator/AppKit instrumentation evidence. Dedicated-device and helper cleanup after this QA handoff is owned by the lead; this reviewer released both task emulators and all preferences/AppKit reservations with no owned test host left running.
