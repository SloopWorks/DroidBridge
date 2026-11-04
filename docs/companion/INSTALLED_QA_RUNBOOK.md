# Next installed companion verification

## Companion improvements candidate (2026-10-30)

The current improvement workstream owns only `DroidBridge_API35` on
`emulator-5580`. The API37/5582 ledger below is retained historical planning;
it does not authorize this workstream to operate 5582 or the physical phone.
Coordinate one device owner at a time, including test-APK installation.

Build the signed APK and copy it to `dist/companion-improvements/` before
packaging. Pass that exact copy as `DROIDBRIDGE_COMPANION_APK` to
`scripts/package.sh`; verify the bundled copy has the same hash. The candidate
manifest binds APK bytes and product-source hashes. Preserve earlier failed
logs and distinguish their hashes from final-candidate evidence.

`scripts/verify-companion-improvements.py` extends the installed pairing/native
launch runner with four actual phone-to-Mac commands, exact clipboard comparison
and restoration, an owned loopback web URL, preset receipts, a deterministic
2 MiB phone-to-Mac handoff, and decoded-frame continuity after the companion
service stops. It requires a fresh output directory and an existing private
mode-700 QA root. Example (replace the root with a fresh owned directory):

```sh
python3 scripts/verify-companion-improvements.py \
  --app dist/DroidBridge.app \
  --qa-root /absolute/private/qa-root \
  --output verification/companion-improvements/installed-e2e-new \
  --adb /Users/patrick/Library/Android/sdk/platform-tools/adb \
  --serial emulator-5580
```

The system Save panel and Finder selection require an unlocked Mac and real CUA
interaction. A programmatic panel-selection attempt is not that acceptance gate.
The runner prints its private destination and waits for CUA to complete the real
Save panel. `--defer-system-save` runs the independent installed transport and
decoded-frame checks, writes `component-results.json`, and deliberately keeps
the overall `results.json` incomplete. It never turns a skipped dialog green.
The first run reached actual applied command receipts and native decoded content,
then timed out selecting the Save panel while the Mac was locked. Its overall
`results.json` remains failed; successful preceding checkpoints are recorded
separately and must not turn the complete flow green.

The subsequent unlocked run in
`verification/companion-improvements/installed-system-save-final/` passed the
complete flow. CUA completed the real Save panel, the script verified the saved
2 MiB file and phone completion receipt, and an independent reviewer observed
the exact selected file in Finder. Bind CUA only after the isolated host is
actually running: an older idle DroidBridge process at the same bundle path can
otherwise receive the automation binding. Close only a positively identified
idle host through normal Quit; never terminate unrelated active sessions to
resolve a tool-selection ambiguity.

The owner later explicitly authorized installing the verified release on the
Pixel. That personal-profile install, pulled APK hash and startup passed; the
USB transport disconnected before further physical UI/pairing. See
`verification/companion-improvements/pixel/installation.json` and
`PIXEL_VERIFICATION.md`. This specific authorization does not broaden the normal
emulator regression runner's scope or permit personal-data/permission mutations.

`scripts/verify-companion-gui.sh` uses the shipping AppKit/controller code over an
anonymous NSXPC fixture, with Android tools disabled. Its verified-file recovery
check proves destination retention after local publication, explicit receipt
retry with the original UUID and no redownload. It does not prove system-panel
interaction, Finder selection or live-phone transfer.

Final acceptance and external distribution status live in
`verification/companion-improvements/REPORT.md`.

## Retained API37 verification plan

This is an execution plan, not acceptance evidence. Use a fresh
`verification/companion/installed-api37-build3-*` directory and retain failed
attempts. Only the coordinated owner may operate `emulator-5582`; `5580` belongs
to a different workstream. Never use the physical Pixel or `emulator-5554`.

## Admission and recording

1. Receive the explicit device handoff, frozen APK hash and installed Mac artifact.
2. Verify bundle version/build, strict nested signatures, executable/APK hashes
   and the portable bundled ADB dependency inventory. Keep the build-2 app intact
   until the replacement artifact is validated.
3. Use the existing private mode-700 `--companion-qa-root` and exact `--serial`.
   Record hashes of retained profile/export/settings files. Never export Keychain
   values, a full pairing link or an enrollment QR. Enrollment captures remain
   only under ignored private QA storage and are deleted after use.
4. Launch with `--companion-launch-trace` for bounded local phase/decoder metadata.
   The flag requires the explicit isolated scope; no screen/input/clipboard
   content belongs in its trace. Test paths and managed wrapper output must stay
   beneath the QA root. A shipping wrapper is launched with explicit QA arguments
   during these tests, so an ordinary Finder launch cannot escape isolation.
5. Drive actual native controls and WindowServer focus through CUA. Public
   AppKit observations/captures supplement those actions; direct NSView input
   calls are component evidence and never substitute for keyboard-focus gates.

## Flow ledger

| Case | Actual action | Completion evidence |
|---|---|---|
| C03 image enrollment | Phone creates a fresh QR; private PNG is chosen using the real Mac Import QR Image panel and Go to Folder; compare and approve | Same named peer/comparison, approved credential stored, authenticated catalog; no QR/link in published evidence |
| C15 update recovery | Start new ad-hoc broker against retained saved trust; exercise actual failure/recovery UI when applicable | Bounded actionable refusal or authenticated success; explicit Finish/Forget if needed, no prompt/retry loop; retained profiles/exports unchanged |
| C04 initial catalog | Install Input Alpha v1 and Beta v1 only after handoff; refresh paired catalog | Real labels/icons/packages and generation; bounded native search |
| C04 delta | Close Alpha, upgrade its same-signed v2 APK (changed label/icon), query/refresh delta, then remove owned test package when appropriate | New generation and changed icon SHA/label; deletion represented explicitly; another app unchanged |
| C05 export | Select only purpose-created Alpha/Beta wrappers through native Apps controls; wait for owner receipts and helper protocol admission | Exact managed records, valid signatures/Android icons, paths confined to QA root, visible eligibility and truthful completion |
| C05 unavailable/disabled | Stop only the companion service or disconnect its channel; separately test explicit deselection and ADB availability using owned scope | Document which authority controls each state; accepted running sessions survive; disabled wrapper admission and visibility verified independently, without claiming instant Spotlight eviction |
| C06 phone open/favorite | Select trusted Mac; favorite Alpha; tap Open on phone | Actual new Mac window and owner-applied receipt; favorite persists through refresh/restart |
| C06 bootstrap | Register installed host once, quit main GUI, keep independent wrappers if needed; phone opens a different app | Broker validates and starts registered installed host, waits for registration, then real window; no caller-provided path or permanent launcher-unavailable result |
| C07 independent owners | Run Alpha/Beta as distinct signed wrappers; quit main launcher; inspect phone dashboard | Distinct bundle IDs/PIDs/window numbers and correct app names/icons in Mac switching; exact owner registry |
| C07 stop all | Phone confirms Stop All for the selected Mac with two wrapper owners | Both exact owners terminate sessions, aggregate applied only after completion, unrelated phone/device untouched, no orphan displays/forwards |
| Input native | Activate Alpha with actual CUA; type a unique Alpha token; activate Beta and type a different token; click counters, resize, alternate focus | Each visible echo/counter stays in its own window, state survives resize, keyboard absent; native key/main/active/window facts correlate with real typed effects |
| Input fallback | Repeat two-app focus/key/click/resize using actual SDL Player windows | Actual live content and input, correct owner/player identities and cleanup; do not infer from native tests |
| C08 audio | Phone selects Phone, Mac, Mac + Phone, and Retry Mac Audio while wrappers own sessions | Desired route and real owner-bound audio status; fresh retry action, exact-device coordination; samples/output initialization distinguished from physical listening |
| C08 screen | Phone explicitly turns its primary display off/on while two Mac sessions run | Primary display state observed, native frames/input continue, virtual displays not powered off, exact device only |
| C11 phone-to-Mac clipboard | Fixture explicitly copies sentinel; companion explicitly sends current clipboard; Mac explicitly copies received item | Exact sentinel in selected destination only after each user action; no idle clipboard read |
| C11 Mac-to-phone clipboard | Create deterministic Mac sentinel, explicitly Send Clipboard, phone explicitly reads/copies it into fixture | Exact expected text at phone destination; clear direction/consent; snapshot/restore any test pasteboard use |
| C12 permission/filters | Explicitly enable Mac banners and phone notification listener using native/platform UI; select only fixture app | Actual grant/deny state, selected trust and allowlist; new trust defaults off |
| C12 lifecycle | Fixture posts public reply/nonreply/private notifications, replaces and clears them | Correct permitted update/removal, private exclusion and nonreply affordance; no blanket success from one posted item |
| C12 reply | Reply once to the actual permitted notification, then attempt a stale/replaced action | Fixture RemoteInput delivery counter increments once with exact deterministic reply; stale action rejected and no duplicate on retry |
| C13 profiles | Apply battery/balanced/responsive through UI; launch fresh changing-content sessions for each | Actual server argv and descriptor use 15/30/60; bounded decoded-frame samples give observed rate; existing windows retain prior ceilings |
| Cold startup | After all builds stop, run interleaved connected/disconnected cohorts on the same installed executable | Process-spawn→preview and first-video n/p50/p95 separately; phase attribution, host load, preserved 100 ms cold-preview target failure unless actually met |
| Final cleanup | Quit actual GUI and wrappers; retain scoped broker only if next test needs it | No active sessions/native/audio receipts; every remaining forward matched to its exact live broker owner, no other device changes |

## Fixtures and helpers

`python3 scripts/build-desktop-input-fixture.py` builds only. Its three signed
outputs are under `.build/desktop-input-fixture/`; do not install or upgrade any
fixture while another agent owns the device. Existing
`dev.droidbridge.companionfixture` supplies actual share intents, private/public
notifications and RemoteInput receipts. The new Alpha/Beta fixtures provide
independent editable windows, counters, normal IME behavior and explicit
clipboard actions. Their APKs never ship inside the product.

`verify-companion-installed.py` covers installed setup, full-link enrollment and
native first-frame startup. Image-picker completion uses real CUA controls rather
than the observer's unreliable programmatic NSOpenPanel selection. Keep its exec
session alive while continuing tests; completing a short command can reap child
apps. `verify-companion-performance.swift` measures actual IPC/pinned HTTPS and
bulk boundaries. `verify-companion-preview.py --trace` records interleaved cold
preview/video cohorts and phase attribution, with a separate target result.

For C13, use `qa_video_metrics` events from the actual installed native session:
drop startup/resize intervals, calculate frame deltas over multiple seconds and
report n and elapsed boundaries. The source-motion counter alone is not decoded
FPS. A configured 60 ceiling is not a promise that a loaded emulator emits 60.
Never convert missing output into zero or infer battery savings from a profile.

The ledger must distinguish pass, fail, blocked and untested. Compilation,
fixture assertions, Android API-only tests and installed GUI evidence remain
separate. Final physical Pixel verification is still the owner's last manual
stage; everything possible on the owned emulator remains agent work.
