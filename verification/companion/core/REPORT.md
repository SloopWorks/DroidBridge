# Companion Core verification

## Availability recovery and portable ADB checkpoint (2026-10-30)

`adb-source-notice-audit.json` records the final metadata-only source/notice audit.
The runtime manifest remains byte-identical at SHA256
`65dfa704cbde5802fe9e7a1c44f77c9dd9943653f0b5135fa8fca7f71a5c9cc9`.
All seven signed runtime files are unchanged. Sixteen hashed notice files now
include fmt NOTICE, Fiat Crypto LICENSE/AUTHORS, UTF-8 Range's MIT license,
libcutils/liblog notices and embedded attribution/license comments from 1,532
actual compiler/header inputs. `SOURCE_CLOSURE.json` binds the linked graph,
81 static archives and the exact generated Abseil C++17 ABI header derivation.
Darwin ranlib container metadata changes are distinguished from ordered object
member bytes; every installed static archive must match its build's object set.

Every expanded source tree is compared with a fresh extraction of its SHA256-
pinned archive plus the approved patches before and after compilation. Unknown
files, changed bytes (even with preserved mtimes), executable-mode changes and
symlink-target drift fail closed before source admission. Three focused script
regressions pass in `adb-build-integrity-tests.log`; the real cached build and
all staged provenance/notice/closure hashes pass in
`adb-source-notice-audit-build.log`. No Core source, device or background job was
changed during this follow-up. These technical checks do not replace independent
license/distribution review.

`portable-runtime-tests.log` passes 21 focused tests: the fourteen crash/recovery
and actual mapped-process tests remain passing, with two additional portable
cohort recovery tests and five inventory/load-closure regressions. The latter
compile and sign a real dylib/client, execute the copied client after removing
its source library, reject absolute or missing dependencies, and validate the
supported arm64 slice of a universal legacy binary. Unknown bytes, signatures,
process references, corrupt receipts, and unavailable partial-copy sources remain
preserved and counted against the eight-generation limit.

`installed-availability-migration.json` records an actual isolated LaunchAgent
upgrade from eight generations of the installed 0.1.8 helper to the installed
companion QA helper. The old current generation is preserved; count stays eight;
the new PID/path and policy protocol are verified; the scoped job is removed.
This fixture uses signed compiled fake ADB binaries and explicitly does not prove
Android availability. Production user stores and LaunchAgents are untouched.
The separate old-binary version2 catalog refusal remains in `old-helper-fence.json`.

`adb-reproducible-build.log` and `adb-reproducible-repeat.log` record a clean
pinned-source build and cached repeat. Android-tools 37.0.0, protobuf 36.2,
Abseil 20260817.0 and Google's test-friend header source 1.18.0 are SHA256-pinned.
Protobuf/Abseil are statically linked permissive dependencies; libusb remains a
separate dylib. The signed flat ADB cohort has six dynamic libraries and occupies
8,910,272 bytes. Exact source archives, build recipes, patches, provenance and
static dependency notices are retained beside the build artifact.

`adb-prototype-performance.json` compares 20 isolated-PATH offline version
processes per binary. Static protobuf/Abseil reduces the prototype's dylib count
from 87 to 6. `adb-portable-performance.json` records the final portable cohort:
first invocation 9.58ms, subsequent 19 median 7.91ms and p95 11.29ms on this host.
OS caches were not flushed, so these are first/subsequent process observations,
not a claim of a fresh-boot cold-cache result. No benchmark starts a server.

`adb-helper-portability.json` executes final source ADB from both immutable
helper layouts. It validates the actual installed universal SDK predecessor,
starts only the private QA35 companion broker through LaunchAgent installation,
checks its PID/executable path and offline XPC status, verifies its checked
lifetime lease, and executes its copied ADB. Four subsequent signed-generation
upgrades wait for the exact previous owner to stop and retain at most four
cohorts. The final cycle leaves the old job stopped but its plist configured,
proving that its generation remains pinned during reclamation. All four cycles
retain exactly four generations. The exact scoped job/plist are removed afterward;
no device/server request is issued. The initial fixture readiness race is retained
separately; the corrected fixture polls only the explicit `broker_starting` state.

`portable-lifecycle-tests.log` passes25 selected tests (one existing opt-in
physical/emulator lifecycle case skipped): the late-forward cancellation fixture
now returns the actual serial/local/remote tuple, and a new regression proves
cleanup preserves another serial's or session socket's mapping on a reused port.
No production exact-identity cleanup rule was weakened to satisfy the fixture.

`adb-source-isolated-runtime.json` proves the initial source-built ADB using only
owned server port5038 with USB, mDNS and emulator scanning disabled: empty initial
device list; explicit API35 emulator5580 TCP connection; shell; 64KiB push/hash/
pull; ephemeral non-rebinding forward/list/remove; disconnect; exact owned server
termination; port closed. This precedes static dependency optimization; final
packaged source ADB still requires the product's installed emulator acceptance.

## Current pinned TLS checkpoint

`swift test --filter 'CompanionBoundaryTests|CompanionSecurityTests|AvailabilityRuntimeStoreTests'`
passed29 tests with zero failures. Current log: `tls-tests.log`. The earlier
plaintext fixture results below are historical parser regressions and do not
establish secure pairing acceptance.

Every networking fixture now uses an actual loopback TLS server and a private,
ephemeral named-curve P256 certificate with serverAuth EKU, digitalSignature key
usage and IP SAN. Production has no HTTP or unpinned test escape. Wrong leaf
tests verify `server_pin_mismatch` and zero HTTP application bytes for both
pairing-secret and saved-bearer paths. Correct pins pass real control requests;
the expected loopback hostname remains mandatory. Cancellation is exercised
before request creation, during TLS handshake and during response wait. Legacy
unpinned Keychain items fail with `re_pair_required`; new credentials atomically
store installation/trust/pin/credential together. Keychain QA suffixes remain
isolated. Tests also cover the verified whole-file transfer receipt seam.

Five runtime-store tests establish the eight-generation bound, current-generation
pin preservation, shared lifetime leases, unknown-reference refusal, post-rename
reference recheck/rollback, foreign-file preservation and identity reuse. Those
inject signature/reference seams and do not replace actual installed migration,
mapped-process or old-binary compatibility tests.

The later `availability-live-process-tests.log` passes six store tests, including
an actual mapped executable: the test compiles and ad-hoc signs its own sleeping
C helper, verifies it remains alive, fills the store to eight, and observes
preservation through the real codesign/lsof path. After stopping only that owned
process, the same generation can be reclaimed and the retained count remains
eight. Copied Apple platform binaries were unsuitable fixtures because macOS
terminated them before they could establish the required mapped-process state.

`old-helper-fence.json` executes a copied installed0.1.8 availability helper
against an isolated version2 catalog with disabled preferences and fake ADB. Its
parsed result refuses `manifest limits/version`, preserves the catalog bytes and
performs zero registrations. No production LaunchAgent/catalog was changed. The
first invalid-root fixture is separately retained. The later scoped eight-generation upgrade and crash-recovery evidence above supersedes these earlier open gates; the real user's store has not been mutated by this fixture.

The first fixture attempt failed inside Apple's memory-only PKCS12 EC import;
the final fixture keeps private keys in a temporary Python TLS server instead.
An additional fixture certificate failure used explicit EC curve parameters;
named-curve SPKI and the required serverAuth EKU fixed it. Production trust
validation was retained throughout. `tls-fixture-import-failure.log` preserves
the first failure. Actual Android KeyStore TLS interoperation and independent
security review remain required release gates.

## Earlier boundary checkpoint

Executed 2026-10-30 using `swift test --filter
'CompanionBoundaryTests|CompanionSecurityTests'`. Result:18 tests, zero failures.
Raw output: `boundary-tests.log`. These are host boundary regressions, not
two-platform or packaged release acceptance.

The new ten tests exercise positive/negative protocol version and installation
identity parsing, request correlation, response MIME, catalog deletion identity,
UTF-8 byte limits, full valid PNG decoding and malformed PNG rejection, deep JSON
and invalid UTF-8, authenticated installation/pairing identity mismatch,24
before-start/in-flight cancellation iterations, a canonical command's UUID and
30-second expiry with conflicting retry refusal, a real isolated Keychain
save/load/remove round trip, and actual subprocess argument/exact cleanup behavior
using an owned fake ADB executable. The fake foreign mapping is metadata only;
no command was sent to emulator-5554 or a physical device.

The existing eight independent security tests cover endpoint restrictions,
credentials/header injection, invalid path/command/chunk admission, unpaired
requests, redirect refusal, declared/streamed response limits, protocol rejection
and image predecode bounds. Core compilation and `git diff --check` also passed.

Implementation adds broker-only Keychain storage, exact no-rebind companion ADB
forward leasing/private receipts/recovery, public authenticated identity proof,
per-request MIME/JSON-depth/byte/header bounds, bounded canonical in-memory command
retry bodies, request IDs on the wire and response envelope correlation. URLSession
delegate callbacks use a serial queue; cancellation uses a locked latch and session
publication so cancellation before session creation cannot be lost.

Remaining release gates: actual Android peer interoperation for every operation;
security expert reinspection; packaged broker Keychain trust/restart and update
behavior; real ADB crash recovery; measured control/bulk performance; independent
wrapper session registration and alias admission. No raw content, credentials,
phone pairing capabilities or audio/video frames are recorded here.

### Monotonic clock and command admission checkpoint (2026-10-30)

The Mac/phone clock skew bug is remediated in source with `clock_anchor_v1` pinned
hello samples, conservative monotonic translation, fixed request-body expiry,
Mac boot fences, structural-only QR parsing followed by pinned phone expiry
validation, and explicit durable owner `command_admit`. Thirty seconds limits new
admission; truthful effects may finish later. Admitted owner loss or 120-second
in-flight timeout yields immutable unknown rather than replay. Selection revision
publication is durable intent; later wrapper failures preserve a pending intent
receipt. Equal revision without the exact broker row is a crash gap and cannot
repeat materialization. Terminal phone receipts retry in a bounded coalesced,
generation-fenced background task cancelled before ownership release.

Evidence: `clock-swift-full.log` records 294 passing Swift tests with four intended
runtime skips before the final coalesced receipt lifecycle changes.
`clock-lifecycle-tests.log` records 12 passing tests against the frozen checkpoint,
including actual pinned TLS blocked-receipt cancellation with no late network or
journal write, actual anonymous XPC admission/replay, atomic two-caller catalog
outcomes, and crash-gap unknown-intent behavior. Clock tests also exercise actual
TLS canonical bytes, a real 30.1-second expired retry, cancellation and changed
identity/epoch, plus pure ±24-hour skew, expiry/future/RTT/freshness/boot boundaries.
The final full run is `clock-swift-final.log`; consult its terminal result before
accepting the exact checkpoint. `clock-boundary-checkpoint.json` binds source hashes.
No installed Mac/Android or physical-device acceptance is claimed by these tests;
root owns that integration and independent security review remains required.
