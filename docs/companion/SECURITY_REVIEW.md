# Companion security review

Status: **M0 conditional; implementation/release acceptance pending**. Independent
review on 2026-10-30. This is a live findings ledger, not an assertion that the
program has passed. Executable evidence belongs in `verification/companion/`.

## Trust boundaries

The Android application is ordinary, unprivileged software. Its loopback HTTP
service is reachable by other applications on the phone; authorized ADB forwards
also expose it to local Mac processes. ADB transport authorization does not grant
companion consent. A paired Mac is trusted for deliberately enabled capabilities,
not for arbitrary shell execution, unrelated device identities, silent clipboard
reads, automatic file execution, or every future permission.

Separate principals are: Android installation identity, explicit ADB transport
alias, approved Mac identity, random revocable trust identity, session owner and
generation, notification/action generation, and transfer owner. None may be
silently substituted for another. The current user on a compromised/rooted phone
or Mac is outside the credential confidentiality guarantee; no root is required.

The approved design uses loopback-only HTTP over USB/Android TLS wireless ADB,
32-byte expiring pairing capabilities plus visible phone approval, Keychain and
Keystore credential storage, bounded typed routes and explicit sharing. Direct
LAN plaintext, credentials in QR URLs with network destinations, bearer tokens
in argv/logs, generic subprocess routes and automatic received-file execution
are prohibited. An Android pairing QR is a two-minute bearer capability and must
be treated as sensitive, excluded from screenshots/evidence and cleared on expiry.

## Required contract corrections

1. The first transport paragraph's launcher-only coordinator contradicts the
   later cross-process broker requirement. Use one per-user broker and one
   canonical paired installation identity; wrappers register exact PID/start/
   session/generation and do not copy credentials. Local IPC must be user-owned,
   reject symlinks/foreign ownership, enforce bounded frames, and validate current
   owner before commands. A filesystem dictionary alone is not a command broker.
2. Align roadmap and wire bounds: max two active file transfers, raw chunks at
   most 65,536 bytes, thumbnail hard 64 KiB, full icon hard 256 KiB and 512×512.
   JSON/header/event aggregate budgets and decoded-image limits are independent.
3. Commands need canonical typed payloads, persisted receipt before acceptance,
   stored original result, request expiry and explicit replay policy after receipt
   eviction. Never replay an uncertain notification reply after process death.
   A 512-entry cache alone cannot promise replay rejection indefinitely.
4. Events must bind epoch and recipient trust. Restart/epoch mismatch or lost
   history requires reset/resync. Revocation checks occur after long waits and
   immediately before emitting sensitive data or publishing a transfer.
5. Notification and sharing authority is per approved trust. Phone-to-Mac shares
   select their intended recipient; all trusted Macs must not automatically read
   another Mac's clipboard, files, sessions or notification content.
6. Installer source/version/architecture/size/hash are visible. A checksum from
   the same untrusted source is integrity evidence, not origin authentication.
   No dead release URL, auto-execution, or unverified signing/notarization claim.

## Implementation findings

The initial source reviewed was untracked work on `codex/companion-program`;
findings are location/function based because concurrent implementation changes
line numbers. Closure requires source inspection plus the stated regression.

| ID | Severity / state | Finding and required closure |
| --- | --- | --- |
| S01 | High, open | `BridgeStore.command` executes side effects before durable dedupe, hashes JSONObject insertion order, stores only hash, no expiry. Test crash at every receipt/effect boundary, semantically equal reordered JSON, conflicting reuse, 513 requests/eviction, restart and stale reply; no duplicate effects. |
| S02 | High, open | `issueCredential` replaces credential for supplied existing Mac ID. Use independent random trust ID and refuse collision or visibly approve exact replacement. Test second Mac using first Mac's ID cannot displace its trust. |
| S03 | High, open | Server authenticates once before long-poll; revoked requests may later return events. Recheck trust after wait/before response and cancel active requests. Test revoke while waiting and while transfer hash/commit runs. |
| S04 | High, open | Global event history/session snapshot and `owner == phone` downloads are visible to any trust. Scope sensitive state, events, transfers and permission decisions to recipient trust. Test two paired Macs and deny cross-recipient reads/actions. |
| S05 | High, open | Notifications lack sensitive/ongoing exclusions, app filters and action generation; key-only reply may target replacement notification. Test actual hidden/private/secret notifications, access revocation and stale/replaced RemoteInput action. |
| S06 | Medium, open | Event endpoint ignores epoch; old high cursor stalls after restart. Commands/events not durable. Test restart with retained consumer cursor and terminal receipts; resync without reopening expired apps. |
| S07 | Medium, open | File staging reserves quota after copy, accepts arbitrary URI schemes, clears all records at construction. Reserve quota/admission before reading, require granted content URIs, retain bounded resumable metadata, stream/cancel and reject unknown-size overflow. Test malicious/slow provider, concurrent staging and crash resume. |
| S08 | Medium, open | HTTP parser has per-read timeout only, allowing trickle clients to monopolize all workers; long polls share same four-worker pool as control. Add absolute header/body deadline, route-specific sizes before allocation, bounded separate long-poll admission and control fairness. Test slowloris/worker exhaustion and control latency. |
| S09 | Medium, open | Swift hello lacks UUID/range validation; catalog deletion identities unchecked, envelope correlation missing, PNG header-only check, response MIME unspecified. Add bounded semantic validators and image decoder dimension checks. Test forged metadata, wrong request ID/protocol, malformed PNG and oversized frames. |
| S10 | Medium, open | Swift request cancellation can race before session assignment; unchecked shared mutable state crosses delegate/cancel threads. Use locked/actor state and cancellation latch; test cancellation before task start, midstream and repeated invalidation exactly once. |
| S11 | Medium, open | Event/receipt memory and file counts are bounded but aggregate bytes/retention and per-kind payload bounds are not consistently enforced. Test worst-case Unicode, 512 large events, persisted corrupt metadata and quota refusal without increasing caps. |
| S12 | Gate, open | No installed two-platform security/load evidence yet. All adversarial unit tests are contract evidence only. Verify packaged APK/Mac credentials, no LAN bind, exact forward cleanup, no secret/content in logs and installer trust path. |

## Release verification requirements

- Pair: expired/guessed/reused capability, phone denial, five-failure closure,
  monotonic 120-second expiry, one pending attempt, eight-trust capacity, identical
  approved poll recovery and explicit replacement. Comparison code appears on
  both devices and is not accepted as a credential.
- HTTP: duplicate Content-Length/header/query ambiguity, TE+CL, oversized/missing
  length, invalid UTF-8, malformed UUID/path, deep JSON, unknown major, redirect,
  missing/wrong credential, truncated/slow input and bounded output allocation.
- Identity/lifecycle: USB/Wi-Fi verified aliases, no duplicate audio/video admission,
  old owner generation, Mac/service death and revoke during every costly boundary.
- Content: path traversal, symlink, name collision, executable MIME, hostile URL,
  image decode bomb, chunk gap/conflict/hash mismatch, disk-full, unknown size,
  cancellation/resume and no automatic launch or clipboard overwrite.
- Privacy: notification filters and lock-screen default, explicit pasteboard reads,
  scoped recipient authorization, redacted diagnostics and no raw content captures.
- Performance: short control request must retain priority with long polls and two
  transfers active; capture p50/p95/bytes/RSS/queue bounds from raw endpoint logs.

Completion requires independent review of actual source and installed artifacts,
not agreement with a design document or a passing compilation.

## Initial executable review (2026-10-30)

`swift test --filter CompanionSecurityTests` executed eight tests with zero
failures. The tests use an actual hostile loopback HTTP peer to verify redirect
refusal, declared/streamed response byte ceilings, protocol rejection and PNG
predecode dimension/integrity rejection; other tests verify endpoint authority,
credential/header syntax, path/command/chunk admission and unpaired requests.
Log: `verification/companion/security/swift-boundary-tests.log`. These do not
verify Android behavior, valid image decoding, cancellation races or installed
artifacts. An initial truncated declared-body fixture produced a network-loss
error; the fixture now sends a complete oversized body to test the intended
byte-limit property rather than conflating truncation with oversize.

Android source changed during this review. Reinspection confirms distinct trust
IDs/collision refusal, receipt intent before effect, canonical JSON, command
expiry, event epoch/reset/recipient logic, bounded event aggregate bytes,
public-only notifications with per-trust permission and reply action IDs, and
recipient-bound file staging are being implemented. **No finding is closed yet:**
these changes still need executable regression evidence and final race review.
In particular, evicting the oldest receipt at entry 513 can still replay an
unexpired first request, dismissal still needs notification generation fencing,
and HTTP absolute deadlines/control fairness remain required. Full program
acceptance and installed security validation are pending.

## Critical rejection: loopback is not Android application identity (S13)

**High severity / release blocking, 2026-10-30.** The original HTTP-over-ADB
assumption is rejected. Any ordinary Android application with INTERNET can bind
`127.0.0.1:37841` while DroidBridge is stopped. It can impersonate hello and
collect a pasted pairing secret or a stored bearer token. USB and wireless ADB
protect the Mac-to-device transport, not the identity of the application owning
that device port. An authenticated-identity GET after sending a bearer token is
too late. A preliminary HMAC challenge followed by a separate plaintext request
also leaves a connection/ownership race. M1 trust acceptance is withdrawn until
this issue has implementation and actual malicious-listener evidence.

### Required pinned-TLS contract

The v1 API shapes and limits remain, transported using **HTTPS**, on the existing
Android loopback address/port and exact-owned ADB forward. No LAN listener is
introduced. TLS 1.2/1.3 only; no HTTP downgrade, TOFU, pinless hello, system-trust
fallback, redirects, cached credentials shared with unrelated URLs, or silent
certificate replacement.

Android creates one installation-stable EC P-256 signing key in AndroidKeyStore,
using `KeyGenParameterSpec`, SHA-256 signing permission and a self-signed X.509
certificate. Its private key is non-exportable. The certificate and key survive
service/app restart and package upgrade, not uninstall/reset. TLS server code
uses that exact alias, binds only loopback, and has a bounded handshake deadline
and bounded pending handshakes so TLS cannot exhaust HTTP control workers. No
new INTERNET server identity is accepted merely because it occupies port 37841.

The phone's trusted pairing UI presents a QR and a complete copyable URI:

```
droidbridge://pair?secret=<43-base64url>&expires=<unix-seconds>&device_id=<UUID>&server_pin=<64-lowercase-hex-SHA256-DER-leaf>
```

Exactly these four unique query fields; no destination hostname/port, fragment,
userinfo or path. The QR secret remains 32 random bytes, 120-second monotonic
window, one pending attempt, rate/capacity limits and explicit phone approval.
The pin is SHA-256 over the **entire exact DER leaf certificate**, not PEM text,
subject/CN, hello/device name or a certificate learned from the connection. Both
QR and manual import convey this pin from the phone UI; the old bare 43-character
secret entry must be rejected with instructions to copy the complete link.
Alternatively a future manual form may require the secret, device UUID and full
fingerprint entered independently. A short comparison code is not a replacement
for the certificate pin.

Mac `CompanionClient` requires an HTTPS `127.0.0.1:<owned-port>` URL and an exact
validated pin **before creating a request**. Its dedicated URLSession server-trust
delegate accepts only a server-trust challenge for this exact loopback authority,
a bounded certificate chain and a leaf whose DER SHA-256 equals the expected pin.
Any missing/wrong certificate, wrong challenge, wrong endpoint or cancellation
fails closed. Only that exact pinned leaf is a private application trust anchor;
the code must not accept an arbitrary self-signed certificate or general public
CA chain. TLS proves possession of its private key and encrypts the entire HTTP
request/response. Certificate validity/key/signature checks should use the exact
pinned anchor and an explicit policy suited to the loopback endpoint, with no
production `accept-all` helper. Self-signed deployment must be tested against
actual URLSession/Android TLS behavior rather than assumed to work.

Only after this TLS authentication may the Mac send a pairing secret, a Pairing
authorization header, a bearer token, shared content or commands. Pin mismatch
must return a specific actionable trust error; do not retry through HTTP or
replace a saved pin from hello. A non-secret pre-pair presence check may inspect
ADB package/service metadata; it cannot establish identity or authorize sending
any secret. The first trusted hello is over the QR-pinned TLS connection and its
installation UUID must equal the QR UUID before pairing. Pair approval response
must match that same UUID.

On successful pairing, save `{device_id, trust_id, credential, server_pin}` as
one Keychain record before marking paired. Independent wrappers never receive
copies. Existing legacy records lacking a pin require explicit re-pairing before
any credential is used; do not contact the endpoint with the old bearer token.
Reconnect uses the saved pin before its first request and checks authenticated
installation identity. USB/Wi-Fi aliases share this canonical pin/installation
identity. Unexpected key/installation change leaves the old credential unused
until explicit Forget + re-pair. No automatic certificate rotation is in v1.
The expected pin is public identity material but must be integrity-protected
alongside the Keychain credential; the private key/secret never enter logs,
argv, screenshots or exported diagnostics.

### Required executable closure for S13

1. Real malicious ordinary Android APK binds the same loopback port while the
   companion is stopped and serves a believable hello with the real UUID. Mac
   attempts pairing and reconnect. Attacker captures **zero HTTP request bytes**,
   pairing secrets and bearer tokens; Mac reports trust failure. A plaintext
   listener and an attacker TLS listener with a different valid self-signed
   certificate are separate cases.
2. Rebind the port between requests and between preliminary checks and pairing;
   reconnect cannot leak credentials. No challenge-only/HMAC-then-HTTP path exists.
3. The actual signed companion APK and installed Mac app pair via QR/manual URI,
   survive service/Mac restart and package upgrade with unchanged pin, preserve
   API features and meet cold/warm/transfer budgets. Stop/restart cert hashes must
   match. Both API35 and API37 peers are required.
4. Wrong/missing/malformed/duplicate pin, mismatched QR device UUID, wrong trust
   identity and pinless legacy credential all reject without Authorization or
   secret reaching any peer. A changed installation/key requires explicit re-pair.
5. Exercise TLS handshake timeout/worker exhaustion, cancellation before and
   during TLS authentication, incorrect challenge, redirects and certificate
   replacement. Verify no accept-all/debug override in packaged code.

Implementation references: [Android Keystore](https://developer.android.com/privacy-and-security/keystore),
[KeyGenParameterSpec](https://developer.android.com/reference/android/security/keystore/KeyGenParameterSpec),
and [Apple manual server-trust authentication](https://developer.apple.com/documentation/Foundation/performing-manual-server-trust-authentication).
These APIs support the design; references are not evidence that this deployment
has passed. The security reviewer must inspect final code and captured attacker
bytes independently before closing S13.

### Swift/Android integration surface and failure codes

- `CompanionPairCode` carries `secret`, nonoptional validated `deviceID`,
  nonoptional `expires`, and `serverPin`. Reject all legacy/pinless URI and bare
  secret forms before any I/O. Maximum URI 1,024 UTF-8 bytes; exact four unique
  fields; 43 ASCII base64url secret; canonical UUID; decimal finite Unix expiry
  greater than now and no more than 180 seconds ahead; exact 64 lowercase hex pin.
  The server independently enforces its monotonic two-minute window.
- `CompanionClient.init(baseURL: URL, serverPin: String, credential: String? = nil)`
  validates the authority and pin synchronously. Client sessions never learn or
  mutate the expected pin from responses. A credential setter cannot add a token
  to an unpinned client. Concurrent requests must retain their immutable expected
  pin across cancellation and connection reuse.
- `CompanionCredentialRecord(version: 1, deviceID, trustID, credential, serverPin)`
  is validated and saved atomically in Keychain. `load` returns a validated record;
  old opaque string records fail `re_pair_required` without network access.
- Failure codes: `missing_server_pin` for absent pin,
  `invalid_server_pin` for malformed fingerprint,
  `server_pin_mismatch` for a well-formed wrong leaf,
  `server_authentication_failed` for a non-TLS peer, unavailable/invalid certificate
  or unsupported authentication challenge, and `re_pair_required` for old stored
  trust lacking authenticated server identity. `unsafe_endpoint` continues to
  reject non-HTTPS/non-loopback or network-bearing endpoint parameters. Codes
  must not include certificate/private/credential bytes.
- API contract tests migrate to actual TLS fixtures with ephemeral test keys and
  their exact pins. Never add a production `allowHTTP`/`skipPinValidation` switch
  to retain the old test harness. Existing negative endpoint tests must now reject
  HTTP even on loopback. Attacker fixtures explicitly capture post-handshake HTTP
  bytes and assert zero for wrong-pin cases; a thrown error alone is insufficient.

## Pinned-TLS implementation review (in progress)

Independent rerun: `swift test --filter CompanionSecurityTests` now executes 12
negative tests, zero failures, including wrong leaf receiving no HTTP bytes,
correct pin with wrong SAN rejection, TLS-handshake cancellation, endpoint/pin
admission, redirect refusal and response bounds. Log:
`verification/companion/security/swift-pinned-tls-tests.log`. These are real local
TLS peers, not Android/device or installed-package evidence.

Source inspection confirms immutable per-client pin, HTTPS loopback-only URL,
exact DER hash check before TLS trust acceptance, the pinned leaf as sole trust
anchor with SSL server-auth policy, no HTTP downgrade, mandatory four-field
pairing URI, and one validated atomic Keychain credential/identity/pin record.
The broker learns pins only from explicit QR enrollment or accepted Keychain
records, not hello. Legacy unpinned trust refuses credential use.

Android's initial Keystore-generated certificate failed Apple server-auth trust
because it lacked the required TLS extensions. That was a real positive-path
failure, not waived by accepting arbitrary certificates or using BasicX509.
The replacement fixed-profile DER builder signs a proper leaf using the
non-exportable Keystore key: digitalSignature, CA=false, serverAuth EKU and
127.0.0.1 IP SAN. Its inputs are fixed profile fields and its output is parsed,
key-matched and signature-verified using platform X.509/JCA. Public DER/state
journaling must fsync files and parent directory before publishing its pin;
accepted ready identity changes fail closed. Android/Mac interoperability and
actual ordinary-app attacker evidence remain required before S13 closure.

An additional actor-reentrancy defect was found during review: `beginPair`
awaited connect, then read a possibly replaced current transport and checked only
public installation UUID before sending the original secret. A concurrent
unapproved enrollment could use the same claimed UUID and a different pin.
The required check binds the original requested pin **before** transmitting its
secret, not only generation after a response. Pair polling must bind original
pin/device/generation before and after each suspension. A final interleaving
regression and source reinspection are required.

## Distribution and credential continuity gate (S14)

Ad-hoc-signed immutable broker generations may have different code hashes and
paths. Generic-password Keychain default access controls must not be assumed to
permit a changed binary to load a prior credential without user interaction.
Before claiming trust survives updates, test an actual installed QA broker:
accepted pairing → same-binary restart → different-code-hash/path broker upgrade,
using only the isolated Keychain service. Record exact binary hashes and Keychain
result codes. A failed noninteractive load must remain fail-closed and explain
Forget/re-pair; retain app export choices, audio/profile settings and wrappers.
Re-pair includes explicit phone-side revocation of the previous Mac trust where
necessary. Never broaden Keychain access to every application, export a plaintext
backup or send an old credential to an unpinned endpoint to make migration pass.
Developer ID continuity may improve this behavior only when actually signed and
verified; unavailable credentials are not a reason to claim it works.

### Actual API35 ordinary-application impersonation regression

Executed `scripts/verify-companion-peer-attack.py` against exclusively assigned
emulator-5580. The installed companion APK SHA-256 was
`4707ee2032a52ed47eefb36cb80f4ba16a47b553e47a4a25bbfc6147d69ff2d3`;
Core probe `9fa0c3154788ed323c05ff661521f960a0e0dd8405bfa5e9395d69ace3806bc7`.
The genuine pinned TLS hello first succeeded, then the **same ADB forward** was
used after its device loopback port was occupied by a different ordinary APK.

The attacker had only INTERNET permission, UID10156 versus companion UID10155,
and no root or companion-private-key access. Its proper serverAuth/SAN TLS
certificate had a different pin. Pairing and reconnect attempts both rejected
with `server_pin_mismatch`, with **zero captured application bytes**. Two plain
listener attempts rejected with `server_authentication_failed`; captured bytes
were complete TLS ClientHello records only, with no HTTP or Authorization header.
Six captured raw `.hex` artifacts were independently reread, hash-checked and
fully decoded for TLS record/ClientHello framing. This audit is separate from
attacker-reported byte counters. The forward was removed exactly, attacker
stopped, and genuine service restored through its public UI.

Evidence: `verification/companion/security/peer-attack-api35/result.json`,
`capture-audit.json`, and adjacent raw captures. Credentials in this test were
synthetic isolated candidates passed over bounded stdin; **no real user Keychain
credential was accessed**. This proves the production Core transport guard on
API35, not yet an installed GUI/Keychain migration flow, API37 matrix, actor
reentrancy regression, or complete M1 release acceptance. S13 remains open until
those remaining gates pass against the packaged candidate.

The API35 attacker matrix was then repeated against a freshly built probe linked
from the frozen current production Core objects, including strict expected-IP
SSL policy. Probe SHA-256:
`7b5707022fc574b3210927e3cc228ddf120e5d55844d54d50add94187e7ad23e`.
`probe-build.json` binds 41 source/build inputs and 38 linked object hashes;
before/after source hashes matched during build and were independently rechecked
after execution. The repeated four cases passed and all six raw captures again
contained zero application HTTP bytes. Final evidence for this narrow guard is
`verification/companion/security/peer-attack-api35-current/`, including a separate
`capture-audit.json` with Client/Forward/Store/Broker source hashes. The earlier
9fa0 probe run is preserved as historical evidence; it is not used to assert the
latest host-policy behavior. This still does not substitute for packaged GUI,
real Keychain update, actor interleaving or API37 acceptance.

### Actual ad-hoc Keychain update experiment and remediation

The isolated experiment builds two real Core-linked executables at different
paths, signs both ad-hoc with the same broker identifier, verifies their
signatures and records distinct CDHashes. It touches one random account under a
random QA-suffixed service in the existing login Keychain; it does not read or
alter unrelated user records, export credentials or broaden access controls.
Secrets enter bounded stdin and never appear in command arguments or evidence.

The initial LAContext-only production behavior failed: generation A saved and
read its record, but generation B's read blocked beyond the parent's ten-second
bound. The parent killed only that owned child; A removed the exact test item
and verified `errSecItemNotFound`. Failure evidence is preserved under
`verification/companion/security/keychain-ad-hoc-update/`.

A test-only process-local noninteractive legacy-Keychain policy demonstrated a
safe alternative. Root then implemented the same public policy in the production
credential store, without widening ACLs. The subsequent experiment used actual
current production Core with **no test-only policy override**:

- A save/read returned success (OSStatus0).
- B, with a different path and CDHash, failed read promptly with
  `credential_unavailable` / `errSecAuthFailed` (-25293).
- B explicitly removed that exact item and confirmed not found (-25300).
- B saved and read a fresh synthetic replacement successfully.
- A could still remove the exact test item without reading B's credential; final
  verification again returned not found.

Evidence: `keychain-ad-hoc-update-production-policy/result.json` and adjacent
log, binding credential-store SHA-256
`8b1b2ccee1d3b010fa612040edcfcd545c23b5614ef4de0faef3357f1535e1e2`.
Source hashes remained unchanged during this run. The public legacy API is
`SecKeychainSetUserInteractionAllowed(false)`; its deprecation does not make it a
private API. It suppresses this broker process's legacy ACL interaction instead
of granting access. See [Apple's macOS Keychain implementation note](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).

This establishes that automatic credential continuity across ad-hoc updates
**must not be claimed** and that explicit local Forget can support fresh pairing
without the old executable. S14 remains open until the actual installed broker
and GUI perform local Forget → explicit phone revoke/approval → re-pair while
preserving unrelated export/audio/profile/wrapper/history state. The helper
experiment is not a substitute for that installed workflow.

The same four-case actual ordinary-app attacker matrix also passed on API37
against the installed, locally signed, non-debuggable companion0.2.0/code2 APK
`c304d5d3fc526ebdc7c4c4e16d7c92fb5e53175bfe8f913d3d131fcf097cff04`.
The freshly source-bound Core probe was
`773dfd8fee193fd1ac7a1f7040ed1593b8514b8258c73e135bbdc2ccad250982`;
manifest: `verification/companion/security/probe-build-api37.json`.
Attacker UID10237 differed from companion UID10234. Exact installed attacker APK
hash and `aapt dump permissions` proved its manifest declares INTERNET only.
Android17 additionally reports an implicit requested ACCESS_LOCAL_NETWORK entry;
this platform difference is recorded, not hidden by a relaxed permission claim.
No extra permission was granted by the test. The initial fixture assertion on
that extra requested entry failed before any forward/attacker admission and its
log is preserved; the corrected fixture independently verifies manifest, APK
hash and platform-reported permissions separately.

Final evidence: `peer-attack-api37-checked/result.json`, six raw captures and
`capture-audit.json`. Separate raw audit again found only empty wrong-pin TLS
captures or complete plaintext-listener TLS ClientHello records, zero HTTP bytes.
Current source hashes matched the build manifest after execution. Cleanup removed
only the owned forward, stopped the attacker and restored the genuine service.
Emulator5582 was explicitly handed to the macOS reviewer for installed GUI tests.
The remaining S13 gates are packaged GUI/Keychain trust/re-pair behavior and the
broker actor-interleaving regression; neither is implied by these transport tests.

## Expanded source review checkpoint (2026-10-30)

Reviewed the current canonical-alias lease, supervisor crash guard, staged
Keychain candidate saga, DEBUG-only fault/race hooks, scheduler/profile paths,
capability-gated state heartbeat, release metadata and portable ADB cohort.
This remains conditional implementation review, not installed acceptance.

The initial focused run of `CompanionPendingAdmissionTests`,
`CompanionBrokerTLSRaceTests`, `CompanionBrokerSchedulerTests`,
`CanonicalAliasAdmissionTests`, `ADBPortableRuntimeTests` and
`CompanionReleaseMetadataTests` passed 27 tests. Log:
`verification/companion/security/review-current-focused-tests.log`. It predates
subsequent cleanup/persistence fixes and must not be used as their evidence.

New actionable findings were sent directly to the coordinator:

- **S15, cleanup ownership:** Forget removed transports before a throwing
  journal publication and deferred exact-forward retirement until afterward.
  A persistence failure could therefore discard the only live cleanup owner.
  Other removal paths used `try? close()` and likewise lost failed cleanup.
  Required invariant: register a retained cleanup owner synchronously before
  removing a transport, crossing persistence or awaiting; retry failed close even
  while durable state is unavailable. Forward allocation itself must also expose
  ownership before an ADB side effect can occur, including cancellation/error.
- **S16, journal durability:** `Data.write(.atomic)` plus chmod did not prove the
  pending-admission journal durable before staging/promoting Keychain credentials.
  Require bounded private staged file, complete write, file fsync, rename and
  parent-directory fsync; injected errors must remain explicit and fail closed.
  Atomic publication/process-crash tests are distinct from power-loss claims.
- **S17, control fairness:** one global short-control lane allowed a blocked
  phone to stall other healthy phones. The contract promises per-device control
  serialization plus bounded global work. Require independent groups and a real
  TLS two-peer blocked/healthy regression, retaining aggregate admission bounds.

Root is remediating these findings. Source closure and independent regression
results will be appended rather than inferred from a proposed patch.

### TLS fixture failure diagnosis

The retained integrated full-suite run failed TLS fixture initialization in
0.155 seconds, far earlier than its three-second startup deadline. Its owned
failed directory contained a subsequently complete five-byte port file.
The fixture waited for file **existence**, then parsed it once while Python's
`write_text` could have created an empty file before writing. This was test
startup publication, not evidence that production TLS policy should be relaxed.

Normal fixture port publication is now atomic; the reader waits for a complete
valid nonzero numeric port within the original three-second bound. A deterministic
50ms incomplete-file publication regression exercises the exact prior race and
then completes a real pinned TLS request. Startup failure retains bounded stderr
in its error and stops only its owned child. The same publication correction was
applied to the multi-request broker test peer. Thirteen security tests passed:
`verification/companion/security/tls-fixture-publication-tests.log`. The original
failed integrated run remains retained; final full-suite verification is required.

### Remediation and independent regression checkpoint

S15 now registers an exact forward owner synchronously before transport removal,
throwing persistence or allocation suspension. Allocation reserves its receipt
before ADB establishment; failed close remains in a bounded retirement queue with
backoff. The independent real-TLS control test arms both journal and close faults:
Forget fails explicitly, ownership survives, maintenance attempts cleanup while
storage remains unavailable, and clearing the faults allows retirement. This is
a local DEBUG forward fixture, not an actual ADB deletion/port-rebind test.

S16 now publishes through a private `openat`/`O_NOFOLLOW` staged file, bounded
complete write, file fsync, rename and directory fsync. The source orders durable
journal publication before Keychain promotion. Independent injected failures
before writing and after file sync preserve the previous complete document;
failure after rename exposes the complete new document. Tests also reject unsafe
symlink/hardlink targets, an unprivate parent and oversized state, and check
permissions and staging cleanup. These are fault-injection and filesystem tests;
physical power-loss behavior has not been demonstrated.

S17 now uses four aggregate control lanes with one per canonical installation,
two aggregate bulk lanes, bounded profile limits and at most 64 waiting requests.
Cancellation removes queued work and relinquishes granted capacity. Actual pinned
TLS peers prove a blocked phone does not prevent a healthy phone's short control
response. This does not itself establish the program's 100ms p95 performance gate.

**S18, shutdown publication race:** an independent blocked authenticated identity
response reproduced a late admission after shutdown: the journal changed and a
new export authority appeared after the owner had stopped. The deliberate failed
run is retained at
`verification/companion/security/shutdown-late-admission-before-fix.log`.
The remediation fences connection and admission at entry and after awaited hello,
identity and alias publication, refuses publication while stopping, and retains
the broker owner lock until pending requests drain. Independent blocked-hello and
blocked-identity regressions now pass: no journal or export authority publication
occurs after shutdown. The hello case additionally proves that a saved bearer is
never sent to the identity route after shutdown begins.

The combined remediation run passed 31 tests, including the three independent
cleanup/shutdown tests, journal tests, TLS security tests and broker race/scheduler
tests. Log: `verification/companion/security/remediated-review-final-tests.log`.

**S19, credential-cohort isolation:** an unreadable or legacy pinless saved
credential previously aborted the entire saved-pin scan for a new ADB alias,
blocking an unrelated healthy paired phone. The scan now fails each record closed,
preserves its history/settings and records its repair error, while trying only
independently stored valid pins for other installations. A real pinned TLS peer
plus a separate raw legacy Keychain entry proves healthy new-alias admission and
retained `re_pair_required` status/profile for the stale installation. Log:
`verification/companion/security/credential-cohort-isolation-tests.log` (one test,
zero failures). Known aliases remain scoped to their own installation; this fix
does not accept an unauthenticated hello-learned pin.

Release remains conditional. The integrated full-suite failures are retained;
a fresh full-suite result against the final candidate is required. Installed
GUI trust/re-pair/update behavior, actual ADB cleanup failures, wireless alias
lease coexistence, source/runtime distribution binding and final installed
performance/resource gates require their own evidence. The historical API35/37
ordinary-app attacker results remain bound to their recorded source cohorts.
S07's blocking content-provider read deadline was reassigned to the Android
owner with a real stalled-pipe regression required; it is not closed here.

### Build 3 distribution review (2026-10-30)

The reviewed Swift candidate's retained full-suite output reports 277 tests,
four explicit opt-in skips and zero failures in
`verification/companion/swift-reviewed-candidate-tests.log`. This supersedes the
previous failed integrated run for that native candidate; it does not convert
opt-in device/installed tests into passes.

The actual-forward probe uses production Core objects and real ADB. Its source
and evidence were independently inspected: failed executable availability retains
both receipt and mapping; retry removes the exact mapping; a replacement mapping
is preserved; final inventory equals baseline. All 45 recorded source hashes
still matched this review's tree. Evidence:
`verification/companion/security/actual-forward-runtime.json`. This closes the
specific real-transport cleanup/rebind regression, with no claim of broker crash
recovery or physical USB/Wi-Fi coverage.

**S20, optimized release validation:** assertion-based packaging checks could be
silently disabled with `python -O` or `PYTHONOPTIMIZE`. The pre-fix successful
optimized validator run is retained at `packaging-optimized-before-fix.log`.
The six affected source/runtime/release/probe validation scripts now reject an
optimized interpreter before argument admission. Independent subprocess tests
exercise both forms against every affected script.

**S21, binary and corresponding-source cohort binding:** the source packager
previously compared ADB inventory documents without rehashing the actual app's
ADB files and accepted an old dependency-source manifest missing newly shipped
brotli/lz4/zstd. It now verifies the final app's deep/strict signature, validates
both source-runtime and packaged-runtime file inventories, and requires exact
formula/version equality with the packaged dependency origins. Independent tests
prove rejection of (a) a copied app with a valid deep signature and re-signed ADB
but its old inventory, and (b) an incomplete source formula cohort before Git
source staging. Duplicate keys and conflicting expected file hashes are also
rejected while the valid frozen runtime succeeds. Six device-free tests passed:
`verification/companion/security/distribution-adversarial-tests.log`.

The build-integrity regressions separately passed three tests, including a
same-mtime source edit, added/mode/symlink drift and embedded attribution
retention: `security/adb-build-integrity-independent.log`. Independent pristine
archive extraction plus approved patches matched four source trees (7,304,
3,515, 1,602 and 252 entries); all 1,532 published compiler/header file hashes and
16 notice hashes matched. The closure declares 81 linked static archives.
Evidence: `security/adb-source-closure-independent.json`. Its scope is source
cohort review, not bit-for-bit reproducible compilation on a second host.

The fresh build-3 dependency-source cache contains exactly 16 shipped
formula/version identities. All source archives, recipes and the x264 Git bundle
were hash-checked independently. Both packaged and outside-build copied app
signatures verified; their host/broker hashes matched. Release host/broker bytes
contain none of the reviewed DEBUG fault/extra-serial marker strings. Every
shipped ADB inventory file matches the frozen manifest
`65dfa704cbde5802fe9e7a1c44f77c9dd9943653f0b5135fa8fca7f71a5c9cc9`.
Evidence: `security/build3-distribution-independent.json`. These checks launched
neither app nor device service. They do not claim Developer ID or notarization.

Final corresponding-source archive production must use the exact committed
candidate and the build-3 cache, then be checked against the final released
artifact. No public asset was released during this review. Installed GUI
pairing/repair/update workflows remain a separate acceptance gate. S07's stalled
provider tests are still pending; the implementation bounds reader admission and
refuses late publication, but it must not promise a hard timeout for a provider
that ignores cancellation while metadata/open/close is blocked.
