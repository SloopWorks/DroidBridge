# DroidBridge verification report

Date: 2026-10-27. Test host: Apple Silicon/macOS 26.2, Xcode 26.2/Swift 6.2.3. Dedicated test device: Android 15/API35 AOSP arm64 emulator `DroidBridge_API35` / `emulator-5580`. Protocol/client/server pinned to scrcpy 5.0.1. Physical Pixel 10 Pro is deliberately untested pending the supplied hardware guide.

## Acceptance matrix

| Test | Backend A: scrcpy | Backend B: native | Executable / visual evidence |
|---|---|---|---|
| Emulator connection | Pass | Pass | `environment/`, `android/avd-config.ini`, live discovery test |
| App discovery / launcher search | Pass | Pass | `android/app-discovery.log`, `macos-gui-observations.md` |
| Single app launch | Pass | Pass | `fallback-gui-first.png`, `native-gui-first.png`, actual decoded frames |
| Two concurrent apps | Pass | Pass | Android displays/tasks/recordings; `fallback-gui-{first,second}.png`; independent native streams and QA AppKit windows |
| Mouse input | Pass: first OS GUI session and both independent client event paths | Pass in both isolated streams | CUA screenshots, Android display-bound input logs, `streaming/`, `review/appkit/` |
| Keyboard input | Pass: first OS GUI session and both independent client event paths | Pass in both isolated streams | Visible typed text and Android receipts; no inference from window presence |
| Independent resize | Pass | Pass | Android resize/dumpsys; fallback zoom; actual native resized frame and subsequent click |
| Activity transition | Platform supported | Pass | Real SecondaryActivity bound to second display and Back; `streaming/native-secondary-activity.*` |
| Clean window/session shutdown | Pass | Pass | Final installed normal quit, host crash, child crash: six cases passed; exact process/mapping/display baselines restored |
| Reconnection after full emulator restart | Pass | Pass | Same host survives absence and restores a new session with verified video and virtual display; `review/reconnect/` |
| Installer validation | Pass | Same application | `release/`, `review/package-final.json`; final installed hash and strict signature/dependency audit passed |

A pass above requires executed output or visibly inspected content. ADB-injected input in the initial Android milestone is distinguished from Mac-window input. Raw black host screenshots were rejected; `android/host-screenshot-black-unusable.png` is retained as failed evidence. Contact sheets are labeled as decoded stream contact sheets and are not represented as desktop screenshots.

## Native streaming and AppKit evidence

The enhanced native integration run has two independent test packages with different display IDs, separate click/text receipts, 143 distinct whole-frame SHA-256 hashes, a real secondary Activity transition, native resize to 896×640, subsequent input on that resized display, and unchanged dimensions on the other stream. The recorded run delivered 162 probe-A frames/415,425 bytes and 134 probe-B frames/588,189 bytes. A third Settings smoke shows the full settings list rather than only its splash screen. See `streaming-run.log` and `streaming/`.

Independent QA compiles the exact shipping AppKit view/controller into a real NSWindow harness. Initial QA execution verified two visible distinct windows, changing rendered pixels, NSWindow mouse/key events producing Android receipts, resize to 960×656 and fresh post-resize input. The final QA run produced 162 probe frames and 104 Settings frames. The final rerun also passed minimization, dragging, scrolling, and rapid resizing; see `review/appkit/` for the authoritative final output.

Frame delivery is bounded to one latest pending CGImage and one delivery in progress. Focused mailbox tests prove replacement/coalescing, accumulated frame/byte metrics and cancellation. Native source tests check aspect fit, letterbox rejection and drag clamping.

## Lifecycle, failure and independent review

Independent tests cover invalid package/serial/geometry before spawning, missing apps, repeated decoded start/stop cycles, cancelled startup, late forward allocation during awaited shutdown, exact dead-owner recovery, live-owner preservation, unrelated forward preservation and offline receipt retention. The supervisor was independently exercised with a real child for parent SIGKILL, helper SIGTERM, and parent absence before helper startup; exact cleanup argument arrays were recorded in `supervisor/results.json`.

Review identified and remediated orphaned children after host crashes, cleanup lost during normal quit, startup/shutdown races, and wrapper automatic termination from a main-dispatch callback. The final installed hash be59b196988bdeefd993f847d408ee7249a705102a8a03f2278cb9055a6778bd passed six installed lifecycle cases (0.289–0.628 second cleanup), actual wrapper close (8.523 seconds, exit 0), and all 24 opted-in tests (zero skips/failures, 31.163 seconds). A focused shipping-Launcher harness also proved that late startup cancellation preserves a retained disconnected intent. The independent disposition is in `review/REVIEW.md`; it has authority over broader completion claims.

## Application identity and distribution

Separate Settings and Clock wrapper processes/bundle identities and live windows were observed. Spotlight metadata indexed the Settings wrapper (`wrapper-identities.txt`, `wrapper-spotlight.txt`, wrapper screenshots). Actual Dock UI and Cmd+Tab switcher automation did not complete; those behaviors remain unverified. Final wrappers contain a copied runtime and pass their own strict signature verification; this replaced an external symlink that failed strict verification.

The release artifact contains its own ADB, scrcpy client/server, supervisor, nested player identity and recursively relinked runtime libraries. It is ad-hoc signed, not Developer ID signed or notarized. Packaged minimum: Apple Silicon/macOS 26. Signatures, dependency paths and bundled tools are audited with an isolated PATH. Public redistribution needs the corresponding-source/license work described in THIRD_PARTY.md; the deliverable is a local installable artifact.


## Final client input and resource evidence

`review/sdl-input/` verifies two byte-identical, unmodified bundled Player clients with a test-only public SDL event shim running on each client's own SDL main thread. Distinct displays 16/17 received separate clicks, text commits `1SDLFirst` / `2SDLSecond`, and raw key `k`. H.264 recordings contain 246/243 changing frames at 720×1080. Forward, reverse and display baselines were restored. This is client event-path verification, distinct from OS focus testing. The earlier CUA test independently proved actual OS mouse/keyboard input to the first fallback window.

`review/installed/results.json` records exact final-artifact CPU/RSS/process samples and cleanup for both backends across graceful quit, host SIGKILL and exact child SIGKILL. `resources/packaged-gui-live-samples.json` separately sampled one fallback session plus launcher/helper/ADB: total RSS 188.3–189.9 MiB and sampled total CPU 1.8–4.7%. These are host observations, not a portable benchmark or a long-duration soak claim.

The independent review and failed attempts are retained rather than overwritten by success claims. In particular, the initial serial-selection failure, premature reconnect failure, black screenshots and blocked OS-input experiments remain explicitly labeled. Raw recordings and generated test binaries are stored locally where applicable; reproducible scripts and compact evidence are committed.

## Remaining manual stage and disclosed limits

The sole planned manual device stage is `../PIXEL_VERIFICATION.md`. USB authorization, Pixel-specific codecs/task policy/phone-screen independence, thermals and DRM cannot be certified from an emulator. Audio, full Android-to-Mac clipboard sync, rich IME composition, Android-specific launcher icons and drag-and-drop are deferred. Host locking interrupted desktop focus/switcher automation. Public in-process AppKit and SDL tests completed without unlocking or weakening the host; those prove event routing and Android acceptance, not OS focus under lock.

## Handoff state

Independent QA approved the exact installed release above with no blocking implementation findings. The dedicated test emulator has been shut down, the pre-existing emulator remains connected, and no DroidBridge launcher, Player or supervisor process remains. The synthetic test session intent was archived and removed from the installed launcher's restoration state. See `release/handoff-cleanup.json`. The installed application is `~/Applications/DroidBridge.app`; installable DMG/ZIP artifacts and SHA-256 checksums are in `dist/`.
