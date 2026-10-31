# Installed QA10 / Android12 verification

Owned host: `/Users/patrick/Applications/DroidBridge Companion QA10.app`; owned emulator `emulator-5582` only. Explicit isolated mode700 Final QA Data root, no production catalog/physical device operations. Product commit0b4b3e3; later footer presentation fix is source/component proof until final11 is installed.

| Gate | Result | Executable evidence |
|---|---|---|
| GUI bundled Android12 update | Pass | `actual-gui-android-update.json`, exact APKbc17d7b1275929f88ac445b5a2b99869982eabafa423eec53ae1c161e684db2b |
| Ad-hoc update / explicit fresh pinned pair | Pass with documented repair | `actual-pinned-pairing.json`; expected Keychaincredential_unavailable, user-facing localForget+exact old phone trustForget, fresh full URI/comparison/phone approval; unrelated two trusts preserved |
| Automatic catalog to main AND Companion | Pass | `automatic-catalog/result.json`: all5 package mutations have true before→after transitions withoutRefresh; Android completion→row335.80–855.45ms, observed broker token→row159.56–638.07ms |
| Actual icon replacement | Pass | `actual-automatic-icon-update.json`; four actual AppKit bitmap captures show blue square→green triangle on both UIs, authenticated icon SHA changes |
| Unicode catalog labels | Pass | `actual-unicode-labels.json`: exact86CJK scalars/258UTF8 bytes and255ASCII+emoji=256scalars/257UTF16/259UTF8 bytes appear in both shipping AppKit catalogs and authenticated catalog |
| Service force-stop recovery / independent video | Pass | `actual-service-recovery.json`, `service-recovery-session.jsonl`: companionoffline while same native session/main remains andresizes; actual video frames advance; publicphoneStart restores same trust/session |
| Actual emulator shutdown/cold relaunch recovery | Pass with explicit phone service restart | `actual-emulator-restart-recovery.json`, `emulator-recovery-native-session.jsonl`: same MacPID20973 survives, same trust/phone identity, automatic native replacementC9191C2F after transportloss, frames1→312, visible catalog restored. Android service is intentionally not boot-started; publicStart required |
| Native graceful session close | Pass | Actual shipping close action; exact final forward inspection onlytcp46000→37841, no scrcpy captureforward retained |

The coldboot helper first attempted ActivityManager immediately after sys.boot_completed and received nonzero; a later publicamstart succeeded. Initial service-off/startup connection error server_authentication_failed cleared after publicStart and normal retry. Initial Home receiver loading text did not mean lost trusts: Settings retained all3. No trust/pin bypass or re-pair occurred during recovery. The earlier `emulator-restart-pending-failure.json` is an intermediate investigation observation, superseded by actual recovered state rather than erased.

Unicode helper first had test-only row/API key assumptions; corrected private helper uses visible button titles plus text and public catalogitems. The CJK secondinstall was an update of the same already-addedfixture; its timing is not independent fresh-row propagation evidence. Five-mutation automatic catalog timing above is the valid transition cohort.

Boundary: screenshots here are actual shipping AppKit content-view bitmaps, not desktopWindowServer arrangements. Earlier actualtwo-native-window/focus tests and notification/file/clipboard tests remain separately version-scoped; they are not rerun claims for10. OS native notificationpermission remainedDenied, no reset/bypass or OS banner success claim. Actual Spotlight activation and SDL mouse-after-key automation remain unresolved host/tool acceptance limits described in parentreports.

Cleanup: owned native session closed; onlycompanionforwardtcp46000→37841 retained. Removed only two disposable Unicode APKs after proof, restored/retained AlphaV2 andBetaV1. Paired scoped broker, Balancedprofile andphone service retained for final11/performance handoff.
