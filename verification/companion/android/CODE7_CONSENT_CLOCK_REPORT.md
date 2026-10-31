# Android code7 consent and clock checkpoint

Status: superseded by code8 after independent review found an unbounded admitted-outcome lifetime. Code7 actual27/27 tests passed in234.33seconds with the revised harness; this does not accept the full companion program.

## Frozen product

`/Users/patrick/workspace/DroidBridge/.build/companion-code7-candidate/DroidBridgeCompanion.apk`

Version0.2.0/code7; SHA256 `740fdf0aa9b8ea22522de07cc1d28a528aa822f26be5748d4b325cbf421e3bc8`; 2,859,547 bytes. Persistent local release signer `eb482305a29dfa3c7056f2a8eb6162eff9c123e2de6f85601284ca8967cd98c4` unchanged. Exact product source/APK hashes are in the candidate manifest. Offline notice assets byte-match source. Release compilation, unit tests and lint passed (`code7-final-build.log`).

API35 emulator5580 was upgraded using install-r from code4 to code7. `code7-upgrade-before.log`, `code7-upgrade-after.log` and `code7-upgrade.json` prove the device UUID, TLS leaf pin and clipboard/notification/profile settings remained unchanged. Existing app data was preserved; no uninstall or clear-data operation was used.

## Changes

Approval binds the precise pending pairing ID and throws for missing, dismissed, replaced or expired consent. The UI cannot report success from a silent no-op. File review performs no ContentProvider query, MIME lookup or open before approval; it names the recipient, counts generic file entries, and explains that names/sizes are checked afterward. Explicit clipboard Paste accepts only already-present text, bounds UTF16 before conversion and UTF8 to64KiB, and rejects URI/Intent clipboard items without coercing content or replacing the draft.

Protocol clock_anchor_v1 uses authenticated hello server_time (Unix seconds), server_uptime_ms and a process clock_epoch. New commands carry issued_uptime_ms/expires_uptime_ms in that epoch with a maximum30,000ms interval. Wall timestamps are diagnostic only. Pairing responses carry monotonic expiry; the phone retains its real120-second consent window. Completed canonical request receipts survive epoch changes without replay. Old queued work expires on process restart; accepted/admitted work becomes unknown. Receipt retention uses Android boot count/uptime rather than mutable wall time. Admitted effects may finish late truthfully; unadmitted expired work cannot begin.

A committed Spotlight selection with pending wrapper materialization is displayed as saved/pending, with explicit retry. Retry admits a successor UUID/revision and never replays or rewrites the old receipt.

## Runtime evidence

The first27-test run exposed asynchronous Android ClipboardService MIME classification after setPrimaryClip. The production Paste path contains no provider calls. The failed run is retained in code7-api35-full-attempt1.log. The revised harness completes and observes the platform setup classification before measuring Paste; it still requires no query/open during setup and no additional query/type/open during Paste. The product APK was not changed. Revised signed test APK/source binding is in .build/companion-code7-harness2/manifest.json.

## Platform boundary

Tests use only owned emulator5580; physical Pixel/user emulator5554 and Mac-owned5582 are untouched. Root restored USB debugging using the emulator UI after a prior lab settings restore had disabled it. Tests must preserve developer settings1/adb_enabled1 and may not restore the destructive old null/0 state.

S07 provider cancellation remains bounded admission rather than an absolute guarantee against arbitrary hostile Binder implementations. Actual pipe/read and cancellation-aware query fixtures exercise30-second deadlines. A provider that ignores cancellation may retain one of the two worker slots until it returns; no slot is released early. The public installer metadata lookup separately checks an elapsed10-second budget between network steps with per-I/O timeouts, not a strict absolute10-second promise.

## Superseding review finding

Root independently found that admitted commands could occupy all32 slots forever if the Mac disappeared. Code7 is not the release candidate. Code8 persists first admission uptime/epoch, retires unresolved admission after120seconds to immutable unknown, and prevents duplicate admission from refreshing the limit. It also durably journals queued/accepted expiry. Code7 evidence remains preserved; code8 requires its own full runtime/large-text gate.
