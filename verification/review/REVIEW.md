# Independent engineering review

**Verdict: PASS for local emulator delivery and the owner's physical Pixel verification stage. No blocking implementation findings remain.** The optional OS-switcher checks and the host-lock limitations below remain explicitly unverified.

Reviewed final installed Mach-O SHA-256:
`be59b196988bdeefd993f847d408ee7249a705102a8a03f2278cb9055a6778bd`

Reviewer: independent QA specialist, 2026-10-27. Compilation alone was never accepted as functional evidence. The final artifact was copied from a read-only-mounted DMG outside the build directory and exercised using its bundled runtime.

## Final executable evidence

| Check | Result | Evidence |
|---|---|---|
| Complete unit/live emulator suite | 24 passed, zero skipped, zero failures; 31.163 seconds | `full-live-suite.log` |
| Native concurrency, input and transitions | Two distinct packages/displays; changing decoded frames; independent click/text receipts; real secondary Activity; resize and post-resize input; clean stop | `full-live-suite.log`, `../streaming/` |
| Shipping AppKit view/controller | Two live NSWindows; actual rendered PNGs; NSWindow click/text/drag; Android scroll; minimize/restore; rapid resize; correct resized input | `appkit/` |
| Installed host crash, normal quit and exact child crash | All six cases passed across both backends; child failure left host alive and terminal session visible; exact processes/mappings/displays restored | `installed/results.json`, session/server logs |
| Final installed cleanup timing | 0.289–0.628 seconds across six cases | `installed/results.json` |
| Actual-Mach-O wrapper close | Strict-signed self-contained QA wrapper decoded live Settings, received public NSWindow.performClose, exited normally in 8.523 seconds, and cleaned up | `wrapper/results.json` |
| Actual emulator shutdown/reboot and automatic restoration | Both backends: same host survived six seconds without emulator; new session/display restored after boot; native decoded-frame and scrcpy live Texture/decoder evidence required | `reconnect/results.json`, original/restored logs |
| Late-start cancellation race | Shipping launcher with delayed fake ADB retained disconnected intent after late cancellation; no device used | `launch-race/run.log` |
| Startup/receipt safety | Late forward allocation awaited before shutdown return; exact serial/socket recovery; live owners and unrelated mappings preserved; offline receipts retained | `startup-race.log`, `recovery-tests.log` |
| Renderer backpressure | One pending newest-frame delivery; dropped presentation frames counted without retaining an unbounded task/image queue | mailbox tests in `full-live-suite.log` |
| Bundled runtime portability | Deep/strict ad-hoc signature; 22 Mach-O dependency trees resolve to system or bundle-local dependencies; isolated-PATH adb, scrcpy and Player versions pass | `package-final.json` |
| Generated wrappers | Settings and Clock independently pass deep/strict signature verification; unique bundle/process identities and Spotlight metadata verified | `../wrapper-identities.txt`, `../wrapper-spotlight.txt`, `../release/wrapper-refresh.txt` |

The AppKit harness delivered 162 probe frames and 104 Settings frames in its recorded run. Installed process snapshots observed roughly 112 MiB native-host RSS and 98 MiB fallback-host RSS; complete CPU/RSS samples are retained rather than presented as a benchmark.

The fallback's first window received real CUA mouse/keyboard input before the host locked. Additional independent client-path evidence is in `sdl-input/`: two unchanged bundled clients produced display-bound click, text and ordinary raw-key receipts on displays 16/17; recorded 246/243 real H.264 frames; changed visible content between 1s/7s; and restored all resource baselines. I independently read the Android receipts and visually inspected the second client's frame showing click 1 and `2SDLSecondk`. The test-only public SDL events exercise the unmodified client input/coordinate/control path, and are explicitly not proof of OS focus while the desktop is locked.

## Findings remediated before acceptance

- External processes could outlive a crashed GUI. An independent C supervisor now owns exact child process groups, monitors parent lifetime and cleans up exact native resources. Real installed host/child crash tests passed.
- Normal quit could exit before detached cleanup completed. AppKit delayed termination and stopAndWait drain processes, in-flight startup and cleanup. The delayed-forward regression and normal-quit tests passed.
- Explicit serial launches initially queried the first device before honoring the target. The failed launch and observed wrong-device process are retained in `installed-initial-serial-*`. Explicit selection now precedes app discovery, with no missing-target fallback; installed cases passed afterward.
- Real reboot initially consumed the reconnect edge before package services existed and never retried. Original failure evidence remains in `reconnect-initial-boot-race.log` and `reconnect/initial-failure.txt`. Readiness now requires boot completion and package service; interrupted intent survives stable device lists and finite retry polling. Both actual reboot replays passed afterward.
- A late cancelled GUI launch could overwrite the retained disconnected marker. The catch now preserves that marker; the focused shipping-launcher race harness passed.
- Wrapper close could hang in a nested termination loop. A public run-loop callback now initiates termination; actual final-Mach-O close passed. Wrapper external-runtime symlinks also failed strict verification; wrappers now seal independent runtime/license copies and pass strict checks.
- Native frame delivery could retain every queued image while the main thread was blocked. The bounded latest-frame mailbox passed scheduler/race tests and real streaming regressions.

An initial post-resize test incorrectly expected counter 2: Android recreated the test Activity and reset its unsaved counter. The real second click receipt was present. The harness now clears logcat after stable resized frames and requires a fresh correct-display receipt; this is a corrected test expectation, not a product bypass.

## Explicit limits

Black screencapture images were rejected as visual evidence. Valid CUA screenshots, actual AppKit rendered-view PNGs and recorded/decoded Android frames are retained separately.

The locked desktop prevented acceptance of second-window OS focus, actual Cmd+Tab selection and Dock-click switching. Targeted CGEvents had no Android receipts. Cocoa experiments produced dual-display clicks but their expected alphabetic text commits were inappropriate for scrcpy's default mixed mode, which intentionally filters alphabetic TEXT_INPUT events; this was not a product defect. The successful SDL test uses digit-leading commits and a separate raw `k` key to cover both actual client paths. No host-unlock bypass was attempted.

The artifact is locally installable and ad-hoc signed; it is not Developer-ID signed or notarized. It requires Apple Silicon/macOS 26. Public redistribution still requires corresponding-source/license compliance for bundled GPL-enabled FFmpeg and Android SDK components. Audio, full bidirectional clipboard, advanced IME composition, drag/drop and extracted per-app icons remain outside verified scope. Physical Pixel 10 Pro behavior remains the owner's supplied final verification stage.
