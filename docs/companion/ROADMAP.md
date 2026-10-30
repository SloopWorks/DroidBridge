# DroidBridge companion program

Status: active development. This is the full program roadmap, not a claim that
the companion features already work. The starting production revision is
`e0e02ea2f4810dcc3e108d5f2339e6cdb25726db` (macOS 0.1.8 build 14).

The user requested the roadmap **and then implementation of the full program**.
All recommendations below remain in scope through installation, integration,
independent review, failure testing and release evidence. A milestone is complete
only when its end-to-end gate passes; compilation and disconnected screens do
not satisfy a gate. Physical Pixel acceptance remains the owner's final stage.

## Product ownership and execution

The lead agent acts as Technical Product Expert and acceptance coordinator. The
Technical Lead owns integration contracts and implementation sequencing. Separate
macOS/Swift, Android, mobile UX/UI, systems design and security agents review and
implement their owned areas. Agents work in bounded parallel waves when available
execution slots are fewer than roles; a role cannot be replaced by an unreviewed
assertion from its implementer. Independent security review can reject a gate.

| Responsibility | Owned deliverables |
|---|---|
| Technical Product Expert | This roadmap, requirement traceability, acceptance, release and evidence index |
| Technical Lead | Boundary contract, shared types/client, integration and recovery design |
| macOS/Swift expert | Native companion UI, broker/session integration, permissions, Spotlight and install flows |
| Android expert | Installable native companion, bounded server, OS capabilities, catalog, sharing and optional integrations |
| Mobile UX/UI expert | Phone/Mac onboarding, permission timing, connected/offline states, accessibility and perceived speed |
| Systems expert | Transport arbitration, concurrency, backpressure, resource budgets and failure/performance tests |
| Security reviewer | Threat model, authentication, revocation, content handling, adversarial executable checks and release review |

Production code owners agree interfaces before cross-module edits. Preserve
unrelated work. Never operate the physical Pixel or emulator-5554 during automated
development; explicitly owned API 35/37 emulators are the test devices.

## Complete recommendation inventory

| ID | User capability | Delivery milestone | End-to-end evidence required |
|---|---|---|---|
| C01 | Guided USB setup and authorization status | M1 | New install connects without terminal use; denied/offline paths stay actionable |
| C02 | Secure Wi-Fi setup and reconnection | M1/M6 | Actual Android wireless-debugging TLS pairing/connect, endpoint change and outage recovery |
| C03 | QR pairing, trusted Mac list and revoke | M1 | QR/camera or image import, phone approval, persistent trust, immediate revocation and replay refusal |
| C04 | App names/icons/catalog changes | M2 | Android install/remove/rename change reaches Mac; bounded delta and content-hash icon reuse |
| C05 | Select exported apps and Spotlight availability | M2 | Phone selection changes actual signed Mac wrappers/index admission; unavailable phone cannot launch stale result |
| C06 | Phone Open on Mac/favorites | M3 | Real phone action opens correct app on selected trusted Mac and returns actual outcome |
| C07 | Session dashboard/stop all | M3 | Includes independent wrappers while main launcher is closed; stop releases exact sessions/resources |
| C08 | Audio route and screen controls | M3 | Phone action uses existing typed Mac APIs; device-wide scope and actual result visible on both ends |
| C09 | Health/compatibility diagnostics | M3/M6 | Transport, auth, app, codec/audio and permission failures have actionable bounded diagnostics/export |
| C10 | Android Share to Mac files/images/links/text | M4 | Real Android share intent/content URI becomes a verified Mac inbox item with progress/cancel/retry |
| C11 | Explicit clipboard handoff | M4 | User-initiated copy in both directions, foreground Android access, expiry and no background collection |
| C12 | Optional notifications and supported replies | M5 | User grant, actual notification, update/dismiss and actual RemoteInput reply; revoked access stops new content |
| C13 | Battery/thermal/network profiles | M6 | Live state and chosen profile visibly affect bounded work/video settings without silent Android global changes |
| C14 | Mac download/install assistance | M7 | Actual reachable installer/download or scoped offline delivery, integrity checks and installation outside build tree |
| C15 | Coordinated versions/updates and trusted-device controls | M1/M7 | Incompatible versions fail explicitly; reinstall/rekey needs new trust; update preserves settings |

## Phone–desktop boundary

Streaming stays in the existing pinned scrcpy backends. The companion channel
carries control, catalog metadata, explicit shared content and optional events;
it carries no screen frames or PCM. A normal Android APK does not obtain the
privileged Android app-streaming role or silently enable debugging.

The initial transport is a loopback-only Android service reached through an
exact-owned ADB forward. USB and Android's authenticated wireless-debugging TLS
are transport choices; an unauthenticated LAN control server is not an implicit
fallback. QR trust is separate from ADB authorization and never bypasses Android
confirmation. The detailed versioned API is in [BOUNDARY_CONTRACT.md](BOUNDARY_CONTRACT.md).

Requirements the contract and implementation must preserve:

- A paired Android installation ID is the phone identity. USB/Wi-Fi serials are
  transport aliases, not new trust identities. Reinstallation/rekey fails closed.
- One per-user Mac broker owns companion credentials and the phone connection.
  Independent wrappers publish fenced session state and receive scoped commands;
  the main launcher's in-memory dictionary is not the dashboard authority.
- One selected transport admits new work for a physical phone. Existing streams
  stay pinned to their owned transport until deliberately drained or lost.
  Reconnection restores intent with a visible gap; it is not gapless migration.
- Version/capability/permission negotiation precedes feature admission. An absent
  permission or unsupported feature has a distinct state, never a fake success.
- Every mutating operation has a request identity and canonical receipt. Retry
  after timeout resolves unknown outcome without duplicate launches, replies or
  files. Cursor expiry forces a bounded snapshot, never invented deltas.
- Control/status traffic has priority over icons and file chunks. Queues, active
  requests, input bytes, decoded sizes, disk staging and retained history are
  bounded. Cancellation and revocation fence late publication.
- Existing wrapper loading windows remain local and immediate. An unavailable
  companion cannot add a blocking round trip before the first Mac window.
- Pair secrets, credentials, notification bodies, clipboard and file content are
  excluded from routine logs. Content stays on the selected phone/Mac connection.

## Proposed performance and payload gates

These are targets to measure on owned emulators and the installed Mac artifact,
not existing performance claims. USB and real TLS Wi-Fi results are reported
separately. Record sample count, p50/p95, cold/warm state and hardware/load.

| Boundary | Initial gate |
|---|---|
| Immediate local Mac loading response | p95 ≤100 ms; companion is absent from this critical path |
| Cached first catalog page | p95 ≤150 ms with visible freshness state |
| Warm metadata/control response | USB p95 ≤100 ms; TLS Wi-Fi p95 ≤200 ms; completion may be asynchronous |
| Companion handshake after reachable service | p95 ≤1 s; bounded unavailable-service probe, no UI blocking |
| Existing video first-frame regression | Paired/unpaired companion adds ≤10% and ≤200 ms against same-run baseline |
| Small delta after observed package change | Visible within2 s while connected; reconciliation handles missed events |
| Catalog | ≤64 entries/page; target≤32 KiB JSON/page; hard256 KiB decoded JSON ceiling |
| Icons | Hash-addressed; list thumbnails target≤16 KiB, hard64 KiB; full wrapper icon hard256 KiB and512×512 decoded pixels |
| File transport | Raw chunks≤64 KiB; max2 active transfers; progress/cancel; disk quota and per-file limit explicit |
| Events | Bounded batches and25 s maximum long poll; no idle busy loop; snapshot on cursor loss |
| Interactive fairness | Heavy transfer cannot cause control p95 to exceed2× its measured idle bound |
| Lifecycle | No orphaned owned forwards/processes/displays, duplicate capture owners or unbounded retry/retention |

Final bounds and schemas are pinned in the reviewed contract before the shipping
gate. A failed budget requires remediation or an explicit product decision with
measured impact; silently raising a cap is not a passing test.

## Milestones and exit gates

### M0 — Reviewed roadmap and contracts

Create the boundary/API contract, ordinary-APK capability matrix, state/UX flows,
threat model, ownership plan and executable acceptance plan. Systems, mobile UX,
Android, macOS and security reviewers inspect the same revision. Resolve
contradictions before treating the implementation as release-ready.

### M1 — Installable companion and secure connection

Build/install native Android and Mac applications. Implement lifecycle-visible
phone service, exact-owned forwards, version handshake, QR/manual import, phone
approval, Keychain/Keystore trust, revoke/forget, USB guidance and real wireless
pair/connect UI. A per-user broker survives main-window closure without creating
one poller or credential copy per wrapper. Test restarts, wrong identity/version,
expired/guessed/replayed pairing, revoked credentials, slow/truncated responses,
malformed bytes and exact transport cleanup. No secrets in argv/logs/artifacts.

### M2 — Fast catalog and selective Mac integration

Implement snapshots/deltas, icon hashes/cache, Android package change handling,
phone-side export selection and Mac onboarding reconciliation. Preserve existing
signed wrapper identities/settings and offline admission. Test large catalogs,
locale/icon changes, remove/reinstall, cache corruption, cancellation, concurrent
updates, stale cursors and zero-change payloads. Verify actual installed wrappers
and Spotlight behavior; don't infer indexing from a bundle identifier.

### M3 — Phone control and diagnostics

Implement phone dashboard/favorites/Open on Mac, cross-process session registry,
typed launch/stop/all-stop/audio/screen actions and result receipts. Reuse existing
Mac admission and lifecycle owners. Validate correct device/session targeting,
main app closed, independent wrappers, duplicate/late commands, activity changes
and partial failures. Add actionable connection/permissions/compatibility views
and opt-in redacted diagnostic export; no raw content collection by default.

### M4 — Sharing and explicit clipboard

Implement Android share target and content URI permission lifetime, bounded
streaming/resumable staging, filename/type validation, SHA integrity, Mac inbox,
progress/cancel/retry, explicit Open/Reveal and both-direction clipboard actions.
Do not auto-execute shared files or automatically open untrusted URLs. Test
expired URI grants, unknown lengths, quota/disk-full, path traversal, symlinks,
duplicate names, interrupted chunks, hash mismatch, resume and disconnected
receivers. Compare transfer and simultaneous control latency under load.

### M5 — Optional notifications and replies

Implement permission education and Android's actual notification-access grant,
bounded/redacted notification events, Mac notification/in-app surfaces, updates,
dismissal and supported RemoteInput replies. Associate every action with its
current notification identity/generation. Test access denial/revocation, stale
replies, removed actions, unsupported/sensitive notifications and duplicate retry.
No unattended permission grant or fabricated notification success.

### M6 — Connection resilience and resource profiles

Implement live battery/thermal/network state, user-selected balanced/performance/
battery behavior, bounded polling/asset scheduling and deliberate application of
video settings. Preserve user global settings and explain when a profile applies
only to new sessions. Test USB↔TLS Wi-Fi aliases, no duplicate audio/companion
owners, sleep/wake, process death, real emulator restart, missing wakeups,
reconnect backoff, competing wrappers and slow/large-content transfers. Measure
CPU/RSS, idle bytes/wakeups and user-perceived latency rather than only throughput.

### M7 — Delivery, installed validation and final review

Produce installable signed Android APK and complete Mac app/DMG with versioned
protocol/dependency notices, checksums and reproducible build scripts. Provide a
real working Mac delivery path from the companion: a reachable verified download
and/or explicitly scoped installer transfer. A dead releases link is not delivery.
An ordinary phone app does not install or approve software on the Mac. Developer
ID/notarization require actual credentials; otherwise label ad-hoc artifacts.

Install both artifacts outside build output and repeat complete two-platform
onboarding, catalog, real app launch/input, dashboard, both audio/video backends,
share/clipboard, notification/reply, revocation, disconnect/reconnect and uninstall
checks. Independent security, systems and UX reviewers audit raw evidence and
reject unsupported completion claims. Publish concise Pixel verification steps;
physical security confirmations and hardware acceptance remain explicit.

## Evidence and completion ledger

Implementation progress and test commands belong in `verification/companion/`.
Maintain a requirement→source→test→artifact→review mapping with pending/blocked/
passed distinctions. Store screenshots, scoped logs, sample distributions,
payload/queue measurements, installed hashes and failure reproductions. Tests
using fake tools are useful contract evidence, never actual-device evidence.

No milestone is removed because implementation is difficult. Platform restrictions
must produce a real, tested alternative and an honest explanation. The program is
complete only when every C01–C15 row has an implemented path, end-to-end evidence,
installation validation and independent acceptance.

## Platform references

- [Android wireless debugging](https://developer.android.com/studio/run/device)
- [Package visibility declarations](https://developer.android.com/training/package-visibility/declaring)
- [Foreground service types](https://developer.android.com/develop/background-work/services/fgs/service-types)
- [Clipboard access and explicit sharing](https://developer.android.com/develop/ui/views/touch-and-input/copy-paste)
- [Notification listener](https://developer.android.com/reference/android/service/notification/NotificationListenerService)
- [Privileged app-streaming restrictions](https://source.android.com/docs/core/permissions/app-streaming)
- [Mac distribution and Developer ID](https://developer.apple.com/developer-id/)
