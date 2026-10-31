# Android companion initial peer gate

This is executed development evidence, not release acceptance for the full companion
program. The test APK was installed on the two owned AVDs only. No physical Pixel
or user emulator was operated.

| Check | Evidence | Result |
|---|---|---|
| Pinned native Kotlin application builds | build.log | Pass |
| Pure framing/token/package/filename/hash tests | TEST-dev.droidbridge.companion.ProtocolRulesTest.xml | 5 pass |
| Android API35 real HTTP/Keystore/security tests | emulator-5580-instrumentation.txt | 6 pass,9.748s |
| Android API37 real HTTP/Keystore/security tests | emulator-5582-instrumentation.txt | 6 pass,7.185s |
| Actual Android GUI service start and notification grant | connected-api35.png/.xml,permission-api35.xml | Pass |
| Mac reaches installed foreground peer using exact ADB forward | host-http-api35.json | 20 hello requests pass |
| Device transport cleanup | final scope release | Owned forward removed, companion stopped on both |

The instrumentation exercises the real loopback HTTP server, Android Keystore,
actual Android package/icon APIs and private staged files. It verifies phone
approval before pairing, unauthenticated denial, trust revocation, per-trust event
filtering, revocation after longpoll, duplicate/conflicting/cross-trust commands,
512-receipt admission capacity without eviction/replay, expired commands, catalog
paging, epoch reset, duplicate HTTP framing, file hash/order/idempotent chunks,
filename traversal sanitation, profile changes and export choices. These are six
aggregate tests, not proof of every proposed adversarial scenario.

The first Android15 GUI capture exposed overlap with the system navigation bar.
The source now applies system-bar insets and final captures show the corrected
layout. Initial netlink-based listener inspection was denied by Android shell;
that inspection is unavailable, not a failed or passed LAN-exposure test. The
source binds explicitly to127.0.0.1 and the actual Mac-forward path was tested.

The installed APK SHA/size is in installed-apk.json. After that test build, license
assets and Gradle's distribution checksum were added; they require the next
package build. Native Kotlin code was unchanged after the final installed run.
No production/Play signing claim is made. prepare-local-signing.py supports a
persistent private local distribution identity for the eventual release.

## Remaining program gates and known first-pass gaps

* Full installed Mac broker/UI integration and two-platform end-to-end actions,
  profiles, catalog churn and icon cache/performance remain coordinated root work.
* Phone-to-Mac command feedback needs durable command receipt states and visible
  pending/applied/rejected/unknown UI. The current acknowledgement endpoint emits
  events; it does not yet persist/deduplicate those acknowledgements.
* Current phone screens need the independent UX review's named-recipient,
  connection-vs-service wording, search/favorites/icons, progress/cancel/retry and
  accurate queued-vs-applied feedback improvements.
* Binary icon/download responses currently return before the generic post-request
  credential recheck; add a final trust check immediately before writing those
  bytes. Longpoll and file commit already recheck trust.
* Dismiss identity for public notifications without reply actions needs a separate
  current notification-generation record; current reply records cover replyable
  notifications only. Actual notification/reply fixtures and app filters remain.
* Add crash/restart transfer resume, corrupt manifest/receipt failure, stale action,
  pairing expiry/rate, slow-client/control-priority and sustained-resource tests.
* Final locally signed release APK, release identity/signature evidence, licenses,
  installed copy, UI verification and the full security review remain required.

The independent reviewer may reject this milestone. Compilation and these focused
tests are not substituted for those remaining end-to-end gates.
