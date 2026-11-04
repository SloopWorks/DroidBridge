# Companion mobile design and review contract

The Android companion uses Material 3 View components within the existing native Activity lifecycle. A blue primary color, rounded surface cards and a single receiving-Mac selector establish a consistent phone control surface. Filled primary buttons identify Start, Open, Send and Run; tonal controls carry receiver selection and utilities; outlined controls carry secondary operations. All retain 48 dp touch targets and complete wrapping labels. Material bottom navigation supplies icons and labels at ordinary font scales, with a horizontally scrollable full-label fallback at large font scales. A DayNight palette keeps backgrounds, surfaces, text and system bars readable in either mode. Native list virtualization remains in Apps; status polling preserves focused editors and scroll position.

Home exposes connection state, Quick actions, favorite app launches, named-Mac desktop presets, sessions, audio and phone-display controls. Apps offers per-Mac pinned shortcuts without rewriting the general selected Mac. Settings has system requests for both Quick Settings tiles and the home-screen widget; developer builds expose the real DebugDrawer activity.

Share review always chooses its receiving Mac inside the incoming share flow. Choosing a destination does not rewrite the general receiver. Text then chooses inbox, Mac clipboard, or (for a bounded HTTP(S) URL) explicit open. A final preview names that receiver before admission. External provider metadata is deferred until file approval. Text and file sharing never collect the clipboard in the background.

The snippets library is separate from the temporary received-text inbox. Only explicit Save creates durable encrypted text. Browse opens search without adding another editor to the main Sharing form. Pin, copy, per-Mac resend and delete remain deliberate actions. Presets select up to eight apps plus audio, performance and physical-display intent; saved presets require named-Mac review each run. A pending run cannot be repeated through the same Activity. Partial results remain visibly incomplete.

Verified incoming images decode on a bounded background pool. Files can be saved with the system picker or forwarded through a read-only content URI with temporary access. Active transfer recovery and failed-transfer resend guidance are shown alongside durable status. The existing two-file/50 MiB admission boundary remains in place.

## Executable verification

New installed-view tests in `CompanionImprovementsUXDeviceTest` exercise destination selection without changing the general receiver or admitting before consent, and search/pin persistence after Activity recreation. The existing provider-I/O consent test now selects the recipient inside the new flow before examining the final file review. Existing `CompanionUXDeviceTest` retains polling/editor and large-font navigation coverage.

Compilation and runtime results must be recorded separately. Compilation is not acceptance. Dedicated emulator `DroidBridge_API35` / `emulator-5580` only; physical owner verification remains separate.

## Executed UI evidence (2026-10-30 Pacific)

`mobile-build.log` proves debug/test APK compilation and release Kotlin compilation. `mobile-unit.log` records the passing Android JVM test task. `mobile-release-build.log` and `mobile-test-build-final.log` record signed release/test builds using the existing persistent local signer. Updates on `emulator-5580` preserved app data.

The final feature run in `mobile-instrumentation-final.log` passed 16 installed tests: four improvement UI tests (including real verified PNG/provider/batch rendering), three existing UX tests, two external-provider/clipboard-input consent tests, three Quick Access tests, and four encrypted-library backend tests. `mobile-dark-instrumentation.log` passed three dark-mode checks. `mobile-large-font-instrumentation.log` passed seven checks at font scale 1.6, including navigation, editor persistence and actual consent controls.

Repeated image verification exposed cancelled incoming rows retaining their immutable `committed` fact. The UI now requires current `received` status before offering previews or Save/Share actions. The results feed refreshes independently of the draft editor: the installed test cancels a file while keeping editor focus, then proves stale actions disappear while the exact editor instance and text survive. The earlier Quick Access failures in `mobile-instrumentation.log` are historical and were resolved before the passing final feature run.

A final navigation-only polish removed duplicate system-bar bottom padding and applied the blue palette to the active indicator and labels. Against the exact visual-cohort APK (`15f8f3e8…`), `mobile-nav-final-instrumentation.log` passed three normal-mode checks (screenshots, actual navigation, and legacy Forget consent); `mobile-nav-dark-final-instrumentation.log` passed two dark-mode checks. Both final Home screenshots were inspected and show the corrected spacing and palette. The feature, dark, and large-font runs produced 18 actual emulator screenshots under `screenshots/`; normal/dark Home, presets, Sharing, snippets and Quick actions were refreshed against that visual-cohort APK. Transfer screenshots record the preceding feature-identical candidate before the navigation-only spacing/color adjustment.

The visual cohort was copied outside the build directory to `dist/companion-improvements/`, then installed and run from those copies. Its product APK SHA-256 was `15f8f3e86af1d29555fcbecc908d273538ceea6d6e6c587f709cae9990c2f7bc`; the screenshots and mobile checks above retain that attribution.

The current final product candidate is `b6277fb903e99bb46e9bb93553de12cda6094f8d00b1abf4b700794a11254abd`. It adds narrow corrections for service-server visibility (`@Volatile`), confirmation callbacks after the Quick Access Activity is destroyed, and unavailable preset step counts. Those changes preserve the visual cohort's spacing and palette. Exact current product/test hashes, byte sizes, source hashes and timestamps are in the [final artifact manifest](../../dist/companion-improvements/manifest.json); the platform finalization also synchronizes `artifact-manifest.json`. The later receipt regression passed all three checks in [receipt-final-tests.log](platform/receipt-final-tests.log). Platform and installed Mac acceptance retain their separate results in [the platform report](platform/REPORT.md) and [installed E2E evidence](installed-e2e/); the historical visual checks are not relabeled as runs against the final candidate.

Selected screenshots for review:

- [Normal Home](screenshots/mobile-home.png): primary/tonal hierarchy and the final navigation spacing and palette of the visual cohort.
- [Verified transfer preview and cancelled history](screenshots/mobile-transfers.png): decoded image, verified-byte status, and cancelled rows without preview/share controls.
- [Dark presets](screenshots/mobile-presets_dark.png): dark surfaces, readable text and the explicit named-Mac preset.
- [Large-font snippets](screenshots/mobile-snippets_large.png): wrapped snippet text and visible dialog close action at font scale 1.6.
- [Native Android fixture](installed-e2e/native-android-fixture.png): root-owned installed Mac/video evidence, separate from the Android visual cohort.

Original emulator settings were restored to font scale 1.0 and night mode `no`. The service remained stopped at handoff. Only the dedicated emulator-5580 was modified; user emulator-5554 and other devices were untouched.
