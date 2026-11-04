# Android backend/UI contracts

`MainActivity.kt` is owned by the mobile UX agent. The backend exposes the following
application-private Kotlin APIs; none is an exported Android component or bypasses
HTTP authentication.

- `phoneCommand(kind,payload,recipientTrustId?) -> String`: returns an admitted
  request UUID. It does not imply that the Mac applied anything. A bounded encrypted
  journal retains32 outcomes and pending commands across service/app restart.
  Commands expire after30seconds; exhausted active/byte capacity is refused.
- `commandOutcomes() -> JSONArray`: request_id,kind,trust_id,status,created_at,
  expires_at,error_code. Status is queued/accepted/applied/rejected/unknown/expired.
  Original payloads remain encrypted and are omitted from this UI projection.
  Optional `timing.acknowledged_ms` and `timing.completed_ms` are elapsed durations
  from local admission within the same monotonic process epoch. Missing durations
  remain unavailable. Preset results retain phase, completed_steps and failed_step
  when supplied; an absent completed_steps is not zero.
- `peerStatus(trustId = selectedTrust())`: exact trust_id/mac_name, connected, sessions, and optional
  last_seen_at/audio_route/audio_status/profile. Connected requires a fresh
  authenticated per-trust state heartbeat within15seconds and a running service.
  Service running alone does not mean a paired Mac is connected.
- `catalogRevisionLocal()` and `catalogLocal()`: selected-trust cached immutable
  generation and launcher items. Call the generation getter before mapping the
  catalog again. Cache keys include the base catalog and per-trust selection
  version; unchanged polling does not serialize/render thousands of rows.
- `chooseExport(package,selected,trustId) -> String`: persists a phone command and
  returns its request UUID before local selection update. `set_export` and
  `catalog_preferences` include monotonic per-trust selection_revision and origin
  request_id. Local phone choice is distinct from acknowledged Mac publication.
- `receivedTexts()` and `clearReceivedText(eventId)`: selected-trust received text,
  max8 items/512KiB encoded aggregate/30minutes, encrypted at rest. Getter includes
  event_id,trust_id,created_at,text. Receipt never changes Android's clipboard;
  Copy is an explicit foreground user action. Event journal carries metadata only.
- `transfers.stage(contentUri,recipientTrustId,batchId?,onProgress)`: pins the confirmed
  recipient before reading. `staged_bytes` is local preparation; outgoing
  `accepted_bytes` is independently confirmed remote receipt, initially zero.
- `transfers.listLocal()/cancelLocal(id)`: states staging/ready/receiving/received/
  downloaded/cancelled/failed; max2 active,50MiB each,100MiB staged,32 history,
  30minute expiry. A shared scheduler enforces a 30-second preparation budget:
  cancellation signals provider query/open and closes the registered stream on a
  bounded background executor. Read/EOF and publication checks refuse timed-out
  partial content. At most two staging reader slots remain admitted until their
  workers actually exit; an uncooperative provider cannot free its slot early.
  Android cannot force a provider Binder query/type/open implementation to honor
  cancellation. Such a call may retain its bounded worker until it returns; the
 30-second budget is not an absolute guarantee for an arbitrary provider. Received
  files require explicit Android Save; none is executed.
- `snippets()/saveSnippet(text,sourceTrustId?)/pinSnippet(id,pinned)/deleteSnippet(id)`:
  explicitly saved encrypted content, separate from the expiring inbox. Maximum
  64 snippets, 64 KiB per text, sharing a 512 KiB aggregate journal with presets.
  Saving commits the new journal before exposing it to readers. Clipboard reads
  and writes remain explicit foreground actions.
- `presets()/savePreset(name,packages,trustId,audioRoute,profile,screenOff)/deletePreset(id)`:
  at most eight named presets, each with one exact trust and one to eight distinct
  packages. `runPreset(id)` admits one `run_preset` command with one durable receipt;
  it does not submit independently replayable child commands. Partial completion
  retains earlier effects and requires inspection before a new explicit run.
- `libraryRevision()` is a cached content fingerprint. Read it before mapping
  snippets/presets so unchanged UI polling does not serialize the library.
- `transfers.shareUri(id)` validates a complete, verified inbound transfer and
  returns an application-specific `content://` URI. The read-only provider uses
  temporary recipient grants; cancellation/expiry refuses subsequent opens.
  `batch_id` groups independently verified transfers without changing byte,
  concurrency, expiry or receipt limits.

For `share_text` and `share_url`, `action` is `send` (default inbox delivery),
`copy` (explicit Mac clipboard effect) or, for valid HTTP(S) URLs, `open`.
The named recipient is captured inside the share flow independently of dashboard
selection. Mac copy/open effects require durable owner admission; receiving an
ordinary share does not automatically modify the Mac clipboard or open content.
Selected-text, tile, shortcut, widget and notification entry-point contracts are
documented in [Quick access](../docs/companion/QUICK_ACCESS.md).

Mac download completion is acknowledged by authenticated
`POST /v1/transfers/<id>/receipt` with request_id,status downloaded,accepted_bytes
exactly equal to size and complete sha256. An optional status receiving reports
monotonic progress. The phone must not label a local staged file as delivered.

Phone-to-Mac commands are trust-targeted event entries. Mac sends
`POST /v1/commands/<UUID>/receipt` with the same request_id and a stable terminal
result. A wrong trust is denied, identical terminal retry returns the stored
outcome, conflicting terminal reuse fails409. Queued commands recovered after
restart keep their original UUID and deadline; an epoch reset requires Mac resync
and its own durable deduplication before effects.

Mac-to-phone commands use a separately persisted hash/result receipt before effects;
an uncertain effect never runs again automatically. Canonical JSON order is used,
receipt capacity refuses admission without evicting live identities, and expiry
prevents replay after retention. Notification reply/dismiss requires the current
notification/action generation and current permission. Public notification sharing
and package filters are per approved trust, separately from Android listener access
and the phone's global opt-in.

TLS1.2/1.3 and the QR-conveyed exact DER-leaf fingerprint authenticate the local
server before any HTTP; no plaintext fallback exists. All HTTP reads have a five-second absolute deadline, JSON262144/header16384 byte
caps and bounded JSON nesting/node count. One longpoll may occupy a worker; bulk
chunks are64KiB. Bounded writes are closed after five seconds. Closing the service
closes queued/live owned sockets. Raw icon/file responses and longpolls recheck
current trust before emitting bytes. No raw LAN listener or arbitrary shell route
is available.
