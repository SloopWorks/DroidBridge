# Companion boundary contract — v1

Status: draft under systems, UX and security review, coordinated by the technical lead. This
document describes the target, not evidence that a feature has shipped. Runtime
and release acceptance are recorded separately.

## Transport and authority

The Android companion is an ordinary user-installed APK. Existing ADB/scrcpy
remains responsible for trusted virtual displays, video, input, screen power and
device-wide audio. Installing the companion does not grant those privileges.

The companion listens only on Android loopback `127.0.0.1:37841`. The Mac creates
an exact-owned, explicit-serial ADB forward to that port, using a cross-process
leased host port and no-rebind. All application requests use TLS 1.2/1.3 with
an installation-stable Android Keystore P-256 server key. The exact leaf DER
SHA-256 is pinned from the phone's pairing link or the Mac's approved Keychain
record before any HTTP request bytes are sent. ADB encryption alone does not
authenticate the Android app owning a loopback port; plaintext HTTP, TOFU and
pin discovery from hello are forbidden. See security finding S13.
USB and Android's paired wireless-debugging ADB connections use the same protocol. v1 does not expose a plaintext
LAN listener. A future direct LAN transport requires authenticated encryption
and an independent security gate; a bearer token is not encryption.

One per-user persistent Mac broker synchronizes a device. Independent app
wrappers retain their existing fast ADB startup and shared audio authority. A
companion cannot operate an unverified serial or execute arbitrary shell commands.
Explicit per-app export choices become revision-fenced inputs to the managed
catalog, which combines them with authorized Android readiness for Spotlight
admission. Before publishing a choice, the Mac verifies the updated availability
helper; catalog version 2 permanently fences legacy writers that ignore choices.

## Protocol envelope and admission

HTTP/1.1 requests have a 5-second connect/read timeout (30 seconds for explicit
file transfer), JSON UTF-8, a body limit of 262,144 bytes and a 16,384-byte header
limit. Reject chunked HTTP transfer encoding unless the server implements a
bounded streaming decoder. Reject duplicate Content-Length, invalid UTF-8,
unknown protocol majors and malformed paths before dispatch. No redirects.

All successful JSON responses use `{ "protocol": 1, "request_id": "UUID",
"data": {...} }`. Errors use `{ "protocol": 1, "request_id": "UUID",
"error": { "code": "stable_snake_case", "message": "bounded explanation",
"retryable": false } }`. Request IDs are caller-generated UUIDs, accepted only
as identifiers, never as paths or executable arguments. Additional object fields
are ignored within a compatible major; required fields and all bounds fail
closed. HTTP status codes carry errors too: 400 malformed, 401 unauthorized,
403 capability/permission denied, 409 stale cursor/conflict, 413 too large,
429 admission capacity, 503 transient unavailability.

All routes except hello and pairing require `Authorization: Bearer <token>`.
Use constant-time credential comparison; never log credentials, shared content,
clipboard data, notification bodies or file names. Normal diagnostic counters
include only route, status, elapsed duration, byte count and a random request ID.

## Pairing and trust

`GET /v1/hello` returns `device_id` (random installation identity, not hardware
serial), `device_name`, `protocol_min`, `protocol_max`, `capabilities`, and
`pairing_available`. The response is bounded to 8 KiB. The transport's explicit
ADB serial is independently retained by the Mac; a hello cannot change it. The
paired installation identity is canonical: USB and wireless serials become
verified aliases only after the saved/QR-pinned TLS connection and authenticated
`GET /v1/identity` prove the same installation and approved trust identity.
Changing transport interrupts and reconstructs sessions; no gapless migration is
claimed. Release requires device-level alias fencing for capture/audio admission
across known USB/Wi-Fi aliases. The current broker refusal while registered
sessions are live is partial protection: it does not yet fence direct ADB-only
wrapper starts through an unregistered second alias. Do not report that case as
passed until session/audio/supervisor admission and crash cleanup prove it.

The phone user explicitly opens a two-minute pairing window. Android generates
a cryptographic 32-byte secret. The UI presents a QR and copyable complete URI
with exactly `secret`, `expires`, `device_id` and `server_pin` query fields. The
pin is 64 lowercase hex characters over the exact DER leaf. Bare-secret pairing
is rejected. A short comparison code helps identify the same attempt but is not
a credential. A screenshot of the QR grants pairing during that short window.

`POST /v1/pair`: `{ "request_id": "UUID", "pairing_secret": "base64url",
"mac_id": "UUID", "mac_name": "bounded display name" }`. Android admits at most one pending attempt, returning202 with
`pairing_id`, `status: pending`, and `expires_at`. The phone user must explicitly
approve the displayed Mac name and comparison code.
`GET /v1/pair/<pairing_id>` with `Authorization: Pairing <secret>` returns pending
or approved with `credential` (new random32 bytes), `trust_id` (UUID), `device_id`,
negotiated `protocol`, and `capabilities`. The pending request expires with the
120-second pairing window; wrong IDs/secrets fail closed. Identical approved polls
return the same result until expiry, permitting recovery after a lost response.
New pairing consumes the capability; no second Mac can use it.
Maximum eight trusted Macs. Pair attempts are limited to five per minute and a
window closes after five invalid attempts. A new pairing does not overwrite a
different trusted Mac. Mac credentials are stored atomically with the installation
UUID, trust UUID and server pin in one validated Keychain record. Legacy pinless
records require explicit re-pairing before network access. Android trust lives in
app-private encrypted storage backed by AndroidKeyStore; never plain preferences.

`GET /v1/trust` lists bounded trust IDs/names/last-used times, never credentials.
`DELETE /v1/trust/<trust_id>` revokes that trust immediately. The phone can revoke
one or all Macs without a connection. Every new request checks current trust;
in-flight transfers check again before commit. Uninstall/reset removes trust.

## Capability and permission model

Hello/pair expose supported capabilities separately from granted permissions.
Expected keys: `catalog`, `icons`, `commands`, `sessions`, `share`, `clipboard`,
`notifications`, `notification_replies`, `profiles`, `diagnostics`, `delivery`,
`state_heartbeat`.
A missing capability disables its controls, with an explanation. Notification
access, Android posting permission and any runtime permissions are user-granted;
pairing does not grant them. No automatic clipboard polling or content upload.

## API shapes

* `GET /v1/catalog?cursor=<opaque>&limit=64`: `generation`, `items`, `next_cursor`.
  Each app: `package_name`, `label`, `version_code`, `icon_sha256` (or null),
  `launchable`. Package names use the existing Android validator; labels are
  bounded to 256 Unicode scalars. Default/page cap64; total cap4096. Cursors bind
  one immutable catalog generation. A changed snapshot returns409 `stale_cursor`
  and the Mac begins a new bounded snapshot; it never combines generations.
* `GET /v1/catalog/changes?after=<generation>`: bounded changed entries/deleted
  package names plus current generation. An expired cursor returns409 and requires
  a snapshot. No full catalog on each heartbeat. The Mac's export choices remain
  local per device/package and survive uninstall/reinstall.
* `GET /v1/icons/<sha256>.png`: content-addressed PNG, max512×512 pixels and
  262,144 encoded bytes (thumbnails max64 KiB), `ETag` equal to SHA-256, immutable cache. Decode with
  dimension limits, verify bytes/hash before using; two concurrent icon fetches,
  four MiB byte cache plus disk cache bounded to64 MiB. Never accept URL redirects.
* `GET /v1/events?after=<sequence>&limit=64&wait_ms=25000`: `epoch`, `events`, `next_sequence`,
  `reset_required`. Sequence is monotonic within a random installation/service
  epoch. Event entries contain `sequence`, `event_id` UUID, `kind`, `created_at`,
  `payload`. Max64 entries and256 KiB response. Retain last512 events; expired
  cursors require state/catalog resync. Persist the consumer cursor only after
  applying or durably rejecting an event, so reconnect is at-least-once.
* `POST /v1/commands`: `{request_id, kind, payload}`. The receiving side persists
  a receipt before acknowledging, deduplicates request UUID+canonical payload,
  returns the original result on identical retry and409 on conflicting reuse.
  Bound dedupe store to512 receipts/24h; a response identifies accepted vs applied.
  Pending requests expire after30seconds unless they are explicit file transfers.
* `POST /v1/state`: `{ request_id, sessions:[...], audio_route, profile,
  connection_state }`. Max32 sessions with session UUID, package, label, backend
  and phase. No window screenshots, app text or content. This updates a snapshot
  for the phone dashboard; it cannot admit a Mac session.
  Only peers advertising `state_heartbeat` may receive the smaller
  `{request_id, unchanged:true}` form. It refreshes that same trust's existing
  snapshot without replacing sessions/audio/profile. No extra state fields are
  allowed. A missing prior snapshot returns409 `snapshot_required`; the sender
  retries a full snapshot. Old protocol1 peers always receive full snapshots,
  because they did not recognize this optional form. Revocation and snapshot
  publication serialize so an earlier authenticated request cannot restore a
  revoked peer. Balanced/responsive/battery publish cadence is2/1/5seconds;
  explicit session changes still trigger prompt publication.
* `GET /v1/diagnostics`: bounded counters, service/protocol versions, permission
  states, battery/charging/thermal status, network transport class, recent error
  codes; no device content, hardware identifiers, SSIDs or credential material.

Command kinds: `open_app` (`package_name`), `stop_session` (`session_id`),
`set_audio_route` (`mac|phone|mac_and_phone`), `set_profile`
(`balanced|responsive|battery`), `clipboard_text` (explicit text, max64 KiB),
`share_text` (max64 KiB), `share_url` (http/https only, max8 KiB),
`notification_reply` (opaque notification/action IDs and max4 KiB text),
`dismiss_notification` (opaque ID), `forget_mac`, `diagnostics_request`.
Phone-to-Mac commands enter the event journal; Mac results are posted as command
receipts. A Mac accepts open/stop/audio only for the paired explicit device and
its own session registry. Expired/replayed commands cannot reopen an app.

Clipboard receiving never silently replaces a clipboard. Show a received item
with Copy action. Sending requires a deliberate Send Clipboard action. URL/file
receiving never automatically opens or executes content. Notification mirroring
is opt-in per trust and excludes sensitive/hidden/ongoing categories by default;
replies invoke only Android's currently advertised RemoteInput action, with
notification identity revalidated at execution.

## File and installer delivery

`POST /v1/transfers` begins an explicit transfer: `{request_id, transfer_id,
direction, display_name, mime_type, size, sha256}`. Size cap50 MiB, filename max255
scalars, max2 active transfers, aggregate staged cap100 MiB,30minute expiry.
User-visible names are metadata, never filesystem paths. The receiver allocates
its own UUID file in a private temporary directory.

`PUT /v1/transfers/<id>/chunks/<index>` sends raw bytes with exactly one fixed
Content-Length (max65,536), `X-Chunk-SHA256` and authorization. Retries with the
same index+hash are idempotent; gaps/conflicts fail409. `GET /v1/transfers/<id>`
reports next expected index and accepted bytes, permitting bounded resume.
`POST /v1/transfers/<id>/commit` verifies exact length and complete SHA-256 outside
the state lock, rechecks trust, and atomically publishes a received item. No
automatic extraction/execution. Cancellation/expiry/revocation deletes private
staging. Downloads use `GET /v1/transfers/<id>/chunks/<index>` under the same caps.

Mac delivery assistance defaults to the public DroidBridge release page plus
installation/pairing instructions. Optional offline DMG delivery uses the same
explicit transfer mechanism with a separately declared installer size cap and
user confirmation; a phone cannot install macOS software. Never bundle an
unversioned DMG inside the APK. Display release version/checksum/source; verify
release origin and bytes before presenting a local installer. Signing and
notarization claims require actual release evidence.

## Scheduling, performance and perceived speed

All I/O and hashing are off the Mac main actor and Android UI thread. One short control
request at a time per paired device, one separate long-poll, max2 icon/file requests. Control traffic
has priority over bulk transfers; after every chunk yield and check cancellation.
Event long-poll waits at most25seconds; normal connected state polling is2seconds, inactive10seconds, absent exponential
backoff2/4/8/16/30seconds with jitter. User actions bypass the next poll delay.
Polls coalesce; reconnect never starts parallel snapshots or duplicate commands.

Measure on both API35/API37 emulators with actual host/phone endpoints: warm
hello/control p95≤100ms overUSB-equivalentADB, UI acknowledgement≤100ms, command
applied/phone feedback p95≤500ms excluding Android app cold launch, first64 catalog
entries≤1second, warm unchanged sync≤2 KiB/request, idle control≤2KiB/s, icon cache
hit zero transport, transfer memory bounded independently of file size. Measure
wire bytes, duration, allocation/RSS and p50/p95 from raw receipts; report failed
budgets rather than weakening them. Wireless budgets are measured separately.

## Required adversarial and release gates

Test malformed/oversized/duplicate framing, slow clients, credential guessing,
revocation during transfer, changed cursors, bounded snapshot restart, duplicate
and conflicting command retry, repeated reconnect, catalog churn, icon decompression
bounds, file traversal/size/hash/missing chunks, stale notification actions,
no silent clipboard overwrite, no LAN listener, no content logs, phone denial,
APK/service restart, Mac crash, exact-forward cleanup, and companion absence.
Existing ADB apps/windows must remain usable if the companion is absent or fails.
Install and run packaged Mac app and APK outside build outputs. Require actual
GUI actions and changed content, not compilation alone. No physical Pixel or
unrelated emulator use without the owner's explicit testing authorization.

## Host broker and public Swift surface

A per-user local companion broker persists bounded session metadata for the main
launcher and independent wrappers. A wrapper registers its PID, process-start
identity, session UUID, installation identity/explicit serial and monotonically
fenced owner generation. The broker sends stop/audio/profile commands to that
owner through user-owned local IPC; it never launches a shell. Receipts bind the
request ID and exact live owner generation. Closed/dead owners cannot receive
commands; stale registration cannot resurrect a session. The phone dashboard
therefore remains meaningful when the launcher closes. The broker is an explicit
release workstream, not satisfied by reading only the main launcher's sessions.

Core API ownership: technical lead owns `CompanionModels.swift`,
`CompanionClient.swift`, `CompanionCredentialStore.swift`, and
`CompanionForward.swift`, plus focused Core tests. Systems expert owns the persistent broker, Core IPC and broker installation.
Mac expert owns Companion controller/views, Launcher integration and wrappers' registration.
Android expert owns APK/service/protocol peer. Root coordinates security/design
review before freezing protocol and running end-to-end acceptance.

`CompanionClient` is an actor initialized with an owned loopback URL and optional
credential. Its async operations are `hello`, `beginPair`, `pollPair`, `catalog`,
`catalogChanges`, `events`, `sendCommand`, `acknowledge`, `publishState`,
`diagnostics`, `icon`, `trustedMacs`, `revoke`, `beginTransfer`, `transferStatus`,
`uploadChunk`, `downloadChunk`, `commitTransfer`, and `cancelTransfer`. JSON DTOs
use Swift camelCase fields and snake_case wire fields. Dynamic bounded payloads
use `CompanionJSON`, never untyped executable strings. UI owns operation lifetime
and explicit cancellation. Keychain and ADB-forward APIs remain separate from
protocol parsing to permit deterministic negative tests.
