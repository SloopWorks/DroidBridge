# Companion program status

Full implementation remains incomplete. Installed GUI and performance acceptance is
blocked by the locked Mac; the user requested committing and merging this current
checkpoint into main. That merge does not mark the program or release complete.
Roadmap: `docs/companion/ROADMAP.md`.
Branch: `codex/companion-program`; production base: `e0e02ea2f4810dcc3e108d5f2339e6cdb25726db`.
No companion milestone is accepted solely because it compiles.

## Current checkpoint: installed Mac10 / Android12; distribution12 packaging repair

Product0b4b3e3 passed335 Swift tests (four explicit live opt-in skips), followed
by seven owning tests for a test-only process identity guard. Android12 passed
8 unit,3 focused TLS,36 full device and9 large-text tests. Independent source
review binds those exact scopes; it does not claim the later test-only guard
ran as part of the earlier full335.

Actual installed Mac10/APK12 now passes automatic catalog changes in both visible
windows without Refresh: five package operations reached rows335.8–855.45ms after
Android completion. Exact CJK/supplementary labels and blue-square→green-triangle
icon updates pass. Service restart and a cold owned-emulator restart recovered
the same phone/trust with live native frames; the phone service requires explicit
Start after reboot. See installed-api37-tls-build10-final/REPORT.md.

The rejected Mac9 catalog attempt exposed JSON-null broadcast filtering; its
failed timings remain recorded. Android12 fixes that routing and preserves
sensitive event targeting. UX review also caught mismatched label counting;
scalar-safe producer/shared consumer validation and real Unicode fixtures now
pass. Neither failure was replaced with a mock success.

Distribution11 source62186d3 includes final user guides and a small footer count
correction; the shipping AppKit full/delta footer fixture passes. Independent
review rejected distribution11: the fallback Player library symlink escapes its
nested bundle, so standalone strict signatures fail despite the outer app check.
Distribution12 gives Player an internal, bounded 17-library closure and verifies
each Mach-O plus the nested bundle. The private repaired fixture passes 48 strict
checks and five negative cases; exact release rebuild/review is pending. This
packaging defect also limits the earlier QA10 outer-signature result. Installed
smoke, performance, public download and final review remain open. The Mac has locked and CUA automatic unlock failed; the user has
been asked to unlock it. No alternate GUI or lock bypass is authorized. All
possible offline packaging/review work continues.

Distribution12 source94b51c2 now builds successfully. A read-only verified DMG
was copied to a fresh QA12 Applications path; all48 individual Mach-O signatures,
the nested Player, its17 internal libraries and the full portable runtime check
pass. The DMG is48,138,501bytes and stays below the unchanged256MiB delivery cap.
Exact source archive validation and independent final artifact/source review
pass; see security/final12-offline-cohort-review.json. No QA12 GUI launch or performance pass is claimed while locked.
The first build12 attempt exposed a broken HomebrewPython XML library; packaging
now preserves/preflights the working callerPython. Its failed log is retained.

## Historical installed checkpoint: Mac8 / Android11; Mac9 source gate


Mac9 is required before release. Independent review identified a missing desktop
consumer for automatic catalog updates and the native permission API throwing
when notification authorization is denied. The new visible-UI catalog reader
coalesces authenticated change hints, uses bounded full/delta reads, preserves a
finite retry budget during event storms and fences replies to the current trust.
A blocked-read/100-hint regression covers starvation. A separately reviewed Core
fix prevents completed catalog read receipts from replaying data after Forget.
The 21 focused Core tests pass; full current-source Swift, AppKit execution and
installed Mac9 results remain pending. No Mac8 result proves those changes.


The current machine-readable ledger is [RELEASE_CANDIDATE.json](RELEASE_CANDIDATE.json).
Product revision `a2a37c6` contains the reviewed notification authority/privacy
fixes and fallback mouse-hover mitigation. Mac0.2.0/build8 bundles the exact
Android11 candidate2 APK `6fa302dd74bd42d67a4bcc88a9970c8079af880a376263ca3ff42584ef809029`.
The rejected first Android11 candidate and its real system-package crash remain
recorded; it was not packaged for release.

Current full Swift:320 tests, four explicit live-device opt-in skips, zero
failures,152.429s;126 source/test hashes stable. Actual API35 Android:34 full tests
(282.426s), three focused notification tests (14.07s), nine large-text tests
(48.715s), all pass. Actual notification replies, private transitions, scope
replay refusal,4096/4097-byte boundaries and256×8 recipient cleanup were exercised.

The read-only build8 DMG was copied to a fresh Applications path and validated:
198 matching inventory entries, deep strict ad-hoc signatures and31 portable
Mach-O dependency trees. Fresh first-launch host registration passed without a
manual retry. Updated installed GUI, performance and public-delivery gates are
still in progress. Source-archive review is provisional until the final evidence
commit. Actual Spotlight UI and allowed native-banner delivery remain blocked or
unverified as described in the ledger. No companion release is public yet.

The sections below retain earlier checkpoints and their limitations; they do not
override the newer source/artifact bindings.

## Historical checkpoints (superseded where noted below)

- Core integration: 87 focused Swift tests passed (`integration-core-tests.log`), including managed export admission, broker IPC, parser/security, QR/setup and profile calculations. This precedes the latest pairing metadata / local host-command integration and requires a final rerun.
- Android: API35/37 actual loopback HTTP/security checks; later API37 nine-test remediation run. See `android/INITIAL_REPORT.md` and owner logs. Public hello latency is not an authenticated-control or Wi-Fi performance result.
- Phone UI: three installed checks at default settings and three at 320dp / 200% text on owned API35 emulator. Font/density restored. These checks do not establish paired transfer, notification or profile outcomes.
- Mac UI: native anonymous-NSXPC fixture exercises eight surfaces, a 1,000-app catalog and 160,123-byte file hash roundtrip. This is a fixture, not actual phone interoperability.
- Export revision tests: seven pass, including a durable catalog version-2 fence that makes legacy helpers refuse future managed writes. Actual old-helper negative proof is pending.
- Exact installed source and Homebrew recipes staged for 13 runtime dependencies; each archive hash or Git revision verified (`source-staging.log`). Corresponding-source release packaging/review remains pending.
- Interim Mac 0.2.0 build 1 packaged with broker/APK/camera metadata; it uses the superseded plaintext transport and is not a release or accepted pairing candidate.
- Locally signed Android release APK produced with persistent private signing material outside source control. Debug-to-release install, paired operation and update validation remain pending.

## Blocking security remediation

A normal Android application can occupy the loopback port while the companion is stopped. Plain HTTP would disclose a pairing secret or saved bearer to that impostor. ADB transport security does not authenticate the Android server application. Independent review requires installation-stable Keystore TLS identity, mandatory QR/manual certificate pin and Mac pin validation before request bytes. Bare-secret enrollment, TOFU and HTTP fallback are rejected. Actual installed pairing is deferred to the TLS candidate.

## Current integration priorities

1. Package and install an isolated QA Mac application with broker, camera usage metadata and companion APK; prove actual pairing / Keychain / restart on owned API37 emulator.
2. Bind accepted phone export changes to authoritative managed policy with per-package monotonic revisions. Upgrade old availability authority safely; the existing eight-generation cap must not be bypassed.
3. Complete validated host bootstrap for phone Open on Mac after GUI quit, cross-process audio status/retry and local stop-all.
4. Execute paired sharing/clipboard/transfers/notifications/revocation/recovery and performance gates. Review independently after remediation.
5. Complete actual download delivery, dependency corresponding-source obligations, installed release validation and final review before merge/push.

## Safety and ownership

Only dedicated emulator-5580 (phone UX) and emulator-5582 (Mac interoperability) may be mutated. Physical Pixel and user emulator-5554 remain untouched. Production installed 0.1.8 application and user managed wrappers are preserved during interim QA. No public companion release has been published.

## Latest integration checkpoint

Interim 0.2.0 build 1 package validation passed strict nested ad-hoc signatures,
25 Mach-O dependency trees, isolated-PATH runtime launches and bundled APK hash.
No plaintext pairing acceptance or production replacement was performed.

The TLS broker integration now obtains a pin from explicit enrollment or approved
Keychain records before opening a phone request. Unknown USB/Wi-Fi aliases may
try only the bounded saved-pin cohort; wrong certificates receive no HTTP bytes.
Enrollment checks the pinned hello's UUID against the QR before sending its
secret. Unapproved transport allocations expire after two minutes. Installed
interoperability and malicious-listener capture remain pending.

Additional C15 recovery gate: a companion reinstall changes its installation UUID
and TLS identity. Implement and test an explicit Forget/re-pair path that safely
retires the prior canonical alias/policy authority before admitting a successor.
Do not silently rotate pins or leave a new Keychain record plus partially mutated
broker state after failed alias admission. Saved known aliases must not be blocked
by an unrelated phone's unavailable Keychain ACL.

## 2026-10-30 current Swift gate

Full `swift test`: **224 tests, four explicit live-device opt-in skips, zero
failures**, 107.9 seconds (`swift-all-tests.log`). The initial full run hung in
`AvailabilityRuntimeStoreTests`' Foundation `waitUntilExit`; the captured sample
identifies that exact stack. Test cleanup now reaps only its owned PID with finite
TERM/KILL deadlines. Six migration-store tests then passed, followed by the full
suite. The interrupted run/sample are retained rather than counted as a pass.

Independent API35 ordinary-APK peer attack initially passed four cases with
explicit raw-capture audit. The security owner is rebuilding the probe with a
source/object manifest to repeat against the latest strict hostname policy.
Actual Android P-256 TLS 1.2/1.3 tests and production Mac Core hello now pass API35;
API37 and installed full GUI pairing remain in progress.

M6 alias gate remains open: broker connection switching refuses registered live
sessions, but direct ADB-only wrapper/video/audio starts can bypass that registry.
Canonical verified aliases need cross-process admission that permits concurrent
sessions on one chosen transport, refuses a second transport until teardown and
survives GUI/supervisor crashes. No duplicate-audio claim is accepted from the
broker check alone. Bound this to the existing local alias policy so companion
absence does not add a network dependency to normal launch.

## Current TLS and installed checkpoint

The plaintext-listener security blocker above has been remediated, not waived.
Actual ordinary Android attacker APK tests on API35 and API37 capture zero HTTP
bytes for a mismatched certificate and only TLS ClientHello bytes for a plaintext
listener. The source/object-bound probes and raw captures are retained under
`security/`. Pairing requires the full QR/manual URI, pinned certificate and
matching installation UUID before sending a secret. No TOFU or plaintext fallback.

The installed, ad-hoc-signed Mac QA build 0.2.0/build2 paired with the signed API37
companion, displayed its catalog, rendered an actual changing Android fixture,
reconnected using Keychain trust and recovered after its broker was terminated.
Native keyboard/mouse/resizing and Android Share text were exercised. Evidence:
`installed-api37-tls-build2-attempt3/` and
`installed-api37-tls-build2-reconnect/`; remaining GUI flows are still being tested.

Actual signed Android TLS release tests and same-signature version1→2 update
preserved installation identity/settings. A separate versionCode3 delivery
candidate builds successfully and is being tested only on owned API35; the
frozen build2 APK used by installed Mac QA remains unchanged.

Ad-hoc broker updates can lose legacy Keychain ACL access. A real different-code-
hash helper reproduced a hang despite LAContext's no-interaction policy. The
production store now disables Keychain interaction process-wide and fails fast;
real signed helpers verified failure, deletion and fresh save/read. Installed
Forget/re-pair UI and retained export/profile settings still need final evidence.
Automatic trust continuity across ad-hoc updates is not claimed.

C15 alias retirement/export authority and M6 cross-process canonical capture
admission are implemented in progress with focused tests; installed alias,
wireless TLS, crash cleanup and audio-owner tests remain open. Availability
runtime migration now has bounded crash journals and focused tests, but the
isolated installed eight-generation test is not yet accepted.

Public release delivery remains open: versioned metadata is validated and UI
fails honestly when this unreleased version is unavailable. Corresponding-source
archives are staged, while source-built ADB and final release/source packaging
are still under review. No companion release is public, and production user apps,
wrappers, helper and physical phone remain unchanged.

## Latest measured interoperability

The lead independently recalculated all p50/p95 values in the installed build2
performance JSON. Owned API37 emulator results: warmed catalog p95=131.01ms
(n20); pinned authenticated diagnostics p95=27.96ms idle(n30) and33.91ms during
real hash-verified2MiB downloads(n91), fairness ratio1.213; saved-trust reconnect
p95=282.52ms(n5). `performance-root-audit.json` records exact boundaries. These do
not establish physical USB/Wi-Fi performance or local preview/video regression.
Actual native Open/Save panels completed both-direction2MiB transfers with exact
hashes; received Mac files retained quarantine. See installed build2 evidence.

The separately signed Android code3 notices candidate passes19 installed tests
plus4 large-text/320dp UI tests, with original settings restored. APK hash and
source bindings are in `android/notices-api35-artifact.json`. Public installer
availability remains open; its unavailable UI is explicitly verified, not called
successful delivery. See `android/DELIVERY_REPORT.md`.

An actual isolated LaunchAgent upgrade from eight legacy generations passed,
retaining the cap/current old pin and verifying the new helper PID/path/protocol.
Its ADB was a signed compiled fixture, so Android availability is explicitly not
claimed. The source-built ADB37 separately passed real API35 shell, file hash
roundtrip and exact forward lifecycle on isolated server5038, then terminated
that exact server. ADB's new dynamic dependency portability into private broker
and availability generations remains under implementation before packaging.

## Independent review remediation checkpoint

The full integrated264-test run failed on a TLS fixture's partial port-file
publication race and an outdated late-forward fake. Both were fixed without
weakening production TLS or exact tuple cleanup. The next276-test run had one
port-lease test assertion fail while actual M6 runtime concurrently occupied a
released TCP port. That test now directly proves inherited-lock retention and
release; allocation still refuses foreign listeners. Historical failed logs are
retained; neither run is reported as passing.

Independent review reproduced a late TLS identity response publishing policy
after shutdown. Lifecycle guards now fence hello/identity/setter/admission and
journal publication, and the owner lock remains until accepted requests drain.
Review also found cleanup ownership could be lost on failed persistence or
forward close. Reservations are now tracked before ADB allocation, teardown
registers ownership before fallible boundaries, and finite backoff cleanup runs
independently of healthy phone publication, including when storage is failed.
The broker journal now stages0600 bytes with file fsync, rename and directory
fsync; fault tests prove complete old/new publication and unsafe-target refusal,
not physical power-loss durability. A stale unrelated Keychain record can no
longer prevent another installation proving its own pinned new alias. Focused
security/scheduler/TLS/lease tests pass; a fresh full-suite gate remains required.

Current-source M6 actual emulator runtime passed Android wireless-debugging TLS
pair/connect through owned emulator redirections (not physical Wi-Fi), real
phone approval and authenticated alias binding, two native streams, resize,
audio ownership after video closes, cross-alias Phone intent, SIGKILL teardown
and later alias recovery. Final Android displays exactly matched baseline[0]
and exact owned forwards/JARs/temporary redirections were removed. Evidence:
`broker/m6-actual-alias-runtime.json` and `broker/android-wireless-tls.json`.
This is a source harness, not the final installed GUI artifact. Legacy0.1 hosts
must be closed/updated before joining this protocol cohort; mixed old/new
capture ownership is explicitly outside the new alias-fence guarantee.

## Reviewed source regression and real-forward checkpoint

Full `swift test` now passes **277 tests, four explicit opt-in live-device skips,
zero failures**,121.37s. Exact log: `swift-reviewed-candidate-tests.log`. This
supersedes the pending full-suite statement above, not the outstanding installed
GUI or release gates.

The lead linked current production Core objects into a narrowly scoped actual
ADB driver on owned emulator5580. Making only that driver's executable symlink
unavailable caused real cleanup failure; its ownership receipt and actual
forward remained. Restoring the executable and retrying removed both. A second
actual ADB mapping was deliberately rebound to another remote port; production
close preserved that replacement, then the driver removed its own test mapping.
Final forward inventory matched the baseline. Source/object/probe/ADB hashes and
facts: `security/actual-forward-runtime.json`; driver:
`scripts/verify-companion-forward-runtime.swift`. This proves the Core cleanup
mechanism, not automatic broker retry, physical transport or installed GUI flow.

## Installed build3 and independent UX rejection checkpoint

Build3 packages signed Android code6 (b17b6bcae25cb3549ec696a868675807aa93fc316ae1327bd8af9ede5dfc31f5).
The21 signed Android device tests and five320dp/200%text tests pass, including
actual30s stalled pipe reads, explicit cancellation, capacity recovery and full
consent-button visibility. The lead inspected raw instrumentation output;
`android/CONSENT_STAGING_CODE6_REPORT.md` binds sources/artifacts/settings.

Mac build3 passes deep/strict ad-hoc verification,31 Mach-O dependency closures,
isolated-PATH runtime checks, exact APK notices and a copy outside the build tree.
Independent distribution review verified all16 required dependency source
cohorts,1532 compiled source/header inputs,81 static archives,16 source notices,
and seven unchanged portable ADB files. Actual installed ADB passes isolated
API35 discovery/shell/hash-verified transfer/forward cleanup. Its first attempt
used an unsupported ADB listener-host syntax and failed; that log is retained.
The later isolated connection also left shared discovery of owned emulator5580
offline. Only that emulator's transport is under recovery; shared server5037,
Pixel, emulator5554 and Mac verification emulator5582 are not restarted.

The installed ad-hoc update fails promptly on the old credential ACL and permits
explicit Forget/revoke/QR-image import/phone approval to recover. Actual CUA
keyboard input reaches two concurrent native display sessions independently.
These facts do not close wrapper/Spotlight, full permission/reply or release gates.

Independent UX review rejected code6 for false success after expired approval,
unbounded pre-consent provider metadata access and clipboard URI coercion on the
UI thread. Android code7 remediation/tests are assigned. Actual first-install
phone bootstrap also needs bounded Mac host-registration retries. Export/control
testing found a seven-second peer clock offset invalidates absolute-wall-clock
command deadlines. A negotiated pinned monotonic clock-epoch/uptime contract is
being implemented; the30s owner deadline is not widened to conceal the failure.

Quiet installed build3 timing improved substantially after deferring the hidden
launcher but still FAILS the initial100ms cold-preview gate: connected p95~504ms,
disconnected~388ms(n5each). First-video regression also fails this small cohort.
`installed-api37-tls-build3-preview-quiet/results.json` retains phase measurements.
Further local-window startup remediation is in progress and not yet timed in an
installed candidate. Do not mark either performance gate passed.

Local source review commits5ad87f7/91d0916 exist on codex/companion-program; neither
is pushed or a completed release. A155MiB corresponding-source candidate archive
was successfully generated against5ad87f7 and the exact build3 cohort. Final
archive review must use the eventual committed, tested release candidate after
these fixes. No companion assets are publicly released.

## Monotonic admission and installed verification checkpoint

The owned API35 transport recovery is complete. The local emulator's Developer
options showed USB debugging disabled; enabling it through the authenticated
emulator UI restored ADB. The temporary gRPC control endpoint was removed by
restarting only that owned emulator with its original arguments. No shared ADB
server, physical Pixel or unrelated emulator was restarted. Evidence:
`android/transport5580-ui-recovery.json` and the before/after screenshots.

Android code8 is now the frozen candidate, APK SHA256
`0bddc834ac688fedb23d18138a59ea39c6fd7f4d3ecda0d0f63759d8ab999ee9`.
The lead inspected the raw actual API35 instrumentation logs: **28/28 tests pass**
in 234.42 seconds, plus **7/7 at 320dp and 200% text** in 20.205 seconds.
The real 120-second test confirms late Trust cannot approve, repeated admission
does not extend the first admission, unresolved admission retires to unknown,
and timely admitted work can complete honestly after its initial 30-second
budget. Actual stalled pipe/query deadlines and explicit cancellation release
capacity. See `android/CODE8_ADMISSION_REPORT.md` and the raw logs it identifies.
Code7 evidence is retained as superseded, not relabeled as code8.

The lead inspected the actual ScreenCaptureKit image and WindowServer metadata
in `installed-api37-tls-build3-visible/two-native-windowserver-tiled/`:
two distinct processes/windows show different fixture content, display IDs and
input values. This substantiates that build3 checkpoint; it does not prove the
new command contract works in an installed candidate.

Independent review found and rejected additional command lifecycle gaps.
The current source uses pinned monotonic peer clocks, a durable one-time
execution grant, owner/trust checks after awaited admission, bounded unknown
outcomes, immutable stop-all aggregation and explicit command protocol2 owner
eligibility. Legacy owners remain dashboard-visible but receive no new commands;
already delivered old work cannot be retracted. A final full Swift suite and
installed Mac/APK interoperability are still required. An interrupted earlier
suite is explicitly recorded in `security/clock-final-interrupted.json`.

Build4 packaging completed but was superseded by final Core settlement/scope
fixes before installation. Build5 packages those fixes and Android code8.
No cold-preview or first-video performance gate has been upgraded to pass.
File-based Spotlight indexing is also still unverified: user/Data-volume apps
are absent from metadata results despite indexing reporting enabled. A separate
temporary Core Spotlight item was indexed, queried and deleted successfully;
actual Spotlight activation and availability behavior remain open gates.
