# DroidBridge 0.1.2 build 6 verification

Implementation and installed-app acceptance passed. Independent QA approved the candidate for the physical-device handoff; see [QA review](qa/REVIEW.md). Physical Pixel and direct macOS switching/focus checks remain explicitly unverified.

The DMG was mounted and its app copied to `~/Applications/DroidBridge.app`. Final installed executable SHA-256: `4e2d3ca0666ba43c4199bac1dc9c40a17951b8cd1f23e863c4c12f707731be26`. [Release identities](release.json) bind production inputs, bundle seal, helper, installer and ZIP; [checksums](SHA256SUMS) cover the deliverables. The artifact is ad-hoc signed, with no Developer ID/notarization claim or public binary-release claim.

## Acceptance evidence

| Check | Result | Evidence |
|---|---|---|
| Final full unit suite | Pass: 73 tests, 4 explicit device-test skips, no failures | `unit-final.log` |
| Independent catalog correctness | Pass: 24 cases, including reproduced races and recovery | `qa/catalog-final.log`, `qa/REVIEW.md` |
| Shared preferences / monitor failures | Pass: bounded readiness, fairness, cancellation, feature-off, poisoned registration isolation | `unit-build5.log`, `unit-tests.log`, `qa/REVIEW.md` |
| Entire real Android catalog / icons | Pass: 16/16 updated, no errors, 20.52 s | `cohort.log`, `README.md` |
| Current-record resume | Pass: 16 current, 1.59 s | `cohort.log` |
| Cancellation and resume | Pass: bounded workers, accepted history retained | `cohort.log`, `qa/installed-ui-cancel/result.json` |
| Actual installed Add All / Cancel controls | Pass through public AppKit actions; max observed icon-helper children 2 | `qa/installed-ui-add/result.json`, `qa/installed-ui-cancel/result.json` |
| Actual installed decoration checkbox / Settings launch | Pass: new descriptor false and real decoded native video | `qa/installed-ui-add/result.json` |
| Managed disabled launch and Reopen | Pass: no denied Android start; enabling + Reopen gets a frame; second Reopen keeps one session | `qa/managed-reopen/result.json` |
| Running Android icon | Pass: running icon matches Launch Services rendering; Android PNG/ICNS comparison and generic-icon difference checked | `qa/managed-reopen/result.json`, `qa/managed-reopen/running-icon.png` |
| All managed entrypoints / intent preservation | Pass: 16 shipping-source cases; denied Restore, Retry and reconnect retain intent; Close and shutdown fence late work | `qa/managed-gates/results.json`, `intent-replacement.log` |
| Two managed native apps concurrently | Pass: Settings and Clock, distinct owned PIDs, decoded-running/visible window receipts, displays 1→3→1 | `concurrent-managed/result.json`, `concurrent-managed.log` |
| Owned-parent crash cleanup | Pass: exact forwards/display baseline restored; derived remote JARs absent and exact owned receipts removed | `concurrent-managed/result.json`, `offline-app-index.json` |
| Spotlight friendly names and independent device identities | Pass: actual metadata queries, signatures and cross-process reservation contention | `qa/managed-apps/`, `managed-apps.json`, `MACOS_CATALOG_REVIEW.md` |
| Full-cohort Spotlight availability | Pass: global exact-ID query 16 online → 0 offline, all 16 retained privately; observed 21.044 s including polling/indexing | `online-app-index.json`, `offline-app-index.json` |
| Final actual transport reconnection | Pass: booted dedicated emulator, all 16 automatically active/indexed again; stopped it and confirmed all 16 hidden/zero indexed again | `final-transport-reconnect.json` |
| Helper survives GUI/parent exit | Pass: per-user launchd process, PPID 1 | `helper-survived-parent.txt`, `helper-final-resource.txt` |
| Feature-off / helper SIGTERM / launchd restart / re-enable | Pass: no disabled ADB probes, bounded exit, new PID and all 16 active again | `final-agent.json` |
| Helper evidence exactness | Build 6 helper is byte-identical to tested build 5 helper | `helper-build6-identity.json` |
| Desktop decorations, backend A and B | Pass on Android 15 and 17: both values, actual video/input/resize and cleanup | `../desktop-mode/ANDROID_REVIEW.md`, `final-desktop-native35.log`, `final-desktop-external35.log` |
| Installer/runtime audit | Pass: strict signatures, 23 Mach-O dependency trees, isolated-PATH ADB/scrcpy/helper | `package-final.json` |

The four skipped unit-suite cases require explicit device opt-ins. They are not treated as passes; the actual device/frame/control/lifecycle evidence above is separate. Older build 3/4/5 artifacts are retained with their identities and supersession explained in `README.md`; they are not silently relabeled as build 6 tests.

## Correctness and performance review

Android and macOS experts implemented and reviewed their boundaries. Independent QA reproduced stale register/unregister ordering, foreign-path admission, lock shutdown, and lost Restore/Retry/reconnect intent, then required remediation and passing regressions. Initial failures remain in `qa/` and the evidence index.

A real roughly 60 MB runtime copied 29 files by APFS COW cloning, with zero full copies in the measured run. Free-space delta is an observation under concurrent filesystem activity, not a promised allocation size. Synthetic 1000-record catalog transitions take about 1.6–1.9 seconds in 16 bounded waves; those fixtures are not 1000 installed Android applications or 1000 real icon/indexing operations. Exact measurements are in the factory/performance JSON. The real 16-app cohort and installed UI observations are reported separately. The persistent helper's idle snapshot was approximately 11 MiB RSS / 0% CPU; this is not a peak-load guarantee.

Policy denies admission immediately, independently of delayed bundle moves or stale Spotlight results. Registration effects run outside catalog locks; bounded batched acknowledgements compensate stale effects without losing successor receipts. Poisoned or deleted bundles do not block healthy apps, foreign content is preserved, and an explicitly requested signed rebuild can repair missing owned bytes.

## Boundaries and final state

The Mac is locked. Public AppKit target/action and delegate calls exercise the actual installed application, and metadata queries exercise actual Spotlight indexing. Native receipts establish visible windows and decoded video; they do not establish physical keyboard focus or actual Cmd+Tab/Dock interaction. Partial cached UI bitmaps are not accepted as complete visual painting evidence. Layout geometry and real control execution are recorded separately.

No physical Pixel was attached. Use `PIXEL_VERIFICATION.md` for the owner's physical stage, including USB authorization, both backends, phone-screen independence and the new controls. Android app-drawn bars and IME are outside the system-decoration option.

Existing Dock bookmarks may follow a manually adopted wrapper into its retained private backup; the new per-device managed identity does not rewrite Dock preferences or legacy backup executables. Managed wrappers enforce availability; retained legacy standalone copies keep their previous behavior. A crash before publication can retain private unpublished COW staging bytes; automatic staging reaping is not implemented. Capacity refusal remains active, and accepted generations are retained.

The task-owned emulators are stopped and emulator5554 is preserved. The 16 accepted emulator wrappers remain in the private noindex store, ready for automatic restoration when that emulator returns. Only empty, test-owned public QA directories were removed; no unrelated application or user history was deleted.
