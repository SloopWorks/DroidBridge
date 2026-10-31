# macOS companion integration

Status: implementation input, 2026-10-30. Existing behavior is described by
`ARCHITECTURE.md`; this document specifies the companion work. It does not claim
that the planned features have passed acceptance.

## Current Mac implementation checkpoint

`CompanionDesktopAdapter` uses only broker IPC, registers the real host and
process-owned session cohorts, and dispatches fenced commands through existing
launcher/audio/power/export admission. `CompanionWindowController` supplies the
eight native surfaces below. `CompanionTransfers` performs bounded file I/O and
full size/hash verification off the UI actor. The setup camera/image/manual and
wireless-debugging windows are implemented separately.

The installed QA mode is explicit: a validated mode700 owned canonical root and
one of emulator-5580/emulator-5582 are required. Its storage, helpers and identity
scope cannot be inferred from normal startup. Scope validation/device filtering
have focused tests. Actual production acceptance must still exercise ordinary
installation and owned wrapper paths; the QA flag is not that proof.

See `verification/companion/macos-ui/REPORT.md` for native source/NSXPC component
evidence and its deliberately limited scope. Installed phone/Mac interoperability
and independent security/UX review remain release requirements.

## Product boundary

The Android companion adds pairing, a catalog, explicit handoff and a phone-side
control surface. ADB/scrcpy remain the execution, virtual-display and video/input
transport. A companion outage must not close working video windows or add a
catalog dependency to a saved Mac wrapper's startup. A paired companion identity
does not establish ADB authorization, and an authorized ADB device does not by
itself establish companion consent.

The first transport is pinned HTTPS on Android loopback, reached through an exact owned ADB
forward, for either USB or Android's separately paired wireless ADB connection.
It is not a LAN listener. Pairing and reconnect UI must name these two
different permissions. General wireless/LAN discovery requires a separately
reviewed authenticated encrypted transport; a Bluetooth association or QR code
alone does not supply one.

The shared contract is owned by the technical lead. Suggested UI-facing data:
connection phase and reason, protocol/capability versions, immutable phone ID,
trust ID, pairing challenge expiry, catalog revision, bounded app pages, export
selection, transfer receipts/progress, command accepted/completed/rejected
receipts, session snapshots, profile, battery/thermal observations and their age.
Use unknown for unavailable observations, never zero. Secrets never enter labels,
accessibility text, diagnostics or logs.

### Approved host adapter seam

A persistent per-user companion broker is the sole phone HTTP/credential owner.
It is independent of the Spotlight bulk-onboarding flag. Main GUI and wrappers
use bounded Codable JSON Data requests/replies over the reviewed same-user IPC
channel; credentials are never returned to those clients. The UI adapter needs:

- `status`, `connect(serial)`, `disconnect(device_id)` and `retry`;
- `begin_pair(serial, secret, server_pin, expected_device_id)`, bounded pending/approved/
  rejected polling, and `trust_list` / `revoke`;
- `catalog`, `export_selection_get/set`, icon-by-hash and refresh progress;
- `inbox_list`, explicit `clipboard_send`, `share_send`, transfer progress/cancel,
  received-item save/copy, inbox clear, notification filter/reply/dismiss;
- `profile_get/set`, capability/permission states, bounded diagnostics export;
- main/wrapper `session_publish`, `command_poll`, and fenced accepted/applied/
  rejected acknowledgements, binding each session to its actual process owner.

The concrete IPC owner supplies named DTOs and operations before UI lifecycle
integration. A local broker outage must preserve current video and saved wrapper
startup. The pairing camera and native wireless-debugging setup do not own a
phone HTTP connection and can be implemented independently of that seam.

## Existing integration points

| Responsibility | Existing owner | Companion integration rule |
| --- | --- | --- |
| ADB readiness | `AndroidDiscovery`, `DeviceReadiness`, `LauncherController.refreshDevices` | Companion status supplements readiness; it cannot authorize a device. |
| App list | `LauncherController.loadApps`, `AndroidDiscovery` | Cache the paired catalog and use revision deltas. Keep authorized ADB fallback when the companion is absent. |
| Icons | `AndroidIconProvider`, bounded launcher icon queue | Prefer verified content-addressed companion icons; retain current helper fallback. |
| App launch/stop | `LauncherController.launch`, `close` | Translate validated phone commands into the same admission and lifecycle paths. Never construct arbitrary subprocess commands from a message. |
| Spotlight | `ManagedAppCatalog`, `DeviceOnboardingController`, availability helper | Export selection becomes additional policy. Positive authorized ADB readiness remains mandatory, and offline bundles remain hidden. |
| Audio | `AudioControls`, `DeviceAudioPreferences`, `DeviceAudioRouter` | Phone route requests use existing device-wide route semantics and failure feedback. |
| Screen/performance | `PhoneDisplayControls`, `SessionConfiguration` | Per-device profile applies to new sessions; explicit changes explain whether a restart is necessary. |
| Wrapper identity | `MacAppWrapper`, managed name repair | Preserve direct saved-package startup and separate macOS app identities. No companion service is copied into each wrapper. |
| App lifecycle | `AppDelegate`, `LauncherController.shutdownAndWait` | One main-host coordinator owns companion polling and drains/cancels all owned operations at quit. |

Independent wrappers can outlive the main GUI. The approved persistent broker
therefore needs process-scoped session publication, command ownership fencing
and crash recovery. The main launcher's process-local dictionary cannot prove
the complete phone dashboard or control independent wrapper sessions.

## Native controls and information architecture

Add **Phone → Companion…** and a small connection/status entry in the existing
device area. A dedicated AppKit window avoids filling the launcher sidebar with
unrelated features. Its navigation is:

1. **Connection**: selected authorized device, companion presence/version, setup
   instructions, USB/wireless ADB guidance, expiring QR/code pairing, trusted Mac
   identity, reconnect and revoke. Pairing requires visible phone consent. An
   expired challenge cannot silently pair when the next connection arrives.
2. **Apps**: cached searchable labels/icons, current/stale badge, favorites,
   per-app Spotlight selection and explicit Apply with bounded progress/cancel.
   Show selected count separately from the count actually published. Changes on
   the phone reconcile into the same selection policy and preserve completed
   wrappers when interrupted.
3. **Inbox**: received text, URLs, images and files with sender/time/size, explicit
   Copy, Open or Save. Do not execute or automatically open received content.
   URLs accept only reviewed schemes; file names never become destination paths.
4. **Clipboard**: explicit Send Clipboard and Copy Received Text. Read the Mac
   pasteboard only after its send action. No background clipboard polling. Phone
   clipboard restrictions are presented as actionable phone-side interaction.
5. **Notifications**: opt-in mirroring and app filters, permission states on each
   platform, bounded recent items and replies only where Android supplied a valid
   reply action. Opening notification settings is explicit. Do not mirror bodies
   to the macOS lock screen by default.
6. **Performance**: Balanced, Responsive and Battery profiles with concrete
   quality/network tradeoffs, observed phone battery/thermal/network status and
   timestamps. Screen-off and device-wide audio remain identifiable controls.
7. **Diagnostics**: connection phases, capability compatibility and export of a
   bounded redacted report. File contents, clipboard, bearer credentials,
   notification bodies and raw device screenshots are excluded by default.
8. **Get DroidBridge for Mac** on the phone: official release download and
   installation/pairing instructions; optional exact local artifact transfer.

Every long action has progress, cancellation, a terminal receipt and an explicit
retry. Rendering composition does not start I/O. Task generations fence selection
changes, disconnects and revoked trust. Reconnect uses capped backoff with jitter
and a user Retry control; repeated errors do not create repeated alerts.

## Protocol and perceived speed

Catalog first paint uses a bounded last-known snapshot without waiting for icons;
the UI labels it stale until the current paired device confirms its revision.
One initial page is enough to start searching; app wrappers continue to launch
from immutable saved identity without any catalog request. Icons are lazy and
content-addressed, with at most two active fetches and explicit byte/pixel bounds.

A single host coordinator multiplexes control/event/catalog work. Bulk transfer
and icon queues must not monopolize command/state processing. File chunks run off
the main actor with bounded in-flight bytes and streaming hash checks. HTTP
request/response bodies, event history, retry receipts, decoded image dimensions,
total cache bytes and transfer staging are all bounded in the shared contract.
Large payloads never use base64 inside catalog/state JSON.

Measure cold and warm pairing, first catalog paint, first icon, search latency,
command acceptance and visible completion separately. Measure p50/p95 wall time,
control RTT under file load, bytes transferred for unchanged and single-app
catalogs, memory, idle polling traffic and disconnect cleanup. A receipt is not
proof that an Android task or Mac window appeared. The program roadmap owns exact
budgets; do not loosen them to pass a test.

## Local storage and platform APIs

Pair credentials belong in Keychain, keyed by stable phone/trust identity, rather
than preferences or copied wrapper bundles. Revocation deletes the exact
credential and stops admission. Remote revoke requires a connected, authenticated
phone and reports failure honestly when unavailable. Local Forget Pairing is
separate: it removes this Mac's credential, retains wrappers/selections/settings,
and tells the user to remove the old phone trust before fresh pairing. A staged
phone-approved enrollment exposes explicit Finish Approved Pairing and Forget
Pending Pairing actions; startup never silently commits it.

The Mac downloads a phone-shared file only after a Save panel chooses its
destination. It stages mode-600 bytes beside that destination, verifies size and
SHA-256, publishes without overwriting, adds quarantine, and posts an exact
completion receipt. It never opens received content. Clear Inbox removes the
Mac's metadata; files explicitly saved elsewhere remain untouched. Phone staging
and expiration follow the Android transfer store's separate limits.

Use public AppKit, Security/Keychain Services, Network/URLSession and User
Notifications APIs. Notification authorization is requested only when the user
enables mirroring. Denial retains the in-app inbox and exposes settings rather
than blocking pairing. The application does not require Accessibility, Screen
Recording or Full Disk Access to show the companion UI or transfer selected
files. A local notification cannot be represented as originating from another
Android application's macOS identity merely by changing its title.

Official references:

- [Keychain Services](https://developer.apple.com/documentation/security/keychain-services/)
- [Notification authorization](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications)
- [Direct Mac distribution and Developer ID](https://developer.apple.com/developer-id/)

## Installer delivery

The Android companion can guide the user to the official Mac release, show the
version/architecture/size/hash and transfer an exact bundled or selected DMG to a
Mac already running a receiver. A phone cannot install the Mac application. A
local installer server on the phone would need a browser bootstrap surface and
its own carefully scoped transfer trust; it is not the loopback authenticated
API. Prefer a normal official HTTPS download for first install, then QR pairing.

Never auto-execute a received installer, claim a downloaded hash authenticates an
untrusted download source, or claim Developer ID signing/notarization without
verified credentials. Existing ad-hoc builds remain locally installable with
their documented Gatekeeper boundary. Artifact version/architecture/hash and
source URL must be visible; stale APK-embedded installers need a clear version
warning. Runtime updates and rollback must preserve existing wrapper generation
fences and accepted preferences.

## Executable release gates

| Gate | Required evidence |
| --- | --- |
| Pair / revoke / reconnect | Actual emulator + installed Mac app: wrong/expired/replayed challenges rejected, allowed pair survives restart, revoke blocks subsequent commands, no leaked forwards. |
| Catalog / icons / Spotlight | Actual install/uninstall and label/icon changes; revision traffic metrics, per-app selection enforcement, offline visibility/admission tests, original fast wrapper startup regression. |
| Phone dashboard | Phone action produces correct real Mac session/window; stop/audio changes verified from actual session/output state, rejection and offline UI tested. |
| Handoff | Android share intents for URL/text/image/file reach the installed native inbox; hashes and saved bytes match; large/cancelled/interrupted/invalid names and quota refusal tested. |
| Clipboard | Both explicit directions update the intended clipboard after user action; idle time does not read it and no diagnostic report includes content. |
| Notifications | Actual notification delivery/removal/reply using a deterministic Android fixture, permission-denied path, stale reply rejection, filters and private content handling. |
| Profiles / diagnostics | Applied session parameters and observable video responsiveness; stale/unknown sensor presentation; bounded redacted export verified byte-for-byte. |
| Delivery | Installed APK exposes real official release/install guidance; any local transfer matches the exact packaged artifact and never executes it. |
| UX / regression | AppKit accessibility labels, keyboard traversal, narrow/large text layouts, stable selection during polling, spinner/cancel/retry, quit/launch and existing two backend input/audio tests. |
| Security / load | Independent parser/auth/path/image/transfer/replay review, event/receipt limits, concurrent transfer + command latency and memory/backpressure evidence. |

Compilation, mocked transport tests and DTO round trips supplement these gates;
they do not replace installed two-platform end-to-end evidence. Physical Pixel
acceptance remains the owner's last manual stage.


## Installed API37 checkpoint (2026-10-30)

`~/Applications/DroidBridge Companion QA.app` version 0.2.0/build 2 was run outside
its build directory against the exclusively owned `emulator-5582`. The explicit
private QA root isolates catalog, preferences, sessions, audio, receipts, broker
namespace and Keychain service. No physical Pixel or user emulator was operated.
The bundled signed APK hash was
`c304d5d3fc526ebdc7c4c4e16d7c92fb5e53175bfe8f913d3d131fcf097cff04`.

Executed evidence under `verification/companion/installed-api37-tls-build2-*`
includes GUI APK install, pinned full-link pairing, matching comparison and phone
approval, catalog discovery, actual native content, stored-credential reconnect,
exact QA broker restart, owner-confirmed session stop, native keyboard/mouse
activity transitions, explicit phone text sharing, and both directions of real
2 MiB file transfer. The received fixture's bytes match its original provider and
SHA-256; quarantine and the phone's completion receipt were verified. A changing
Android frame probe and +1000 click counter verify actual live frames and input
before and after resize. These are specific checkpoints, not full-program signoff.
Camera/QR-import UI, notification/reply permissions, distinct wrapper identity and
post-main-quit phone bootstrap still need installed acceptance.

The performance runner records one persistent public NSXPC client's request
boundaries. Warmed catalog and diagnostics include real pinned HTTPS; bulk
content is a real 2 MiB phone fixture, verified on each read. It reports n,
nearest-rank p50/p95 and raw timings. A separate passive NSWindow observer records
process spawn to local preview separately from presented video. Build-2 cold
preview p95 exceeded the proposed 100 ms target; those reports explicitly fail
that target and identify concurrent compilation as a limitation. The next
candidate defers hidden wrapper launcher controls/layout/persistence until
Window → Launcher is explicitly opened. Optional QA trace phases separate app
entry, AppKit initialization, launcher construction and preview presentation.
Cold user-perceived time remains the acceptance boundary.

The desktop adapter's status/publish cadence now uses the fastest relevant
connected phone profile: responsive 1 s, balanced 2 s, battery 5 s. Command
polling remains 500 ms and an actual session change invalidates its publication
cadence. Unchanged discovery refreshes do not force publication. The real-timer
NSXPC component fixture observed status/publish counts of 1/2 in battery and 5/6
in responsive over 6.2 s each, while command polls stayed at 12/11. This proves
less status work in that local component; it does not establish battery savings.
Icon work uses the profile's one/two-request asset budget. New session encoder
ceilings still require installed 15/30/60 verification in the next candidate.

## Installed build-3 findings and remediation

The installed code-6 companion and Mac build 3 exercised actual CUA QR-image
selection, comparison/phone approval, local Forget plus phone revoke/re-pair,
and two live native displays accepting independent WindowServer keyboard and
pointer input. Evidence is under `installed-api37-tls-build3-*`. A visible,
private QA root outside `.build` isolates purpose-created Spotlight wrappers.
The initial fresh-broker host registration raced IPC readiness; a second main
launch registered successfully and the phone then bootstrapped the exact
installed host after Command-Q. The pending fix retries registration eight
times with capped backoff and exposes persistent failure plus an explicit retry.
Its anonymous-XPC regression covers transient success, exact exhaustion, and
status reads preserving the result; installed fresh-root acceptance is pending.

A seven-second phone/Mac wall-clock difference rejected Mac-to-phone commands
whose absolute expiry appeared too far in the future. The clock-anchor upgrade
uses pinned peer time only for QR validation and sleep-inclusive local deadlines
for pending commands. The UI countdown consumes the broker's local boot-bound
deadline and never compares a phone QR expiry to the Mac clock. Legacy missing
deadline fields fail closed rather than extending a command's lifetime.

The 30-second command budget governs **pending admission**, not completion of
an already admitted durable intent. The desktop adapter validates its exact
owner generation and continuous deadline at entry; Android-session launch checks
again after readiness and policy awaits immediately before session insertion.
Audio/screen desired intents are committed at valid admission, and their later
verified completion can truthfully be applied. A late acknowledgment does not
turn an effect that occurred into a rejected action. Wrapper publication remains
fenced by the accepted persistent export revision independently of command age.

The quiet build-3 ABBA cohort improved local preview median to 226 ms paired and
207 ms disconnected (n=5 each), with p95 504/388 ms. The proposed 100 ms cold
target still fails. First-video medians were 1952/1665 ms, so the paired overhead
also fails the proposed 10%/200 ms regression budget. Raw phase attribution and
both failures are retained; further startup changes need a new installed cohort.

## Shared visible catalog synchronization (candidate 9)

`CompanionDesktopAdapter` owns one `CompanionCatalogSync` for both the main
launcher and companion window. A visible catalog observes the broker's **local,
cached** status at one second; this does not poll Android's catalog. Hidden UIs
and immutable wrapper hosts create no catalog demand. Phone publication still
uses its selected performance profile separately. All status, publication and
inbox cadence deadlines use the sleep-inclusive monotonic Mac clock, so a wall
clock correction cannot stall those periodic observations.

A captured phone installation ID, original trust ID and opaque
`catalog_change_token` identify each demand. Initial connection loads pages of
64 (at most 64 pages and 4096 distinct package names), with first-page progress
in the companion view. Only a complete, consistent generation becomes the next
delta base. A changed token asks `catalog_changes` against that base, atomically
merges changed/deleted packages, and preserves unchanged icon hashes. A retained
base that Android no longer recognizes permits one bounded full-page fallback.
Ordinary failures retry at most three times; explicit Refresh resets that finite
budget. Cached complete catalogs remain usable during refresh failure.
The engine fixture is reproducible with
`scripts/verify-companion-catalog-sync.sh <report-path>`.

Both visible views share a fetch for the same phone/trust. Every request includes
`expected_trust_id`; responses are fenced again against current visibility,
selected alias, trust, task ticket and cancellation. A newer token coalesces
one successor instead of cancelling a valid in-flight snapshot; only the captured
token is acknowledged by that pass, and hints never reset the retry budget. Re-pair cannot reuse
the former trust's base. The main launcher also invalidates an older ADB app-load
ticket before accepting a companion snapshot, and invalidates only changed icon
hashes. Metadata caches retain at most four bounded origins. The pure shipping
engine regression covers shared 1000-app discovery, incremental rename/add/remove,
unchanged-token quietness, stale fallback, hidden/re-pair late responses,
duplicate-page refusal and finite retry. It is component evidence, not installed
Android acceptance; candidate-9 actual package-change testing remains required.

## Denied macOS notification permission

Installed build 8 confirmed that `requestAuthorization` can **throw** when the
system setting is Denied. The candidate-9 UI reads the current system status
without changing it and continues an explicitly requested in-app sharing
preference only when that read confirms Denied. Other authorization errors remain
errors. The original intent, phone/trust, filter, checkbox, window lifetime and
cancellation are checked before and after the extra await. This permits in-app
phone notifications while preserving the user's system-banner denial. It does
not grant macOS notification permission or demonstrate a delivered OS banner.
