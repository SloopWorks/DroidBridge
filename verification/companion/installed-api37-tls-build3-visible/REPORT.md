# Installed companion build 3 checkpoint

The tested Mac copy was `/Users/patrick/Applications/DroidBridge Companion QA.app`,
0.2.0/build 3, executable SHA-256
`d776356fa9c2fc671a79794880b8c3ebe3b22828fa5a5fafca3ee314808f2ad5`.
Its signed Android companion was code 6, SHA-256
`b17b6bcae25cb3549ec696a868675807aa93fc316ae1327bd8af9ede5dfc31f5`.
Only the handed-off `emulator-5582` was operated. The visible mode-700 QA root
isolates persistence, helpers, wrappers, broker, Keychain service and audio.
This checkpoint is not full-program release acceptance.

| Flow | Result | Executable evidence |
|---|---|---|
| Actual QR image picker | Pass | Previous old-root update directory `pair-comparison.json`: real CUA NSOpenPanel selection, matching comparison, phone Trust Mac; private QR deleted |
| Second isolated Mac trust | Pass | `actual-pairing.json`; strict pinned full-link path and phone approval; explicitly selected second trust on phone |
| Catalog label/icon update | Pass | `catalog-real-upgrade-delta.json`: same-signed Alpha v1→v2 changes label and Android-rendered icon hash, Beta unchanged; `updated-catalog-windowserver/` shows native refreshed search |
| Catalog deletion | Pass after bounded retry | `catalog-delete-attempt1.json` retained; `catalog-real-delete-delta.json` observes real Beta uninstall deletion; Beta restored afterward |
| Managed wrapper creation | Pass | Phone deselect/reselect generated two signed scoped wrappers; persisted actual export receipts and independent executions |
| Spotlight discovery | Not passed | Valid Application importer metadata, but real mdls/mdfind empty; even public standalone probe copy and existing installed apps in ~/Applications have no result. Public probe removed. System Calculator control succeeds; no global settings changed |
| First-run phone bootstrap | Fail; source remediation pending installed retest | Initial fresh-root phone Open rejected launcher_not_registered. Main-only registration now retries finitely in candidate source |
| Phone bootstrap after registered main quit | Pass | `phone-bootstrap-completion.json`, actual installed PID/QA args, native session log; `phone-bootstrap-status.png` shows Completed and favorite |
| Two independent native Mac applications | Pass | `two-native-windowserver-tiled/`: actual WindowServer capture of exact two owned windows, different processes/bundles/displays, original desktop positions; all foreign windows excluded |
| Real keyboard/mouse routing | Pass | CUA physical aa/bb, separate taps; raw `wrapper-*-raw-android.xml` includes actual edit text/counters. Settled resized Beta gets bbc and another tap. Direct NSView events were not used for these checks |
| Resize | Pass for native wrappers | Standard macOS Window → Move & Resize Left/Right; actual changed window frames and live Android layout. Early stale-layout coordinate click copied a sentinel instead of tapping; retained as attempt1 and repeated against fresh settled screenshot |
| Phone audio controls | Pass for routing/initialization | `actual-audio-screen-receipts.json`, native phone route, Mac ready, Retry Mac ready. No claim a silent fixture produced audible sound. Retry disabled on Phone route |
| Phone display off, live Mac input | Pass | Physical committed OFF parsed after CUA input, virtual Beta bbcd/taps3/keyDowns4; live motion frame and both windows in `phone-off-after-input-windowserver/`; native menu restored physical ON |
| Phone Stop All exact owners | Pass | Confirmation targeted two; `independent-stop-all-completion.json` contains two owner-bound stopped receipts; both wrapper subprocesses exited 0 |
| Clipboard, notifications/replies, 15/30/60 decoder rates | Pending | No build-3 completion claim; Mac→phone absolute-deadline clock skew blocked controls. New pinned clock-anchor candidate needs installed tests |
| Ad-hoc credential repair | Partial | Old-root update exercised unreadable credential, visible local Forget, phone revoke, fresh QR approval; balanced profile and empty selection retained. Nonempty selection retention across next update remains pending |
| Cold preview / paired video budget | Fail | Separate quiet ABBA report: preview paired p50/p95 226/504 ms and disconnected 207/388 ms (n5 each); first-video 1952/2759 vs1665/1967 ms. 100 ms cold and 10%/200 ms paired-overhead budgets remain failed |
| Fallback backend / actual Cmd+Tab surface | Pending this checkpoint | Distinct native app process/name/icon is observed; no new fallback or Cmd+Tab acceptance claim |

## Capture and privacy boundaries

The two-window screenshots use public ScreenCaptureKit with an including-windows
filter for exact handed-off PIDs and whitelisted synthetic window titles. They
preserve actual desktop positions; they are not composed from separate images.
The first overlapping capture is retained and is insufficient to show both
contents; the subsequent tiled capture does show both. CUA actions drive actual
Mac focus and keys, and raw Android hierarchies substantiate their results.
Phone screenshots are physical-display captures; uiautomator may instead choose
the focused virtual display, so those sources are identified separately.

No enrollment link, QR, bearer or Keychain value is included. Screen captures
contain only synthetic apps or companion UI. Main and both wrappers are closed;
zero native receipts remain. One deliberately connected scoped companion broker
and its exact forward remain for the next candidate (`final-runtime.json`).
