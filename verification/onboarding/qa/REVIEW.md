# Independent onboarding QA review

Reviewed candidate: **DroidBridge 0.1.2 build6**, installed from the final DMG outside the build directory. Installed main executable SHA256:

`4e2d3ca0666ba43c4199bac1dc9c40a17951b8cd1f23e863c4c12f707731be26`

The independent review found and reproduced release-blocking ordering, cancellation and ownership defects. Their regressions now pass. The final installed controls and managed wrapper were exercised against actual Android sessions; compilation was not used as a substitute for execution. **Verdict: approved for physical-device handoff, with the explicit UI limits below.** No further blocker remains in the reviewed onboarding paths. I inspected the lead’s final concurrent managed-window and global offline-index evidence as well as the resulting durable catalog.

## Executed evidence

| Check | Result | Evidence |
|---|---|---|
| Catalog race/ownership/repair regressions | Pass, 24 tests | `catalog-final.log` |
| Availability fairness, flag changes, poison isolation | Pass, 7 tests | `monitor-final.log` |
| Flag-off and stale-generation managed admission; retained Restore/Retry/reconnect intent; explicit Close and shutdown | Pass, 16 shipping Launcher cases | `managed-gates/results.json` |
| Packaged helper held-lock cancellation | Pass, 63 ms while the foreign lock remained held | `catalog-lock-final.json` |
| Packaged helper uncancelled busy refusal | Pass, 319 ms while the foreign lock remained held | `catalog-lock-final.json` |
| Signed managed factory, independent device identities, same-key cross-process admission | Pass; exactly one success and one busy refusal | `managed-apps/managed-apps.json`, `managed-apps/worker-a.log`, `managed-apps/worker-b.log` |
| Actual friendly-name Spotlight online/offline discovery | Pass; 0.75 / 0.12 seconds | `managed-apps/managed-apps.json` |
| Runtime COW copy | Pass; 29 files cloned, none copied, 59.7 MB logical and observed 16 KB filesystem free-space delta | `managed-apps/managed-apps.json` |
| Synthetic 1000-record transitions | Pass; 16 waves each direction, 2.04 s online / 1.86 s offline; largest reconcile 95 ms, batch acknowledgement 56 ms | `managed-apps/managed-apps.json` |
| Actual Add All and Cancel button target/actions | Pass; cancel at 4/16 attempts, two accepted upgrades preserved, all 16 accepted records retained; maximum observed icon-helper children two | `installed-ui-cancel/result.json` |
| Exact installed Add All resume, real decoration checkbox and Launch App controls | Pass; 2 upgrades + 14 current, zero errors; all wrappers restored to build6; Settings decoded a real native frame; the newly launched descriptor pinned decorations=false | `installed-ui-add/result.json`, its session JSONL |
| Exact managed wrapper flag-off denial, enabled Reopen, repeated Reopen | Pass; no Android start during denial, then one live native Settings session; repeated Reopen presented that same session | `managed-reopen/result.json`, its session JSONL |
| Managed process name, regular application identity and actual Android icon | Pass; name Settings, regular identity; running icon matches its LaunchServices rendering exactly, ICNS versus Android PNG mean error 0.145, difference from generic host 55.56 | `managed-reopen/result.json`, `managed-reopen/running-icon.png` |
| Managed wrapper payload/signature | Pass; strict signature; normalized unsigned executable equals exact installed host | `managed-reopen/result.json` |
| Native wrapper normal quit cleanup | Pass; forwards/reverse mappings and one-display baseline restored | `managed-reopen/result.json` |
| Final default catalog and preferences after QA | Pass; 16 accepted wrappers, all active/build6; no reservation or publication; original true/true preferences restored; availability helper running | `final-state.json` |
| Two exact final6 managed native apps concurrently | Pass; distinct process/bundle identities, both decoded-frame/visible-window receipts; display count1→3→1 and exact forward baseline restored | `../concurrent-managed/result.json` |
| Global Spotlight after real emulator shutdown | Pass; exact16-ID query16→0 in21.04s; all16 accepted build6 wrappers retained inactive/noindex; original emulator5554 preserved | `../offline-app-index.json` |
| Launcher geometry at default, minimum and long status | Pass; all 13 inspected controls within content bounds | `ui-layout.json` |

At QA release, the catalog was online as recorded in `final-state.json`. The lead subsequently stopped only the two dedicated test AVDs; the final handoff catalog is intentionally offline:16 accepted build6 records are inactive/private, with no reservation or publication. This final offline state was independently checked after reading the lead’s evidence.

The helper in build6 is byte-identical to the tested build5 helper (`f6b529516819ee843b3547ba668ef2fb018cd07a3749ea2a66fdabb1d86742fd`), so its executable lock test remains exact. The lead independently reran actual API35 native and external desktop-mode streams with both decoration flags; those results are outside this subdirectory in the final desktop verification logs.

## Reproduced defects and remediation

- Late unregister could land after a newer register and leave an active application absent from LaunchServices. Symmetric compensation now retains a current register receipt. Duplicate and superseded-generation completions are covered.
- A queued unregister could act on foreign replacement bytes at the originally owned URL. Dispatch now verifies current ownership; foreign sentinel data remains untouched.
- A held catalog flock prevented SIGTERM cancellation from completing. Catalog, preference and onboarding admission locks now use bounded cancellable acquisition; catalog descriptors use close-on-exec.
- A poisoned registration precheck could abort a wave before healthy effects were acknowledged. The precheck is now inside the per-action error boundary; earlier and later healthy receipts are acknowledged.
- Managed denial correctly stopped Android admission but discarded saved Restore, Retry and disconnected reconnect intents. Replacement now keeps the predecessor until a successor is admitted, checks exact ownership after awaits, and tracks Restore admission through shutdown. The strengthened fixture first reproduced eight retention failures, then passed after remediation.

Initial failures are retained in `stale-unregister-initial.log`, `foreign-unregister-initial.log`, `catalog-lock-initial.json` and `managed-gates/retained-intents-initial-all.log`. The separate initial fake-tool harness failure classified read-only `--list-apps` as a capture launch; that instrumentation was corrected and is not a product defect.

## Scope and limitations

The installed UI tests use public AppKit `performClick` and the public application-delegate Reopen method. Cancellation uses a metadata-only COW copy with valid numeric build999004 to force real upgrade work; its unsigned executable is byte-identical to the final installed executable. Exact installed Add All subsequently restores every accepted wrapper to build6. The Reopen test briefly pauses only the task-owned availability helper to keep the canonical public path present for a denied launch, then always resumes it and restores exact preference/session bytes.

The desktop is locked. Native receipts show `visible=true` but `app_active=false` and `key=false`; these tests do **not** prove physical OS focus, direct Cmd+Tab/Dock clicks, or complete visual control painting. Cached UI bitmaps paint only part of the native controls and are not full visual-readability evidence. Geometry and actual target/action execution are separately verified.

The 1000-record timing uses metadata fixtures; it does not claim 1000 real Android applications were copied, signed or indexed. Filesystem free-space change is an observation on this APFS host, not a fixed per-wrapper allocation promise. A crash before publication may retain private unpublished COW staging bytes after a dead reservation is replaced; automatic staging reaping is not implemented and capacity refusal remains active. Accepted histories are retained. This limitation does not imply an Android process or virtual-display leak.

Physical Pixel behavior and direct macOS switching remain the external acceptance stage. No emulator result is presented as physical Pixel verification.

## Reproduction

Run from the repository root after `swift build`. Runtime tests require exclusive ownership of default preferences, the managed catalog/helper and emulator5580; they preserve accepted history but intentionally upgrade the task-owned managed cohort.

```sh
swift test --filter ManagedAppsTests
swift test --filter ManagedAvailabilityMonitorTests
python3 verification/onboarding/qa/verify-managed-gates.py
python3 verification/onboarding/qa/verify-isolated-catalog.py
python3 verification/onboarding/qa/verify-installed-ui.py "$HOME/Applications/DroidBridge.app" --mode cancel
python3 verification/onboarding/qa/verify-installed-ui.py "$HOME/Applications/DroidBridge.app" --mode add
python3 verification/onboarding/qa/verify-managed-reopen.py
```
