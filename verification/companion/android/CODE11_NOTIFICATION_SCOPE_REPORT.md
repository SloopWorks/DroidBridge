# Android code11 notification privacy and trust checkpoint

Status: frozen candidate2 focused3/3 passed14.07seconds and full34/34 passed282.426seconds on actualAPI35. Large9/9 passed48.715seconds at320dp/200% text. This report does not accept the full companion program.

## Exact artifact and failed attempt

Use `.build/companion-code11-candidate2/DroidBridgeCompanion.apk`: version0.2.0/code11, SHA256 `6fa302dd74bd42d67a4bcc88a9970c8079af880a376263ca3ff42584ef809029`, 2,869,727bytes. Signed test SHA256 `c479b2cc67981ea27a58c150172f5edfe44599612bfbc9596ea0604d47c5c150`. Persistent local signer unchanged (`eb482305a29dfa3c7056f2a8eb6162eff9c123e2de6f85601284ca8967cd98c4`). Exact source/APK hashes are in candidate2 manifest. Runtime notice bytes match and fixture/provider classes are absent from productDEX. Release build/unit/lint passed. MainActivity is unchanged from code10.

First candidate `af6d6feb1099fb9e4a0aa41d35f6365c7d56a22926ee7181b26bcf731778219f` and focused attempt1 remain preserved and rejected. Actual listener initial replay encountered Android's internal single-segment package `android`; strict app-package validation incorrectly ran even for excluded/null cleanup and crashed MainLooper. Candidate2 validates the hash for all cleanup, validates app-package syntax only for content, and explicitly excludes internal/non-app package names from content publication. It does not weaken launch/package command validation. The regression includes framework-package excluded cleanup.

Crash recovery disallowed only the owned listener, force-stopped only the owned companion, revoked only testAPK notification permission, and used an explicit test-only runner argument to remove at most two exact named fixture trusts. That cleanup refuses any unrelated trust. No uninstall, data reset, physical device or sharedADB mutation occurred.

## Privacy lifecycle and bounded resources

The Store owns at most256 active key records, each with at most8 current recipients and response-selected recipients plus package/action generation. It retains no notification content in that index. A generation is considered exposed when selected into an authenticated response, not proof that networking completed. An in-flight response admitted before a permission change cannot be absolutely retracted.

Private/ongoing/foreground/own/non-app replacements remove old actions and enqueue only a key-only notification_removed to the previously selected audience. Global opt-out, per-trust opt-out, package filtering, listener loss and bounded eviction perform the same cleanup. Never opted-in and queued-but-never-selected recipients learn no removal existence. Current content requires the current recipient, package grant and latest action generation; stale queued public generations are suppressed. Cleanup has a private internal marker, bypasses content opt-in only for its exact prior target, and the marker is stripped from wire output.

On overflow, prior selected recipients receive cleanup before the oldest key is forgotten. Journal count/byte bounds remain unchanged; a large cleanup burst that exceeds retention reports reset_required so Core clears stale active rows. Store process/epoch loss has no durable exposure history; Core must clear active notification rows on epoch discontinuity or authentication failure, then rebuild only from fresh events. A listener reconnect invalidates action generations and replays at most256 current eligible public notifications to currently authorized recipients.

The action cache is a locked LinkedHashMap capped256. It retains source key/posttime/action capability and opaque generation, never StatusBarNotification or its body. No audience means no action retention. Last-scope removal/eviction clears actions. Store→replyLock has no inverse acquisition; listener releases replyLock before entering Store. Long polls wait without the Store monitor, then bounded filtering uses Store→eventLock. Each publication/reconciliation/clear uses one fresh trusted snapshot rather than decrypting per key×recipient. No long-lived plaintext credential cache was added.

## Exact trust and input boundary

Hello advertises notification_scope_v2. All notification_preferences, notification_reply and dismiss_notification payloads require canonical expected_trust_id equal to the actual authenticated trust. Under the Store monitor, this check precedes receipt lookup/hash/effects. Missing, malformed and mismatched scope returns409trust_changed. Canonical hash already binds the whole payload and authenticated trust; rewriting the field cannot replay a UUID under another trust. Old phone capability is refused by Core rather than silently weakening scope.

Current per-recipient exposure/action generation and actual Android notification eligibility are checked before effects. Reply input is bounded before durable admission and again at the sink to1..4096UTF8 bytes, with a UTF16 prebound. Notification preview limits remain256UTF16 title units and4096UTF16 body units, separately constrained by event JSON/aggregate byte caps; these are not claimed as4KiB body previews.

## Executed focused evidence

`code11-api35-focused3-attempt2.log` records3/3 actual tests14.07seconds. An ordinary separate testAPK UID posts public/private/ongoing notifications and receives RemoteInput through its unexported receiver. Only synthetic delivery counts/generation are stored; reply contents and credentials are never logged. Actual Android NotificationListener and pinnedTLS command/event endpoints prove public→private cleanup, two-recipient ongoing cleanup, opt-out/filter/global/listener loss cleanup, fresh reconnect generation, actual scoped dismissal and revoked credential401. Each cleanup assertion requires a sequence newer than the observed public row; an earlier removal cannot make it pass.

Missing/wrong/malformed expected trust is rejected for all3 command kinds before any reply/dismiss/preference effect. Real reply4097UTF8 bytes produces400 with0deliveries;4096 multibyte bytes delivers exactly once, including canonical retry. Cross-trust and replacement-trust replay fail. Never-exposed recipient receives no notification event. The isolated overflow test also proves a public generation queued then excluded before any GET reveals no key-only cleanup existence.

The full256-key×8-trust matrix is admitted through realTLS event pages. Global opt-out reconciliation measured21ms against a3000ms gate. Overflow cleanup, explicit journal gap and simultaneous waiting poll/publication passed. That measurement describes this emulator cohort, not an absolute worst-case performance guarantee.

## Full actual signed suite

code11-api35-full34-attempt1.log records34/34 passing282.426seconds against the same candidate2. The actual256×8 matrix reconciled27ms; NotificationListener/ordinaryUID/scopedcommands/reply delivery/privacy transitions passed again. Actual120,353ms pairing/admission test preserved unknown/late-completion boundaries. Stalled pipes30,022ms, cancellable query30,010ms and explicitcancel6ms recovered capacity. Native uncertainty30,124ms created no successor UUIDs. Canonical pairing-wire identity and TLS1.2/1.3 stability/wrongpin/plaintext tests passed; upgrade evidence retained the same UUID/pin and settings with code11. This is an exact full34 execution, not an inherited earlier-version suite.

## Final baseline and remaining gates

code11-api35-large9-attempt1.log passed9/9 at320dp/200% text48.715seconds, including real30,179ms uncertainty/no successor and610ms no-provider-I/O review. All candidate2 source hashes still match; actual installed base.apk SHA256 equals the frozen product. Code10→final11 upgrade preserved device UUID/TLS pin/settings, bound in code11-upgrade.json. All release notices/test isolation checks remain valid. docs/companion/ANDROID_CAPABILITIES.md records the new boundary; SCRCPY_HOVER_REVIEW.md records the separate read-only recommendation owned by root.

All tool cells completed. Owned emulator5580 is force-stopped/serviceOFF, physicaldensity420/nooverride, font1.0, intentional developer1/ADB1/wirelessdebug0 preserved. The owned notification listener is disabled as before and the testAPK posting permission restored. Exact test trusts/receiver restored; no new ADB forwards, aliases or emulator lifecycle changes. Root AVD session75348 remains running. This agent did not operate Pixel, user5554 or Mac-owned5582, and made no gitcommit/push. Root receives exclusive runtime next for installed performance/quiet-cohort work; no more Android agent runtime operations after handoff.

Independent security binding, installed Mac final-package/API37 interoperability, release distribution and physical Pixel acceptance remain root's separate full-program gates. The failed first11 candidate is retained and is not releasable; candidate2 is the only accepted Android artifact in this checkpoint.
