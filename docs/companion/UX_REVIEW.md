# Independent companion UX review

Reviewer role: Mobile Design and UX/UI Expert. Review date: 2026-10-30.
Scope: C01–C15 in `ROADMAP.md`, `BOUNDARY_CONTRACT.md`,
`MACOS_INTEGRATION.md`, `ANDROID_CAPABILITIES.md`, current Android
`MainActivity.kt`/`BridgeStore.kt`/`BridgeTransfers.kt`, and Mac
`CompanionPairingScanner.swift`/`CompanionWirelessSetup.swift`.

## Acceptance status

**Final end-to-end release acceptance remains pending.** This document preserves
the first source/layout review and its remediation evidence, followed by the
current frozen-candidate audit below. The phone and Mac implementation have
advanced substantially beyond the original findings. Installed Mac build2 has
actual pinned pairing, catalog, video and bidirectional file evidence; those
passes do not prove every flow in the later build3/code6 candidate. The initial
fixture-only findings must not be mistaken for a current product inventory.
`UX_FLOWS.md` defines the interaction/state acceptance requirements.

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

## Frozen build3 / Android code6 independent audit

The review resumed against installed Mac
`~/Applications/DroidBridge Companion QA.app` version0.2.0/build3 and its bundled
signed companion APK SHA-256
`b17b6bcae25cb3549ec696a868675807aa93fc316ae1327bd8af9ede5dfc31f5`
(versionCode6). The Android owner previously ran21 installed tests plus5
narrow/large-font tests on API37. The reviewer inspected the raw final logs and
their source: the UI tests prove navigation/search/editor stability; the consent
test proves both full-height actions, Cancel preserving every trust, and Confirm
removing only its temporary trust; the stalled-provider test exercises actual
blocked pipe reads and the production30-second stage deadline. These are valid
scoped proofs, not every paired cross-device interaction.

The reviewer owns only emulator-5580 phone UI while the Mac expert owns Mac
automation and5582. Baseline5580 observations before update: code4, font1.0,
physical density420/no override, companion service off. The signed code6 test
APK installed, but the exact-device transport went offline before the baseline
UUID/pin/settings instrumentation snapshot. No product APK update or settings
change had occurred at that failure. One explicitly authorized
`adb -s emulator-5580 reconnect` and ten finite state polls did not recover it.
Transport repair was then handed to the Android expert; no shared ADB-server
reset, physical Pixel, emulator-5554 or Mac operation was attempted.
Raw observations are in `verification/companion/ux-final-build3/`. This is an
environmental interruption, not a failed companion update or a passing upgrade.

Three additional source findings block their corresponding UX gates until
remediated and revalidated. The reviewer made no production edits in this audit:

| Finding | Reproduction / implication | Required verification |
| --- | --- | --- |
| UX17 / C03 | `BridgeStore.approvePair()` returns normally when the pending attempt or live secret is absent; `MainActivity.approveDialog` interprets that as success and announces **Mac approved**. A tap after expiry can therefore claim approval although no trust was created. | Return/throw an explicit expired/missing result, preserve no new trust, and exercise the actual late-approval UI. Normal success and repeated callbacks must retain their canonical result. |
| UX18 / C10 | `MainActivity.reviewShare` queries provider metadata before consent using an uncancellable query on the sole file-preparation executor. A stalled query has no visible Cancel/deadline and blocks later preparations; the backend stage deadline begins later. | Remove provider access before confirmation or provide bounded cancellable inspection with late-result fencing. An actual granted provider that stalls query must prove Cancel/other UI remains usable and no pre-consent bytes/metadata were read. |
| UX19 / C11 | **Paste clipboard** calls `ClipData.Item.coerceToText` on the UI thread. A URI item can invoke/read a provider without the64KiB limit; post-materialization validation does not bound that work. | Admit bounded direct text without provider access, or implement a deliberately bounded cancellable reader off-main. A stalled URI clipboard and oversized direct text must give actionable feedback, preserve drafts and restore the test clipboard. |
| UX20 / C05 and command lifetimes | The Mac owner reports an actual phone-export flow failing when the phone clock is about7 seconds behind the Mac. This is separate from the inspector's layout/source findings and is not yet independently reproduced by this role. | Technical Lead must bind expiry to its authoritative issuer/monotonic lifetime, preserve replay refusal and test actual clock-skewed commands. UI must distinguish a true expired request from a valid request wrongly rejected due to another machine's clock. Re-run phone choice → actual wrapper/publication receipt. |

The Android owner is implementing the coordinated successor candidate, including
a pre-consent file review that states count/named recipient and honestly defers
names/size checking until approval. This design change is acceptable only when
the stated behavior and cancellation are demonstrated; it is not an acceptance
waiver. Candidate hashes and subsequent evidence must replace the code6 binding
for any affected release claims.

Source-checkpoint handoff: the Android expert owns the code7 production fixes,
provider/grant fixtures and5580 transport recovery. This reviewer contributed
`CompanionConsentInputDeviceTest.kt`, with two real native UI regression cases
for no-I/O pre-consent file review/Cancel/draft preservation and URI/oversized
clipboard rejection plus bounded paste and exact clipboard restoration. At this
handoff the new tests are **written but not compiled or executed**; fixture and
candidate integration remain with the Android expert. They must not be counted
as passed. The reviewer holds no device/Mac runtime scope while that work runs.

### C01–C15 acceptance ledger at this checkpoint

| Capability | Evidence independently inspected | Remaining final acceptance |
| --- | --- | --- |
| C01 USB setup | Build2 real AppKit install/open actions, phone service start and pairing; code6 consent/layout source and tests | Installed final candidate's actionable absent/unauthorized/offline/recovery states |
| C02 secure wireless | Actual Android wireless-debugging TLS and alias runtime source-harness evidence, separately scoped in program status | Installed native Wi-Fi setup actions and outage/reconnect, without claiming physical Wi-Fi testing |
| C03 pairing/trust | Build2 actual manual pinned pairing and comparison match; ordinary-APK negative security evidence; code6 temporary-trust consent test | UX17 fix, final candidate paired/rejected/expired/revoke/re-pair paths and complete-URI-only wording; camera/import scope explicit |
| C04 catalog/icons | Real build2 paired catalog screenshot; bounded generation/icon implementation and component1000-app test | Actual final install/remove/rename/icon-change UI/delta evidence |
| C05 Spotlight | Source policy/revision fences and bounded helper migration/old-helper refusal evidence | Phone choice → actual final signed wrappers/index admission, offline hidden/stale-launch refusal |
| C06 Open/favorites | Phone favorites/search implementation; build2 real Mac-launcher Open window | Phone action to named receiver, applied receipt and correct real window, including main GUI closed |
| C07 sessions | Cross-process registry implementation and actual source alias/session cleanup evidence | Final phone dashboard/stop-all with independent wrappers and partial-failure feedback |
| C08 audio/screen | Existing device-wide policies and real source alias/audio-owner runtime evidence | Final phone controls → actual route/power effects, explicit failed/retry/Use Phone results |
| C09 diagnostics | Bounded/redacted source, friendly unknown-state UI and installed component checks | Final export bytes/redaction and actionable real transport/permission failure presentation |
| C10 sharing | Build2 actual native panels, both-direction2MiB hashes and Mac quarantine | UX18 fix, final real share target, progress/cancel/resume and outcome feedback |
| C11 clipboard | Explicit selected-trust received-text source, expiry/removal controls; editor tests do not read clipboard | UX19 fix, both deliberate real clipboard directions, no silent replacement and exact test restoration |
| C12 notifications | Permission separation/filter UI source; Android actual RemoteInput validation implementation | Real producer/grant/denial/update/dismiss/reply/revoke with final installed Mac and current notification identity |
| C13 profiles | Source15/30/60fps/new-window settings, sensor unknown states and profile cadence component evidence | Actual old/new stream parameters and both-side chosen/applied feedback, control fairness under transfer |
| C14 Mac delivery | Versioned origin/hash/architecture validation; unavailable-release path correctly fails closed | Reachable real release metadata/artifact and install guidance/download bytes, installed validation |
| C15 versions/updates | Actual code5→6 signed update UUID/pin preservation from Android owner; source rekey/alias authority and Keychain failure handling | Independent5580 update snapshot after transport recovery; final Mac ad-hoc Forget/re-pair/settings preservation, incompatibility and release artifact binding |

This ledger records inspected proof and missing scope separately. It does not
promote source tests, a historical artifact, a service notification or a fixture
receipt into completion of the full requested program.

## Independent code8 remediation checkpoint

The reviewer re-entered the owned API35 emulator after targeted transport repair.
The installed base APK was read back and independently hashed as
`0bddc834ac688fedb23d18138a59ea39c6fd7f4d3ecda0d0f63759d8ab999ee9`,
matching the frozen code8 candidate. No product or test APK rebuild was needed.
The reviewer executed **six native UI tests at normal size plus three at320dp /
200% font**, all passing. These repeat the actual pre-consent no-provider-I/O
review/Cancel/draft proof, URI/direct-text clipboard limits with restoration,
trust Cancel/Confirm target bounds, search and editor stability. Raw independent
results and exact baseline/restoration facts are in
`verification/companion/ux-code8-independent/`.

Two additional fast installed tests passed for missing/dismissed/replaced exact
pairing consent and persisted Spotlight intent with explicit successor retry.
The initial filter invocation named one nonexistent method and therefore executed
only one test; it is retained as an incomplete selection, not a two-test pass.
The corrected invocation explicitly executed both cases (`fast-consent-spotlight.txt`).

**UX17–UX19 are accepted as remediated within their scoped phone-side behavior:**

- UX17 now requires the exact pending pairing ID and returns typed approval or
  throws for absent, replaced or expired consent. The reviewer inspected the
  code8 full-suite source and raw120,302ms case proving an actual late Trust tap
  reported failure without a new trust. A duplicate admission did not extend its
  deadline, and retired unknown could not be overwritten. The expensive real
  lifetime test was not repeated without cause.
- UX18 performs no provider query, MIME lookup or open before consent. The
  review explicitly names the recipient/count and says names/sizes are checked
  only after approval. The reviewer independently repeated the granted stalled
  provider/UI proof with zero pre-consent I/O and Cancel preserving the existing
  draft. Post-consent cancellation-aware query/read deadlines remain separately
  tested; an arbitrary Binder provider ignoring cancellation can retain one of
  the bounded worker slots until it returns. No absolute hostile-provider
  cancellation guarantee is claimed.
- UX19 admits only already-present direct text, checks UTF16 before converting,
  and bounds UTF8 to64KiB. The actual URI/UTF16/UTF8 oversized inputs preserved
  the draft and produced useful feedback; normal bounded text pasted. Android's
  clipboard service performs its own asynchronous MIME classification at setup;
  the test observes that separately and proves Paste adds no provider I/O.
  Clipboard contents were compared/restored in memory without logging them.

The emulator baseline was restored exactly: font1.0, physical density420/no
override, developer settings1, ADB1 and connection service off. No forward was
created, and no physical phone, emulator-5554, Mac GUI or Mac-owned5582 was used.

### Saved Spotlight intent and result truthfulness

Phone and Mac source now distinguish a committed selection from a pending Mac
wrapper: the phone banner/Recent actions say selection saved/app pending; the
Mac retains the checked choice and offers Retry Wrapper. The phone's Retry
Spotlight binds its original request and selected trust and admits a successor
UUID/revision; it does not replay the old receipt. The independent fast installed
receipt test proves that persistence/retry contract. Actual two-platform
materialization/failure/retry remains an installed Mac gate. When the global
Spotlight feature is deliberately disabled, Mac source reports `saved_disabled`
and explains enabling the setting; that distinct branch must remain labelled as
saved intent rather than proof of an available app.

Mac audio source reports committed routing intent with `output_not_confirmed`
when output has not become ready; it does not fabricate failed intent or sound.
The phone separately shows actual output and offers Retry/Phone. Its generic
completed-command label could be clearer for that partial result; this is minor
copy polish while the actual output remains explicitly unconfirmed. Neither
sample receipt nor successful route preference proves physical audibility.

### Five remaining installed release-gate groups

The full program remains unaccepted until the final source/artifact cohort has
actual evidence for these groups; earlier component passes are not erased:

1. Final Mac/phone connection UX: complete pinned pairing/import/approval,
   denial/expiry, two-trust recipient selection, revoke/re-pair/recovery and
   native wireless setup/reconnect. Camera/physical Wi-Fi limits stay explicit.
2. Dynamic apps and Spotlight: actual catalog/icon changes, selection → signed
   wrapper/index admission, preserved saved intent, pending/retry and offline
   hidden/stale-launch refusal. Resolve the reported cross-clock failure using
   the current monotonic cohort and verify the real flow.
3. Phone session controls: Open with main GUI closed, independent wrappers,
   dashboard/stop-all, audio failure/Retry/Phone, display power, diagnostics and
   new-versus-existing profile effects with accurate receipts.
4. Actual two-platform sharing/clipboard/notifications: progress/cancel/resume,
   explicit clipboard both directions, real notification producer/grant/denial/
   update/dismiss/reply/revoke, correct receiver and no unintended content reads.
5. Public delivery and installed version continuity: reachable real release
   metadata/artifact, installation outside build output, exact final signatures/
   hashes/source bindings and update/Forget/re-pair/settings preservation. The
   Pixel hardware stage remains the owner's documented final verification.
