# Systems implementation checkpoint

This is an implementation review, not end-to-end release acceptance. The
installed LaunchAgent, real Android connection and packaged host integration
remain open gates owned by the coordinator.

## Implemented boundary

- A Core-only per-user `DroidBridgeCompanionBroker` executable owns the phone
  client, Keychain credential and exact-leased ADB forward. A singleton owned
  flock prevents duplicate manual broker authorities. SIGTERM/SIGINT perform
  exact cleanup; abandoned-forward recovery uses Core's leased receipt checks.
- Public NSXPC MachServices carry bounded Codable Data. Effective UID, kernel
  PID/process-start identity and private random nonce are verified. Phone
  credentials never enter IPC replies, state files, labels or diagnostic logs.
- Pairing approval is checked through authenticated installation identity before
  saving aliases. USB/Wi-Fi aliases share one selected connection; switching
  refuses while any live stream is registered, preserving pinned video authority.
- Persistent owner-generation session registry includes independent wrappers.
  Dead/replaced owners lose mailboxes. Accepted commands expire at the phone's
  original deadline, are persisted before event cursor advancement, and receive
  applied/rejected receipts only from the exact generation. Stop All fans out
  stop_session to each actual owner and aggregates the resulting receipts.
- Shared items remain in an explicit private inbox. Notification updates replace
  the current opaque notification key. Revocation removes local content and
  invalidates registry authority; existing video does not depend on the broker.
- Control requests use a bounded priority queue; bulk max2, separate long-poll,
  64KiB raw phone chunks. Local base64 chunks are bounded to87384 encoded bytes.
  Local icon slices avoid exceeding256KiB IPC for valid256KiB PNGs. Verified icon
  cache is4MiB memory plus64MiB/256 files on disk. Inbox pages cap16/176KiB;
  total inbox caps64 items/2MiB. All waits/hashing/transport are off the UI actor.
- A separate LaunchAgent installer stages content-addressed broker+staticADB,
  verifies staged hashes, serializes install and launchctl, and retains at most
  four generations while preserving running flock leases. Spotlight generation
  limits and flags are untouched.

## Executed evidence and limits

`swift build --target DroidBridgeCompanionBroker` passes after this checkpoint;
see `verification/companion/broker/target-build.log`.

Fifteen focused tests pass on the current coherent checkpoint; see
`verification/companion/broker/tests.log`. These include an actual anonymous
NSXPC round trip with injected private root/nonce, wrong-nonce rejection, kernel
PID proof ignoring a fake payload PID, stale registration refusal, byte admission,
actual in-flight cancellation before a delayed reply, explicit cancellation and
harmless late callback. Signed-host tests create and sign a disposable app and
reject a symlink, changed executable and unrelated registering process. Pure tests
cover session caps, exact owner routing, PID reuse, generation replacement,
conflicting retry, expiry, mailbox backpressure and no cross-phone stop.

The earlier transient Mac integration compile failure is preserved separately.
These tests do not prove actual phone actions, launcher bootstrap, installed
LaunchAgent persistence or performance budgets. No physical Pixel, emulator5554,
production LaunchAgent or runtime ADB state was operated by this workstream.

## Remaining correctness/release work

1. C06 validated-host bootstrap is implemented: main-only registration binds the
   exact kernel executable path, strict signature and SHA-256; reopen revalidates
   and waits for live launcher registration. Actual installed-app quit/reopen/
   phone-launch verification remains pending. Audio state now comes from live
   owner-generation status, local Stop All aggregates exact owner receipts, and
   export changes use authoritative per-package revisions and the verified
   availability authority gate. All require real end-to-end acceptance.
2. Independently security-review broker persistence, IPC, lifecycle and cache
   boundaries; resolve findings before freeze.
3. Run installed LaunchAgent/Main/wrapper/Android end-to-end scenarios, including
   force-quit owner, broker crash/restart, revoke during transfer, alias switches,
   actual Stop All across independent wrappers, malformed peer and disconnect.
4. Verify real state-publish/long-poll wire bytes, p50/p95 responsiveness, idle
   traffic, cache hit transportzero, RSS and transfer cancellation under load.
   Present current settings as applying to new windows; existing streams retain
   their pinned FPS. Actual wireless TLS pairing performance is a separate gate.
5. Exercise bounded generation install contention/retention with real launchctl
   and an installed packaged copy; remove only this exact new agent on uninstall.

The same-user nonce boundary does not isolate the broker from malicious software
already executing as that macOS user. No private macOS API, root, shell command
interpolation, unencrypted LAN server or silent clipboard replacement is used.

## Critical transport authentication finding

The mobile/macOS review identified Android loopback-port impersonation: ADB
forwarding proves the selected device, not which Android app owns the listener.
No production release can be accepted until server secret possession is verified
before transmitting pairing secrets or stored credentials. Root is coordinating
independent security review and a transcript-bound challenge/proof contract.
Current interim artifacts are isolated development candidates only.

## 2026-10-30 systems source checkpoint (not program acceptance)

Current source uses mandatory pinned TLS. The earlier plaintext-port issue is
superseded by the coordinator's TLS remediation; it is not evidence that all
runtime recovery or release gates have passed.

### C15 explicit recovery and cross-store saga

Local `forget(device_id)` removes only that installation's normal and pending
Keychain accounts, invalidates in-flight trust epochs, closes its companion
transport and preserves app wrappers, settings, profile, accepted export choices
and revision history. Phone-side revocation remains an explicit separate action.
A forgotten predecessor can transfer aliases only during approved re-pairing.
Policy transfer is one locked atomic write, inheriting historical denials unless
an existing successor already has a deliberate choice. Retired predecessors keep
history with zero aliases. New trust starts a new revision authority.

There is no atomic transaction spanning Android, Keychain and filesystem. The
implemented saga writes a bounded durable pending journal, stages the approved
credential in a separate Keychain service excluded from normal account reads,
publishes the policy, finalizes the normal credential under that pending fence,
then commits broker state and retires the candidate. Failures remain explicit.
Uncommitted pending identities cannot reconnect automatically. The explicit
`recover_pairing` action reauthenticates through pinned TLS before finalization;
expired/unavailable candidates require Forget and fresh phone approval. Neither
an expired callback nor an old connect can resurrect a forgotten trust.

### M6 local alias admission and crash ownership

Every startup first takes a local deterministic serial lease, even without a
companion. Authenticated aliases use a stable canonical capture group. Multiple
video/audio owners may share one selected alias; another alias fails until all
owners drain. Catalog policy changes and admission share one lock order;
first-pairing/reassignment refuses while old standalone/canonical leases exist.
No companion RPC or credential is required on this capture admission path.

Swift retains a provisional lease before ADB staging. The supervisor independently
holds the same shared lease through child termination and exact scoped cleanup.
A small forked non-exec crash guard retains the alias/port/owner descriptors.
Normal shutdown sends a completion byte only after cleanup, closes the pipe and
reaps the guard. Unexpected EOF validates the original child PID, microsecond
process-start identity, UID and process-group identity before TERM/KILL, then
cleans the exact supplied forward/socket and staged resource. It cannot kill a
replacement PID. It never passes this descriptor through exec into an ADB daemon.
Actual fallback/native Android resource cleanup after crash remains a runtime gate.

Native supervisor arguments now include the derived exact remote socket. Native
Swift cleanup checks serial/local/socket before removing a reused tcp:0 port.
The existing abandoned-session recovery already selects the exact socket. A
foreign-replacement regression exercises both native supervisor and GUI cleanup.

Audio intent, retry tokens and ownership use the canonical group. Legacy alias
conflicts retain Phone; deliberate updates atomically compact aliases into one
entry without weakening the32-device bound. Stop-during-admission retains no late
lease and performs no ADB work. Profiles now control real per-device state cadence
(1/2/5seconds) and asset concurrency (2/2/1). Unchanged state uses a small heartbeat
only when `state_heartbeat` is advertised; `snapshot_required` retries full state.
Legacy peers always receive full state. Scheduler cancellation returns both
queued and immediate slots, preserving control priority and the64-waiter bound.

### Evidence at this checkpoint

- `broker/focused-integrated-tests.log`:45 focused tests passed, covering real
  anonymous XPC, real TLS races/faults/recovery, canonical leases/crash guard,
  native foreign-port replacement, audio intent, receipts and scheduler recovery.
- `broker/m6-alias-tests.log`:7 tests passed after adding the explicit
  stop-during-acquire regression; includes an actual C-supervisor SIGKILL and
  proof that its exact child exited before a replacement alias was admitted.
- `broker/tls-broker-race-tests.log`:5 real TLS tests passed. They suspend actual
  TLS hello/enrollment continuations, exercise Forget/replacement before secrets,
  inject candidate-stage/bind/finalize faults, recover explicitly, and verify
  negotiated heartbeat plus missing-snapshot fallback and legacy compatibility.
- `broker/release-hook-absence-build.log` and `release-hook-absence.json`: release
  broker builds and contains no internal DEBUG hook symbols/checkpoint strings.
  Test-only seams have no argv/environment escape and do not bypass TLS checks.

These are source/isolated runtime checks. No emulator, phone, production
LaunchAgent or installed artifact was operated in this systems wave. Root keeps
emulator 5580 reserved for the next coordinated runtime wave. Actual APK3→4
UUID/certificate continuity, wireless TLS alias tests, installed broker update/
recovery, independent security review, performance wire budgets and complete
program acceptance remain open. Broker installer portability belongs to the
technical lead; its current runtime/cohort work is separate from this checkpoint.

### Per-device short-control isolation (2026-10-30)

`CompanionBrokerScheduler.swift` now owns the scheduling actor. Short controls
carry the expected QR/stored installation UUID even before authenticated hello;
verified operations use that same canonical UUID across aliases. One installation
may hold one control lane and four controls may run globally. Eligible waiters
retain FIFO order, while a blocked installation does not block unrelated phones.
Assets retain the two-global, profile-dependent one-or-two-per-device ceilings.
Both queues share the unchanged 64-waiter admission bound. Long-poll events keep
the existing single per-device poller rather than consuming a short-control lane.

Cancellation removes a still-queued waiter promptly. If cancellation races an
actual slot grant, the acquired slot is returned once before cancellation escapes.
The regression observes an actual full 64-entry queue and verifies it drains after
cancellation without releasing the occupied phone lane first.

`verification/companion/security/cleanup-and-scheduler-remediation.log` contains
25 passing focused tests, including 5 scheduler and 7 real TLS broker tests. Two
new TLS peers deliberately hold hello or authenticated identity while a different
phone completes actual pinned-TLS hello and pairing in under one second, before
the held response is released. The earlier failed build in
`broker/per-device-scheduler-tests.log` is retained; the shared reaper's actor
isolation was corrected before the successful integrated rerun. Runtime phone
and installation gates remain separate from these isolated tests.

### API35 signed update and actual TLS alias runtime (2026-10-30)

The owned emulator 5580 was updated in place from signed companion code 3 to code 4.
Phone UI QR metadata and a pin-checked live TLS public hello before/after showed
an unchanged installation UUID and unchanged leaf certificate. Code4 advertises
`state_heartbeat`; no uninstall or trust reset was used. See
`broker/apk3-to-4-continuity.json`.

Android's actual Wireless Debugging pairing-code UI and adbd TLS listener were
used through two explicitly owned emulator TCP redirections. The TLS alias's
companion certificate/UUID matched USB. This verifies emulator transport and
Android TLS behavior; physical Wi-Fi and Pixel networking remain untested here.
`broker/android-wireless-tls.json` records that boundary.

A compiled current-source Core/Streaming harness then obtained fresh phone
approval, authenticated both aliases through the real broker with real ADB
forwards, and committed both aliases in its private QA catalog. The internal
DEBUG-only hook permits one explicitly compiled loopback alias while retaining
the unchanged QA35 storage/Keychain/receipt scope. Its endpoint override is nil;
no TLS, UUID, secret, credential or alias-admission fence is bypassed. There is
no argv/environment switch, and this hook is absent from release builds.

Executed runtime assertions:

- Two same-alias native streams received decoded frames (51 and 3 observed at
  the concurrent-frame checkpoint); resize produced 640×800 decoded geometry.
- Actual Mac audio initialized. After both video streams stopped, the audio
  lease continued refusing capture on the other alias.
- Phone audio intent selected through the wireless alias resolved identically
  through USB. After audio drained, wireless native capture succeeded; USB was
  then refused while wireless owned capture.
- SIGKILL of a capture host left the supervisor's lease in place. The other
  alias was refused 12 times during 20 ms polls, then admitted after cleanup and
  successfully received fresh native frames.
- Final Android display IDs equaled the initial baseline `[0]`. No owned
  forwards, scrcpy server processes or staged DroidBridge jars remained.

`broker/m6-actual-alias-runtime.json` and `broker/m6-actual-runtime/` contain the
result, actual stream/supervisor logs and cleanup evidence. Runtime harness
source is retained in `scripts/verify-companion-alias-runtime.swift` with its
private-link phone driver. This is actual Core/Streaming runtime evidence;
it is not installed AppKit UI acceptance. The test's own phone trust was revoked
through the authenticated broker. Its exact wireless alias/redirections were
removed; wireless debugging and developer-options settings were restored to
initial values, preserving the unrelated 5582 forward. The signed APK4 and
original verification fixture remain installed for subsequent QA. The companion
connection service was restored to its initially stopped state. The new DEBUG
alias marker still requires the final release-binary absence check.
