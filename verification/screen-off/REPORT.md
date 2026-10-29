# DroidBridge 0.1.4 build 9 — final verification

Approved by independent QA and macOS/Android experts. The release DMG was
mounted and installed outside the build directory at
`~/Applications/DroidBridge.app`. Exact installed executable SHA-256:
`3f3b6245a37fe1513250a60b605f5033712f585df2ff0e78124105fe6cdd06f9`.
`release.json` binds 43 production inputs, the installed bundle/helper/seal and
release artifacts; `SHA256SUMS` contains DMG and ZIP checksums. The app is ad-hoc
signed, not Developer ID signed or notarized.

## Delivered behavior

- Existing managed apps receive clean filenames automatically. Unique names
  contain no hash; real same-device collisions use readable package qualifiers.
  The compatibility pass upgrades old copied executables before changing names.
  Saved Android icons, complete launch options, identities and original backups
  are preserved. See [name migration evidence](../clean-app-names/REPORT.md).
- Physical phone-screen control is off by default and remembered per device.
  The checkbox applies during Mac sessions; explicit Phone-menu Off/On actions
  control the selected/focused device. Closing windows deliberately keeps the
  phone off. Explicit On clears saved intent and verifies restoration/wake.
- Both virtual-display backends keep their own displays active and place the
  IME locally, without changing global stay-awake/timeout settings. Android17
  reset/wakeup and Android15's unadvertised legacy commands are handled with
  strict actuation and actual display-state verification.
- Fallback startup uses distinct leased ports and a per-device gate through the
  expected package launch receipt. The supervisor retains its port lease through
  host-crash cleanup. A launch receipt is not itself video evidence.

## Executed checks

| Check | Result | Evidence |
|---|---|---|
| Full final suite | 121 tests, four explicit hardware skips, zero failures | `unit-final.log` |
| Independent power/race regressions | 14 passed; both intent directions, cross-process mutex, device isolation, AOD, cancellation, API differences, false-success refusal | `qa/core-tests.log` |
| Installed GUI Android15 | Real checkbox/menu Off/On and changing native content while off; graceful exit and cleanup | `qa/installed-api35/result.json` |
| Installed GUI Android17 | Same controls/video plus second-device physical-state/preference isolation | `qa/installed-api37/result.json` |
| Failed On retry | One injected transport failure; visible retry, cleared intent, subsequent real On | `qa/installed-api35-on-retry/result.json` |
| Saved intent across relaunch | Two exact installed-app launches automatically turn panel off; decoded video, graceful quit, panel remains off, resources restored | `relaunch/result.json` |
| Real Core Android17 commands | Six paired process races; asleep reset/wakeup; actual final state and unchanged global settings | `core-real/emulator-5582/result.json` |
| Native Android15/17 | Two simultaneous changing streams, mapped clicks/text, resize while off, independent close and cleanup | `android/api35-production-local-ime/native-results.json`, `android/api37-production-local-ime/native-results.json` |
| Fallback Android15/17 | Two real clients, actual recorded changing frames, mapped clicks/text/raw keys while physical0 off, cleanup | `android/api35-local-ime-clock-corrected/external-results.json`, `android/api37-local-ime/external-results.json` |
| Concurrent production fallback | Concurrent shipping Session starts, distinct ports/displays, exact per-display input, physical0 off through idle/input/close, resource cleanup; video samples 37/33 and 24/14 frames/distinct hashes | `concurrent-fallback/result.json`, `concurrent-fallback/frames.json` |
| Installed runtime | Strict signatures; 23 Mach-O trees; isolated-PATH bundled tools | `package-final.json` |
| Final offline availability | Owned emulators stopped, 16 accepted build9 apps retained privately, zero global Spotlight matches; user5554 preserved | `final-state.json` |

The Android experiment isolated keyboard routing by fallback failure → local
IME success → fallback failure on the same stack. Initial failures remain
recorded. The production fallback test also exposed a test-coordinate mistake:
resizing to480pixels wrapped the probe title and moved its EditText; clicking
the old295pixel coordinate hit a gap. The corrected fixture uses the original
probe aspect/size and actual display geometry. That failed assertion and image
remain in `harness-geometry-failure.*`. Earlier fallback startup failures are
retained separately. Recordings use a test proxy that only adds recording/debug
and public SDL event instrumentation around production-generated arguments;
they are not an uninstrumented physical keyboard test.

## Independent review and boundaries

See [QA approval](qa/QA_REVIEW.md), [macOS review](MACOS_REVIEW.md), and
[Android findings](android/ANDROID_REVIEW.md). QA independently checked the exact
installed SHA and all 43 input hashes. No physical Pixel was connected; the Mac
desktop was locked. Real AppKit target/actions and video captures do not prove
physical OS focus, Dock clicks or Cmd+Tab interaction. Hardware panel/PIN behavior
remains the owner's `PIXEL_VERIFICATION.md` stage. Screen controls do not unlock
Android or bypass secure-content capture restrictions. Pending failed On actions
retry while their owning host stays open; quit cancels that work. Old main app
versions must be quit before installing; running wrappers wait for update.
