# DroidBridge companion improvements — candidate report

Status: implemented and locally packaged. The complete installed Mac/emulator
flow, including the real system Save dialog and Finder selection, passed.
Authorized Shipyard Deploy provisioning/publication remains pending. The owner
subsequently authorized Pixel installation, which passed; further hardware checks
await reconnection of its USB transport.
This report distinguishes actual installed effects, isolated component tests and
unexecuted distribution steps. It does not declare the entire goal complete.

## Deliverables and identities

- Android release: `dist/companion-improvements/DroidBridge-Companion.apk`,
  SHA-256 `b6277fb903e99bb46e9bb93553de12cda6094f8d00b1abf4b700794a11254abd`.
- Mac: `dist/DroidBridge.app`, version 0.2.0 build 16, plus the corresponding DMG
  and ZIP. The app bundles exactly that Android APK. Nested strict signature and
  portable dependency checks passed. Signing is ad-hoc, without Developer ID or
  notarization. [Package identity](package-identity.json) binds executable,
  bundled APK and archive hashes; [package log](package-reconnect-final.log) records the
  build and checks.
- [Android manifest](artifact-manifest.json) binds the final source/artifact
  cohort. Development SWIP/Drawer builds use the separate `.dev` application ID.

## Resulting behavior

| Requested improvement | Implemented behavior | Executed evidence / limit |
|---|---|---|
| Connection tile | Unlock-gated companion start/stop, truthful off/waiting/connected state | Actual SystemUI tile interaction; final installed decoded video continued after confirmed foreground service stop |
| Quick operations | Compact foreground panel with Mac selection, favorites, audio, display and session controls | Installed consent/revocation tests and rendered normal/dark/large-text UI |
| Per-Mac launches | Pinned shortcuts bind exact trust plus Android package | Actual Launcher3 pin/tap and forged/revoked identity refusal; a replacement Mac cannot inherit the old shortcut |
| Share to Mac | Recipient chosen inside the share flow; Send, explicit Copy or explicit web-link Open | Destination/cancellation tests; actual Mac clipboard match and owned loopback URL load from the packaged app |
| Faster actions | Durable command wake hints, coalesced polls and periodic recovery; cached library UI fingerprint | Actual timings below; no comparative speedup, battery or frame-rate claim |
| Notification controls | State, window count, transfer progress and direct activity actions | Actual SystemUI 25% progress and Transfers action passed in stronger platform proof |
| Clipboard library | Explicit encrypted save/search/pin/copy/delete, separate from expiring inbox | Four library tests, installed snippet UI/recreation tests; 64 snippets, eight presets and 512 KiB aggregate limit |
| Transfers | Verified image previews, grouped file batches, scoped onward read grants, explicit Mac reveal | Actual decoded PNG/UI, cross-UID granted delivery/refusal, real macOS Save dialog and exact Finder-selected file passed |
| Desktop presets | Exact-Mac review; one durable run receipt; confirmed profile, route intent, bounded launches, audio confirmation | Actual three-step profile/app/phone-audio preset applied; partial/unknown counts remain honest and uncertain effects never automatically replay |
| Home widget | Timestamped local status and favorite/action entry points | Actual bound AppWidgetHost favorite tap opened exact trust/package review; no command admitted before confirmation |
| Material UI | Material 3 controls, bottom navigation, DayNight palette and large-font navigation | 18 rendered screenshots plus focused UI/consent checks; [design cohort details](MOBILE_DESIGN.md) |
| SWIP and DebugDrawer | Actual SloopWorks libraries, typed generated schema, explicit in-memory categorical opt-in and purge | Canonical schema, three privacy tests, two actual `.dev` diagnostic/inspector tests; release DEX excludes collectors/inspector/source key |
| Shipyard Deploy | Development-only Gradle metadata, trusted dev config and signed-APK inspection | Local inspection passed; missing server-side DroidBridge project and insufficient provisioning rights prevent publication/install acceptance |

## Verification already executed

The final Swift suite passed **339 tests, four skipped, zero failures** in
160 seconds, repeated after the reconnect correction in
[the final reconnect suite](swift-suite-final-reconnect.log). The skipped opt-in checks are not
represented as passes. New profile tests cover rejection/uncertain receipts and
revocation while queued behind the actual control scheduler, before HTTP effects.

Android feature verification passed 16 installed tests, three dark-mode checks,
seven large-font checks, and five final normal/dark navigation checks. These are
separate cohorts rather than a claimed count of unique tests. Their exact visual
and product hashes are described in [MOBILE_DESIGN.md](MOBILE_DESIGN.md). The
later narrow final corrections cover destroyed confirmation callbacks, service
visibility and unavailable preset step counts; their final-candidate regression
results belong to [platform evidence](platform/REPORT.md). Build/JVM tasks passed.

Final-candidate follow-up passed four Quick Access checks including destroyed
confirmation callbacks, three receipt checks including real expiry and unavailable
preset counts, two stronger OS widget/notification checks, and five focused
security/staging checks. The latter exercise hash/order/trust/traversal,
restart/resume/cancel, durable command receipts, per-trust state, and actual stalled
provider deadline recovery. See [receipt log](platform/receipt-final-tests.log),
[OS proof](platform/strong-platform-final-tests.log) and
[security/staging log](platform/security-staging-final-tests.log). Earlier
combined-run pairing-rate-limit and RemoteViews namespace selector failures
remain retained; no production limits were relaxed to make the tests pass.

The actual onward-sharing test passed after selecting the external fixture in
Android's Sharesheet. Its separate UID read exactly 137 bytes with the expected
SHA-256 and a temporary read grant; the same receiver was refused when given
only the URI string without a grant. See [cross-UID result](integrations/share-onward.json),
[test log](integrations/share-onward-device-test.log),
[actual Sharesheet](integrations/share-onward-sharesheet.png) and
[receiver result](integrations/share-onward-external-read.png). The Sharesheet and
receiver screenshots were visually inspected. Initial raw-touch/namespace test
harness failures remain retained; product permission checks were unchanged.

The first installed Mac run used the exact build-15 executable and bundled `b627…`
APK, installed from outside build directories. Actual comparison-code approval,
pinned TLS, catalog and decoded native content succeeded. Four real phone
commands reached applied receipts, with the original Mac clipboard restored
after the exact synthetic marker check:

| Actual action | Acknowledged | Completed |
|---|---:|---:|
| Set balanced profile | 45 ms | 94 ms |
| Copy explicit text on Mac | 39 ms | 61 ms |
| Open owned loopback URL | 229 ms | 520 ms |
| Three-step desktop preset | 91 ms | 2,260 ms |

These are individual observations, not percentiles or a before/after comparison.
See [actual receipts](installed-e2e/desktop-actions.json) and
[instrumentation](installed-e2e/desktop-android-instrumentation.log).
The actual native fixture screenshot was visually inspected and the session
confirmed decoded frames. Phone file sharing reached the named Mac's actual
inbox metadata. The run then timed out selecting the system Save panel; CUA
reported the Mac locked. Its [overall result](installed-e2e/results.json) remains
**failed**, retaining successful earlier checkpoints without claiming the full
file handoff passed. The exact owned temporary pairing was revoked afterward.

A repeat exposed a real reconnect race: the wake-driven command poll could run
before the Mac's periodic device-status cache refreshed. The adapter now refreshes
that unavailable cache once, checks deadline/cancellation after the await and
resolves the current authorized device afresh. Four shipping-adapter component
scenarios passed: reconnect applies once, still disconnected refuses, expiry
during refresh refuses, and shutdown during refresh produces no effect. See
[reconnect regression](macos-component-reconnect-final/reconnect-command-cache.json)
and [final component run](macos-component-reconnect-final-run.log). The earlier
failed fixture lacked a published command owner and remains superseded harness
evidence. Build 16 contains the accepted correction; its installed run again
applied all four actual phone commands. A subsequent harness attempt to stop the
non-exported service as shell UID was correctly refused; the runner now uses the
actual foreground Stop service confirmation. The final installed subset below
passed with that supported confirmation flow.

## Final installed build-16 subset

[component-results.json](installed-verified/component-results.json) is **passed**:
the packaged executable hash matches [package-identity.json](package-identity.json),
the bundled Android APK remains `b627…`, and the latest installed test APK is
`b1aee0e064a7f73072278362470554d2ff748a1bed3e10bc5373cb678c4f0d23`.
Actual comparison/approval, pinned TLS, native first decoded content, named-Mac
file sharing and all four phone commands passed again. Final command timings:

| Actual action | Acknowledged | Completed |
|---|---:|---:|
| Set balanced profile | 55 ms | 128 ms |
| Copy explicit text on Mac | 549 ms | 573 ms |
| Open owned loopback URL | 525 ms | 571 ms |
| Three-step desktop preset | 463 ms | 2,822 ms |

These remain individual observations without a comparative speedup claim. See
[final receipts](installed-verified/desktop-actions.json). The actual Mac clipboard
matched the synthetic marker and was restored; the owned test URL was loaded.

The phone's actual Stop connection service → Stop service confirmation completed.
After that stop and native resize, two independent native sessions advanced their
decoded-frame counters from 99→186 and 267→344. Existing Android app video retained
its independent lifetime. The companion was explicitly restarted for the next
transport checks. No screenshot was substituted for decoded-frame evidence.

Three actual 2 MiB downloads matched the fixture SHA-256, taking approximately
475, 417 and 404 ms. [Transport measurements](installed-verified/actual-transport-performance.json)
use a persistent public NSXPC client through the installed broker and pinned HTTPS
to the actual companion, with 64 KiB bulk chunks:

| Measurement | Samples | p50 | p95 |
|---|---:|---:|---:|
| Warm catalog | 20 | 11.5 ms | 17.4 ms |
| Idle diagnostics | 30 | 12.2 ms | 21.6 ms |
| Diagnostics entirely overlapping downloads | 88 | 12.4 ms | 22.1 ms |
| Local status | 50 | 0.31 ms | 0.91 ms |
| Reconnect with retained pin | 5 | 412 ms | 418 ms |

The raw-download benchmark verifies actual transport and bytes; it does not save
through the system panel or invoke Finder. The final [overall result](installed-verified/results.json)
therefore deliberately remains **incomplete/false** with the exact deferred UI
reason. The exact temporary pairing was revoked successfully after the run.

## Completed system Save and Finder acceptance — 2026-10-30

The full installed build-16/b627 flow now **passes** in
[installed-system-save-final/results.json](installed-system-save-final/results.json).
CUA drove the actual macOS Save dialog: set the deterministic filename, used Go
to Folder for the owned isolated QA root, then clicked Save. The saved file is
2,097,152 bytes with SHA-256
`528d7c4ccbfb9b6c5be870818614c6bb306e726715cde1f50704f2de017697eb`.
The phone confirmed completion after verification. Reveal Saved File then opened
Finder with exactly `received-fixture.bin` selected. CUA observed the selected
row, exact file URL, matching preview and one selected item; the displayed
Finder screenshot was visually inspected.

The systems lead independently read the same actual Finder state without
changing it and recomputed the saved file's size/hash. See
[root observation](installed-system-save-final/system-save-finder-observation.json),
[independent selection evidence](integrations/finder-saved-file-selection.json)
and [independent review](integrations/INDEPENDENT_REVIEW.md). This supersedes the
earlier locked-Mac dialog gap. A first unlocked attempt timed out while CUA was
bound to an older idle host; that failed harness attempt remains retained. The
successful repeat used the exact running isolated verification host.

The full run also repeated actual copy/open/preset receipts, three hash-verified
2 MiB transport downloads and new decoded frames after foreground-confirmed
companion stop. Its exact temporary pairing was revoked after completion.

## Pixel installation and current development distribution candidate

At the owner's subsequent explicit request, normal release `b627…` was installed
in the active personal profile of the USB-authorized Pixel 10 Pro (API 37).
Version 0.2.0/code 12 launched successfully, and a pulled installed APK matched
the exact verified hash. See [physical installation](pixel/installation.json).
The phone then disconnected from USB before physical UI/pairing checks; no
test/attacker APK, service/permission/settings change or data deletion was
performed. Further hardware acceptance awaits reconnection.

The development candidate was freshly rebuilt from the current Android sources,
copied outside build outputs and inspected with the authorized Deploy CLI:
`dist/companion-improvements/DroidBridge-Companion-Development.apk`, SHA-256
`d73d3754dcd91b0c15715c0c2599bc9e9600e3bdcaf904929ad93163aa276f6e`.
All 41 tasks executed; 51 source/configuration hashes remained stable. Signature,
`.dev` package/variant identity, provenance and exact notices passed inspection.
The final exact installed development APK passed both real DebugDrawer/SWIP
diagnostic checks in 2.056 seconds, with screenshots visually inspected. The
development test build regenerated metadata; the earlier `a172…` inspection is
retained as a superseded artifact receipt. See the [final artifact receipt](integrations/development-final-artifact.json).
The release app and test APK hashes remained unchanged; both companion services
were absent and the development process stopped after verification. Deploy
doctor remains healthy, but project status still returns HTTP 404. No upload or
distribution install is claimed. See [integration evidence](integrations/README.md).

## Transfer-controller regression

The shipping Mac transfer-controller component check passed over an anonymous
NSXPC fixture: 160,123 verified bytes, retained saved destination during a refused
confirmation, identical receipt UUID on explicit retry, and no redownload.
See [final recovery evidence](macos-component-reconnect-final/verified-file-recovery.json) and
[final component run](macos-component-reconnect-final-run.log). This does not substitute for a system
Save-panel/Finder interaction or actual phone transport.

SloopWorks source revisions/artifact hashes, local Maven compatibility, actual
inspector screenshots and final release separation are recorded in
[integration evidence](integrations/README.md) and
[independent review](integrations/INDEPENDENT_REVIEW.md). Private remote Maven
returned 401; actual sibling-source builds supplied an isolated ignored local
repository. This is local integration evidence, not remote artifact publication.

## Remaining acceptance and operating boundaries

1. An authorized administrator must provision the missing `droidbridge`
   development project/channel. Inspect its notification/install ceiling before
   any publication. No build was uploaded and no unrelated project, credential
   or authorization bypass was used.
2. Reconnect the Pixel and leave DroidBridge open for the user-authorized
   physical UI/pairing checks. Installation/hash/startup passed; the other
   hardware cases in PIXEL_VERIFICATION.md remain unverified. Emulator regression
   tests still operated only on dedicated emulator-5580. Existing emulator-5554
   and 5582 were left untouched.

The implementation preserves pinned TLS, per-trust scope, immutable receipt IDs,
bounded transfer/storage limits, explicit clipboard consent and independent ADB
streaming lifetime. The working branch remains local and dirty; no push, PR,
production deployment or public release was performed. Original Shipyard's
untracked `.codex-product-onboard/` and unrelated sibling-repository work were
preserved. Final source/artifact manifest checks and `git diff --check` passed
for DroidBridge and the additive SloopWorks schema changes at this handoff.
