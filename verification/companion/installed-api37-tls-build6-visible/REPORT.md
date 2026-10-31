# Installed build 6 — actual API 37 functional checkpoint

The installed copy is `/Users/patrick/Applications/DroidBridge Companion QA6.app` (0.2.0/build6), copied from the read-only installer. The exact host/broker/APK hashes and independent deep strict signature result are in `installed-identity.json`. Only emulator-5582 and the explicit private QA data root were operated. This checkpoint predates the notification trust-origin hardening and Android 11 release.

## Executed results

| Boundary | Result | Evidence |
| --- | --- | --- |
| Actual GUI installs bundled Android 9, opens companion | Pass | `initial-gui/` preparation log; not an acceptance claim by itself |
| Full pinned pairing URI, matched comparison, explicit phone approval, authenticated poll | Pass | `actual-update-pairing.json`, `authenticated-companion-window.png` |
| Existing nonempty exports and balanced profile survive local Forget and fresh approved pairing | Pass | `actual-authenticated-retention.json`; before snapshot under build5 |
| Mac checkbox disables and recreates owned Alpha wrapper | Pass | `actual-mac-export-receipts.json`: exact owner admission, inactive/active canonical receipts, build6 copied wrapper |
| Cold independent wrapper, main GUI quit, Battery/Responsive/Balanced configured caps | Pass for configured policy and real motion | `cold-wrapper-*.json`, `existing-session-keeps-15fps.json` |
| Explicit clipboard round trip | Pass | `phone-clipboard-actions.json`: real Mac Copy/Send Clipboard, phone Copy/Paste/Send, received Mac Copy, exact synthetic pasteboard match; original Mac clipboard restored |
| Android Share Intent -> named consent -> native Mac save panel -> actual file | Pass | `real-phone-to-mac-file.json`: 2 MiB exact SHA-256 |
| Native Mac open panel -> phone verified inbox -> explicit Android SAF save | Pass | `real-mac-to-phone-file-ui.json`, `real-phone-file-explicit-save.json`: identical 2 MiB hash |
| Android listener permission, global opt-in, selected trust only | Pass | `notification-scope-setup.json`; fixture-only allowlist set through public broker API, separate from blocked Mac banner prompt |
| Mac in-app reply -> actual RemoteInput receiver, exactly one delivery | Pass | `notification-real-reply.json` |
| Public notification replacement and non-reply actions | Pass | Actual CUA showed generation2 replacing1, generation4 had no Reply; raw private-replacement report includes prior item |
| Mac Dismiss -> actual Android notification removed -> broker row removed | Pass | `notification-real-dismiss.json` |
| Private replacement text excluded, obsolete reply rejected | Pass for exclusion/rejection; stale public UI bug | `notification-private-replacement-bug.json`: no generation3 content, delivery count stays1, obsolete public generation2 row incorrectly remains |
| Mac native notification banners | Unverified, permission denied | `mac-notification-permission-after-request.json`; no permission bypass/reset |
| Fallback real video and keyboard | Pass | `fallback-input-raw-android.xml`: `fb`, two key downs, display43, no IME |
| Fallback normal-hover mouse on API37 | Fail, root cause isolated | `fallback-input.json`: repeated CUA clicks produce0 taps |
| Pinned fallback with supported `--no-mouse-hover` | Diagnostic pass | `fallback-no-hover-diagnostic.json`, actual display44 receives1 tap; parent owns integration |
| Spotlight UI search/activation | Blocked | One exact Apple UI-process restart and normal open succeeded, CUA remains unable to bind its UI; `spotlight-ui-restart.json`. No index/privacy setting change. |

## Frame-rate measurement limits

Three fresh independent wrapper processes were launched after quitting the main GUI. The actual native descriptor ceilings were15,60,30. Sustained decoded counts under visible Android motion measured14.94fps over32.53s,34.72fps over55.01s, and25.52fps over30.06s, respectively. Existing15 and60 windows retained their ceilings after changing the policy for new windows.

The original diagnostic files retain `passed:false` where the test helper imposed an invented one-second arrival ceiling or a minimum36fps for Responsive. These are not encoder-PTS measurements or product guarantees. The bounded frame mailbox aggregates counts when the MainActor drains; one-second arrival bursts therefore cannot prove a strict encoder ceiling. Responsive is advertised as up to60, with actual rate dependent on Android/host/content. No60fps delivery or battery-savings claim is made. The release coordinator and independent reviewer accepted configured policy plus sustained observed effect as the appropriate scoped evidence. Thresholds were not silently increased.

## Later source remediation, not installed build6 proof

The source now fences delayed notification authorization by intent, cancellation, window close/reopen, selected phone and exact trust; checks edited allowlists; fences deferred settings/add callbacks and retracts only exact stale notification IDs; and treats old/missing-origin inbox rows as readable but inert. Actual shipping AppKit plus anonymous NSXPC regressions pass under `macos-ui-notification-origin-fences/`. These use injected OS callbacks and do not grant notification permission or prove installed banners. Final packaging must include the coordinated Core/Android trust-scope protocol and receive its own smoke test.

No raw pairing URI, credential, Keychain value, or incidental file-picker screenshot is included. The synthetic clipboard restoration snapshot was deleted after restoring all original types. No physical device, production catalog, unrelated phone trust, or user's emulator was modified.
