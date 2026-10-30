# Independent companion UX review

Reviewer role: Mobile Design and UX/UI Expert. Review date: 2026-10-30.
Scope: C01–C15 in `ROADMAP.md`, `BOUNDARY_CONTRACT.md`,
`MACOS_INTEGRATION.md`, `ANDROID_CAPABILITIES.md`, current Android
`MainActivity.kt`/`BridgeStore.kt`/`BridgeTransfers.kt`, and Mac
`CompanionPairingScanner.swift`/`CompanionWirelessSetup.swift`.

## Acceptance status

**Not accepted for end-to-end release yet.** The initial installed Android
Home/Apps views exist and use legible scrollable native controls. Source and
screens show gaps in recipient identity, truthful operation results, connection
state, transfer controls and catalog usability. No installed full Mac companion
window evidence was available for this review. `UX_FLOWS.md` supplies concrete
interaction/state requirements for implementation and regression tests.

Evidence inspected visually, not inferred from agent assertions:

- `verification/companion/android/home-api35.png` and matching UI XML: first
  screen, initial service/pair cards and persistent navigation.
- `verification/companion/android/connected-api35.png` and XML: after service
  start the heading says "Ready for your Mac", without observed paired/live Mac.
- `verification/companion/android/apps-api35.png` and XML: giant per-app cards
  expose roughly two apps at once, package IDs and checked Spotlight boxes;
  no icon, search, favorite, selected receiver or publication status is visible.

The initial review was read-only. The lead then explicitly transferred
`MainActivity.kt` and owned emulator-5580 GUI scope to this role for remediation.
No physical Pixel, emulator-5554 or active Mac processes were operated. Backend
changes remain with the Android expert. All findings below retain their original
source/evidence context; remediation progress is recorded separately below.

## Required remediation

| ID / Priority | Source / evidence | Required change and executable acceptance |
| --- | --- | --- |
| UX01 / P1 | `MainActivity.home`, connected screenshot | Replace service-running → "Ready" with separate service/ADB/trust/peer freshness facts. Show selected receiver. Starting only the service must not claim paired/connected; test unpaired service-on and stale previously paired states. |
| UX02 / P1 | `apps`, `home` audio, `sharing`, `sendCommand`; `BridgeStore.phoneCommand` returns void | Remove unconditional "Sent to Mac" after a function that catches failure or only enqueues. Return/persist request ID and show queued/accepted/applied/rejected/unknown/expired state. Test no selected trust, peer offline, actual applied, rejected and lost response without duplicate launch. |
| UX03 / P1 | `settings` "Use <name>"; `receiveShare`, `sharing`, `apps` omit receiver | Put selected trusted Mac name and selected state on Home and every sharing/launch review; same-name trusts need non-secret disambiguation. Two-Mac test must prove the previewed receiver alone gets the action/file, including selection change while staging. |
| UX04 / P1 | `receiveShare`, `sharing` files; `BridgeTransfers.stage` | Add persistent preparing/waiting/sending/verifying/completed/failed progress with cancel and honest partial-state wording. "Ready for Mac download" is staging, not delivery. Test real file, interrupted/resume, cancel, quota/oversize and received hash before success. |
| UX05 / P1 | `showPairing`, pending approval dialog; Mac scanner | Phone instruction says paste link but Mac field says code; use **Pairing link or secret**, distinct from six-digit ADB code. Show actual expiry and comparison code on both peers, named phone/Mac, deny/expired states. Test imported QR/manual and delayed approval; Done must not imply cancellation if secret remains live. |
| UX06 / P1 | `settings` notification switches and per-trust opt-in | Separately show actual OS access, global sharing, and each Mac's opt-in/filter state. Checked global switch cannot imply access granted. Test denial, settings-return refresh, revoke while connected, new second trust stays off, no lock-screen body default. |
| UX07 / P1 | `home` sessions and audio; missing stop-all/screen controls | Show reported-at age, no-report versus truly-empty distinction, exact-owner stopping/applied result, stop-all scope and partial failures. Audio needs selected desired/actual route + Retry/Use Phone. Add phone-screen action with true effect. Verify independent wrappers with main launcher closed. |
| UX08 / P2 | `apps`, screenshot and `render` rebuilding view tree | Add local search, icon placeholders/lazy verified icons, favorites and compact reusable/virtualized app rows. Hide package ID except ambiguity/details. Export selected vs published/pending must differ. Test large catalog, no icon layout jumps, checkbox change pending/offline, search while polling. |
| UX09 / P2 | `refresh` 500 ms; `render` calls `setContentView`; no saved editor state | Incrementally update changed state, preserving tab/scroll/focus/drafts. Avoid full tree churn and UI-thread catalog work. Test continuous status changes while typing/scrolling, rotation, large text and selected nav accessibility state. |
| UX10 / P2 | `settings` profile buttons; `home` audio button list | Use explicit single selected controls and show actual acknowledgement. Profiles must say video applies to new windows when that is true. Test existing versus newly opened session params, failed acknowledgement and unknown sensors. |
| UX11 / P2 | `sharing` text length guard and `receiveShare` text confirm | Invalid/oversized input currently silently does nothing. Show byte-limit error and preserve draft. Named receiver and pending receipt before confirmed send, explicit Copy on receive with expiry/Clear. Test both directions and prove idle does not read clipboard. |
| UX12 / P2 | `settings` Diagnostics raw `store.status` dialog | Add actionable summary/freshness, unknown values and redacted export with destination/cancel. JSON may remain Details. Verify no content/secret/IDs in export, failed export has visible error. |
| UX13 / P2 | `settings` Mac downloads browser-only release index | Include actual release/version/architecture/size/checksum/signing boundary, Copy Link and Mac install steps. Verify reachable artifact, update mismatch guidance and installed copy outside build. Index with no download artifact is insufficient. |
| UX14 / P2 | Mac wireless 560×440 and scanner 540×510 fixed top-only layout | Use resizable scroll content or prove longest errors fit; add explicit field labels, keyboard traversal and primary/cancel actions. Preserve security copy without clipping status. Test actual runtime long error, narrow window, camera denial and scanner alternate flow. |
| UX15 / P2 | Actual initial 320 dp / 200% font screenshots in `verification/companion/ux/*-narrow-large-api35.png` | The four fixed-width navigation columns clip Home/Apps/Sharing/Settings into fragments. Replace with full-label reachable navigation, selected semantics, and content inside scroll areas. Test actual rendered labels and target reachability, restoring exact font/density settings. |
| UX16 / P2 | `CompanionWindow.buildNotifications`, `macos-ui/700-4-Notifications.png` | The primary notification filter expects comma-separated internal package IDs. Provide a searchable app-name/icon selection; package editing may remain an advanced option. Verify selected app filters reach the correct trust and actual notification behavior. |

P1 findings block the corresponding capability's UX acceptance. P2 findings
remain required release work for the requested full program; they are not a
scope reduction or permission to ship an unusable path.

## First phone remediation and installed checks

`MainActivity.kt` now has a persistent receiving-Mac chooser, distinct service/
trust/fresh-peer state, bounded queued/request outcomes, duplicate-pending-action
suppression, selected desired routes, explicit Retry Audio, new-window-only
profile copy, separate notification grants, named recipient/file review,
preparation and transfer progress/cancel, explicit diagnostics export and Mac
installation/link guidance. App search is local with a native virtualized list,
verified content-hash icons, two image workers/16 pending requests and a 4 MiB
bitmap cache. File preparation uses a separate worker so control polling does
not wait behind a file copy. Clipboard reads remain deliberate actions.

On the first APK recorded in `verification/companion/ux/interim-installed.json` (SHA-256
`92ff5bfe02381335af41c5565280d4c7fd89e602134b42297d88cc8b4344e599`),
`CompanionUXDeviceTest` executed **3/3 tests at normal font/density and 3/3 at
320 dp / 200% font scale**. The actual tests assert full navigation labels,
programmatic selected semantics and reachable scroll navigation; no-match search
and real installed-app results; and editor identity/draft preservation through
status polling. They neither read clipboard nor pair/revoke a trust nor launch
remote applications. Exact APK/test APK hashes and raw instrumentation output
are retained. `improved-*-api35.png`/XML were captured from that installed APK;
they show correct service-off/unpaired presentation, disabled peer-dependent
actions, actual icons/search/favorites and full-label navigation. Font1.0 and
physical density420/no override were restored exactly (`restored-settings.json`).

The final phone UI source adds the agreed backend seams for selected-trust
received-text expiry/removal, revision-only catalog checks (no full catalog
serialization on every UI poll), truthful unknown charging and friendly health
facts, typed audio retry, and large-font Apps viewport preservation. The matching
APK in `installed.json` is SHA-256
`f3ce8a7767197acfee6e982a0b25fcb2c20ccf6e02147f0434f62cb5eef3011c`.
The final actual-device rerun again passed **3/3 normal + 3/3 narrow/large text**,
including a usable list viewport assertion; raw results are
`instrumentation-final-api35-{normal,narrow-large}.txt`.
`final-home-api35.png`, `final-apps-api35.png` and
`final-apps-narrow-large-api35.png`/XML show that APK. `handoff.json` records the
frozen source hash, exact restored settings and released emulator-5580 scope.

These are **phone layout/search/editor checks**, not proof of remote applied
actions, cross-process session control, file delivery, notification replies,
pairing security or Spotlight publication. Retry Audio, received-text removal,
backend export receipts and transfers require actual paired-flow checks against
the final installed release candidate. The
implementation owner cannot independently approve its own phone remediation;
the lead's final security/QA reviewer must inspect source and actual paired
flows against `UX_FLOWS.md`. The overall release status remains not accepted
until those broader gates have evidence.

## Mac AppKit layout review

The independent reviewer subsequently inspected the actual native AppKit view
captures in `verification/companion/macos-ui/` at700 and900 points, covering
Connection, Apps, Handoff, Notifications, Performance and Install, plus the
shipping `CompanionWindow.swift` implementation. These use an anonymous NSXPC
fixture, not an installed companion connection. They are useful layout evidence
and must remain labelled as fixtures. The captures show readable scrollable
sections, a virtualized1000-row catalog, reserved icon geometry, persistent phone
selection, explicit permission boundaries, deliberate handoff and new-window
profile wording. The reviewer did not operate the shared Mac runtime.

Actionable feedback sent to the Mac owner: shorten **Pair with QR or Secret…**
to **Pair Phone…** because the700-point capture clips its action title; show the
new comparison code and named Mac in actual pairing-pending state; replace the
primary package-ID notification filter with a user-readable app selector
(UX16). Source has subsequently added scrollable/resizable wireless/scanner
windows, but actual long-error/camera-denial and paired-state release evidence
remains required. No fixture screenshot proves a real launch, transfer, reply,
revocation or first-install download succeeded.

## Boundary and perceived-speed acceptance

The implementation must show local feedback before a network poll, using the
roadmap's ≤100 ms acknowledgement target, while reserving success for actual
receipt/effect. Record action timestamps separately from peer acceptance and
applied state. Test control interaction during large transfers, not merely
isolated throughput. A spinner without named stage/peer and cancel is not enough.

No companion round trip may delay a saved Mac wrapper's immediate loading
window. Catalog text should paint from a bounded cache before icons; stale and
empty/error differ. Repeated events/heartbeats should not rebuild phone screens
or move Mac focus. Accessibility announcements happen only on material changes.
Battery/thermal/network facts have time and unknown states. Phone service-off or
companion-incompatible states cannot crash or close existing video windows.

## Independent release re-review checklist

The next review must inspect actual installed Mac/Android screenshots or native
view captures plus UI interaction/receipt logs for all C01–C15. Priority sequences:

1. Clean pairing, denial/expiry/manual fallback, reconnect, and identity change.
2. Two trusted Macs, visible receiver, per-trust opt-ins and immediate revoke.
3. Apps search/favorite/export, real Spotlight publication/unavailability, phone
   Open on Mac and independent wrapper lifecycle with main app closed.
4. Audio/screen/profile desired-versus-applied results, rejected/unknown feedback.
5. Real share files/text/link, transfer progress/cancel/interruption and explicit
   clipboard both directions without silent pasteboard overwrite.
6. Actual notification access denial/grant/reply/stale action/revoke and private
   content defaults, followed by redacted diagnostics and actual Mac download.
7. 320 dp / 200% text Android layout, long labels, keyboard/insets, accessibility
   hierarchy, polling while editing; Mac narrow/long-error/keyboard traversal.

Record exact APK/app hashes and tested states. Do not promote source review,
compile success, a green protocol test, an OS permission checkbox or a service
notification into proof that the cross-device experience completed correctly.
