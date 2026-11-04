# Cross-system independent review

Reviewed actual Android library/store/transfer/provider changes, Swift action
validation, broker admission/registry/profile handling and desktop execution.
This is source and evidence review of the working candidate, not a release or
live-distribution acceptance. The root agent owns final candidate verification.

## Findings

1. **Resolved in inspected source:** preset execution previously discarded an
   unconfirmed audio result and could report complete before audio was checked
   after opening apps. It now saves route intent before launches, verifies output
   afterwards, and reports `preset_partial` when output is unavailable/unconfirmed.
2. **Resolved in inspected source:** receipt timing previously mutated the live
   outcome before result validation. Timing is now copied/staged and attached only
   after all summary validation. A malformed-result regression test was added.
3. **Resolved and regression-verified:**
   `command_profile_commit` now fences the exact admitted command, trust/epoch,
   enabled scope and transport generation inside the scheduler control closure,
   after lane acquisition and before HTTP, and repeats relevant scope checks after
   HTTP. The previous pre-lane-only guard could send through a revoked old client.
   `testRevocationWhileQueuedCannotSendProfileThroughCapturedTransport` passed
   in `swift-suite-final.log`, which reports 339 tests, 4 skipped, zero failures.

4. **Resolved in inspected source:** preset outcomes with an unavailable step
   count previously rendered a false zero through `optInt`. They now explicitly
   say "Completed step count unavailable"; known counts retain their exact value.

5. **Resolved and regression-verified:** command wakeup could precede the
   adapter's periodic status refresh after reconnect, rejecting an admitted
   command against a stale disconnected cache. The adapter now validates the
   generation and continuous deadline before one bounded status refresh,
   rechecks cancellation/shutdown/deadline after it, and resolves the phone and
   aliases afresh. The independent authorized launcher-device guard remains.
   `macos-component-reconnect-final/reconnect-command-cache.json` and its run log
   pass all four shipping-adapter/anonymous-NSXPC scenarios: stale false-to-true
   commits exactly once; still disconnected, expiry during refresh and shutdown
   during refresh commit zero effects. The fixture first establishes an actual
   published command owner, then stages the stale cache; its successful case
   asserts one cache refresh plus the existing post-commit refresh. The earlier
   `macos-component-final-run.log` timeout is retained as failed harness evidence,
   superseded by `macos-component-reconnect-final-run.log`. The full Swift suite
   also passes after this source change: 339 tests, 4 skipped, zero failures in
   `swift-suite-final-reconnect.log`. These are component/regression results;
   final installed-package execution remains owned by the root agent.

## Requirement-to-evidence assessment

| Feature | Evidence strength / remaining check |
|---|---|
| Connection enable/disable tile | Actual system tile interaction/logs; selected Mac freshness and independent service lifetime explicit |
| Quick operations panel | Actual foreground consent tests, accessibility and installed screenshots |
| Per-Mac pinned app shortcuts | Actual launcher pin flow; exact-trust/revocation refusal tests |
| Share destination + Send/Copy/Open intent | Actual consent cancellation/destination preservation; installed Mac copy/open e2e owned by root |
| Action latency | Bounded monotonic receipt fields + payload-free wakeups with periodic recovery; speedup requires comparison, not inferred from instrumented timing |
| Notification actions | Actual notification/panel controls, private lock-screen visibility; no notification trampoline |
| Saved clipboard snippets | Encrypted storage/restart/capacity + actual UI search/pin; explicit foreground clipboard access |
| File previews and grouping | Real verified provider bytes, decoded installed thumbnail and grouped status |
| Share onward | PASS: actual product touch → system Sharesheet selection → separate ordinary UID reads exact bytes/SHA with a temporary grant; direct no-grant read refuses with SecurityException; screenshots inspected |
| Reveal in Finder | PASS: installed flow executes Reveal; independent read-only Finder AX observation confirms selected `received-fixture.bin` at its exact owned QA URL, with one item selected |
| Transfer recovery | Existing immutable transfer journals/checksums/cancellation remain; installed Save publishes exact verified 2MiB bytes/SHA, while the component recovery fixture verifies pending receipt/same-UUID retry without re-download |
| Desktop presets | Validation, exact pinned recipient, truthful partial receipts and profile refusal covered; actual multi-step Mac execution owned by root |
| Home widget | Actual AppWidgetHost binding/action proof and local snapshot timestamp |
| Material UI | Actual installed light/dark layout screenshots and native control tests, subject to final latest test results |
| SWIP + DebugDrawer | Canonical schema check, 3 privacy tests, generated snapshot, actual source artifacts; latest final `.dev` APK passes 2 emulator diagnostics tests in 2.056s with exact installed artifact/test hashes and visually inspected real-touch inspector |
| Release separation | Resolved runtime graph and final product APK DEX exclude SWIP/Drawer/inspector/dev source key; exact APK SHA is recorded in `release-diagnostic-boundary.json` |
| Shipyard Deploy | `.dev`-only build metadata/signature inspection passes; no project registration/publication/install acceptance due admin-only provisioning refusal |

## Policy and artifact audit

The Deploy config selects only `dev.droidbridge.companion.dev` / `development`,
uses the existing trusted development server and NOTIFY routing, and contains
credential references only. An initial onboarding command can create its main
channel with AUTO_INSTALL_WHEN_ALLOWED, so inspect/lower the server ceiling before
any eventual publish. Current onboarding did not create the absent project.

No new APK, AAR, JAR, native library, keystore or signing-key files are in the
untracked delivery set. Library artifacts are built from actual sibling sources
into an ignored isolated repository; generated Kotlin is an exact compiler-output
snapshot, not binary vendoring or a replacement schema. A structured JSON scan of
new evidence found no non-redacted secret/credential/token string values. Existing
TLS pinning, ADB loopback, scope receipts and release application identity remain.

All five source findings are resolved. External share-onward acceptance is closed
by actual separate-UID delivery/refusal proof. The subsequent installed Mac
system Save/Reveal flow passes in `installed-system-save-final/results.json`;
this supersedes the earlier locked-Mac attempts. Root performed the actual
NSSavePanel interaction, and this independent reviewer then observed Finder's
selected row through CUA without clicking, opening a file or navigating.
`finder-saved-file-selection.json` records only the owned QA selection and confirms
the saved file has exactly 2,097,152 bytes with SHA-256
`528d7c4ccbfb9b6c5be870818614c6bb306e726715cde1f50704f2de017697eb`,
matching the installed-flow handoff. Finder's selected item's URL points to
`.build/companion-improvements-qa-system-save-final/received-fixture.bin`.

Deploy administrative provisioning remains outstanding. Do not convert local
build/test consistency into a published or installed distribution claim. Physical
Pixel installation/acceptance is tracked separately in the root-owned delivery
report; this audit adds no physical-device instrumentation.
