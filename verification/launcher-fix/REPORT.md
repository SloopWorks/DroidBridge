# Wrapper launch and Android icon verification

Date: 2026-10-28. Release candidate: DroidBridge 0.1.1.

## Root cause boundary

The supplied Pixel/ChatGPT server log shows display creation and an application
launch request, followed by cleanup. It does not contain the initiating exit
reason or decoded-frame result. The owner subsequently supplied the matching
structured log: starting at 20:07:23 UTC, running at 20:07:25, then one
stopping/stopped pair at 20:09:08 with no failure. In this implementation running
requires an actual decoded frame. The owner confirms no wrapper window appeared,
there was no intentional disconnection, and ChatGPT works from the main launcher.
This excludes a first-frame timeout and establishes that the failure is specific
to the wrapper experience for this attempt. No physical Pixel is attached here.

Three code defects were confirmed independently:

1. A native wrapper raised its window before asynchronous startup, but never
   reactivated or raised it when the first decoded frame arrived. Losing
   activation during startup could therefore leave a working session behind
   other applications while the launcher hid itself. The wrapper now explicitly
   activates, unminimizes and raises the native session at first-frame readiness;
   reopening the Mac app focuses its existing session rather than starting a
   duplicate. This matches the reported working-stream/no-visible-window symptom,
   although the original foreground/window state was not logged and cannot be
   reconstructed conclusively.
2. An unsolicited clean session exit scheduled automatic termination of its
   wrapper, causing the Mac application and its diagnostics to disappear. The
   old wrapper did not distinguish that event from explicit close.
3. Native Swift cleanup and the independent supervisor could both remove the
   same owned ADB forward. The second removal emitted the misleading error in
   the supplied log. Historical successful sessions exhibit the same message;
   it is not evidence that ADB failed to establish the initial connection.

The implementation retains unexpected terminal sessions visibly, offers fresh
retry/fallback actions, and permits automatic termination only after explicit
close removes every session. New session admission cancels old termination
timers. The supervisor treats only its exact listener-already-absent error as
completed cleanup; other cleanup failures remain visible. Terminal diagnostics
record child exit/signal, native first-frame packet/byte/decoder counters, window
presentation facts and caller-specific stop reasons. The historical single stop
pair fits caller-driven close/quit/discovery cancellation rather than the normal
process/transport failure paths; it does not identify which caller fired. These
changes fix the confirmed presentation/disappearance/diagnostic defects. They do
not establish a ChatGPT-specific Android task or encoder defect, and the original
physical window failure still needs the owner's retest of the updated wrapper.

## Design and expert review

See `../../WRAPPER_DESIGN.md` and `icons/ANDROID_REVIEW.md`. Android itself renders
the resolved MAIN/LAUNCHER activity or alias icon, including adaptive/vector
resources. The Mac generates ICNS, sets the bundle and running application icon,
and uses separate wrapper application identities. The copied scrcpy Player also
requires the package's name/icon/identity for fallback switching. Complete bundles
are signed and verified before atomic publication; matching updates preserve
launch configuration and retain the previous generation.

## Executed evidence

- Android 15/API35 icon provider: three tests passed, including live extraction,
  malformed-image/input rejection and exact temporary-file cleanup.
- Android 17/API37 icon provider: the same three tests passed on a new dedicated
  `DroidBridge_API37` emulator, independently of the owner's existing emulator.
- After the crash-recovery remediation, the complete current icon-provider
  subset also passed on Android 17: eight tests, zero skips/failures, 16.70
  seconds (`icons/api37-final-receipt-tests.log`).
- The fixture uses a different application/INFO icon from its launcher alias;
  decoded pixel assertions prove that the launcher alias icon is selected.

- The final complete opted-in suite executed **37 tests, zero skips and zero
  failures**, in 52.38 seconds (`qa/full-suite-final.log`). It includes actual
  two-package native video, independent input/resize, first-frame exit,
  cancellation/cleanup, and icon receipt/live-owner/offline/concurrent recovery,
  delayed-writer and rotating-batch regressions. Final native metrics record
  128 distinct probe frame hashes, 163/129 frames, and independent 896×640 and
  720×1080 streams (`qa/streaming-final/`).
- The shipping AppKit-source failure harness restores a deliberately minimized
  and hidden native window at the first actual VideoToolbox-decoded frame,
  focuses the same session on reopen, preserves initiating errors, fences a
  stale quit timer, bounds/drains icon work and awaits an in-flight refresh on
  shutdown. `qa/presentation.json` reports visibility and the locked desktop's
  unavailable foreground activation honestly.
- Installed 0.1.1 was copied from a read-only-mounted DMG to
  `~/Applications/DroidBridge.app`. Its executable SHA-256 is
  `6de35eea781f59398375fe882248ec21aaab2c66be1d35963498161cec3d9c6b`.
  Strict signatures, 22 Mach-O dependency trees and isolated-PATH runtime tools
  passed (`release/`, `qa/package-final.json`).
- Actual installed icon staging followed by host SIGKILL and relaunch passed:
  a synchronized ownership receipt existed before the real ADB push, the
  successor recovered only the exact request JAR/PNG and receipt, and quit left
  no new resources (`qa/icon-crash-recovery/`). Recovery preserves active
  producers and retries bounded rotating batches on subsequent device polls.

The first complete suite failed a global-empty temporary-file assertion because
earlier aborted tests had already left files. Its output is retained. The live
test now checks its own before/after delta; independently executed host-crash
cases also reproduced the new feature's real crash-cleanup gap. Durable receipts,
producer fencing and recovery were implemented and retested, rather than treating
baseline correction alone as a product fix. The pre-recovery candidate and failed
test expectations are preserved in the clearly named earlier-evidence folders.

Compilation is not accepted as end-to-end evidence. Final independent disposition
and the remaining installed wrapper cases are in `qa/REVIEW.md` and `wrappers/`.

## Final disposition and handoff

Independent QA approved final candidate `6de35eea…` with no confirmed release
blockers. All six installed main-app lifecycle cases, two wrapper-mode child-crash
cases and actual native-window close passed. Sixty owned host/child PIDs were
absent afterward; exact crash-created icon paths were recovered, receipts and
forwards were empty, and the test emulator returned to its base display.
See `qa/final-resource-check.json` and the independent review for the full scope.

The final installed creator harness passed actual native/fallback sessions,
Android PNG/ICNS and running-application icon comparisons, separate regular
application names/identities, preserved updates/backups and malformed/unrelated/
racing/running-destination refusal. The installed executable and both generated
wrappers have identical code payloads after removing only signatures from
temporary comparison copies. The task-owned Settings/Clock examples were also
updated to the final payload without changing their launch settings.

The lead then removed only 24 exact legacy test-file paths recorded before
durable receipts existed, preserving their evidence inventories. Both dedicated
test AVDs were stopped; the pre-existing emulator-5554 remains connected. No owned
GUI process or icon receipt JSON remained. See `release/legacy-test-temp-cleanup.json`
and `release/handoff-cleanup.json`.

Existing copied ChatGPT wrappers require the one-time update described in
`PIXEL_RETEST.md`. The actual owner's wrapper and physical Pixel were not present
here, so neither migration of that specific file nor physical foreground focus
is claimed. Use the first `session_stop_requested` reason in future diagnostics;
later AppKit window destruction during quit can produce a secondary window-close
receipt.

## External verification limits

CUA reported the Mac locked. No unlock or security bypass was attempted. Direct
Dock click and Cmd+Tab switcher interaction therefore remain blocked; regular
application identities, rendered icons and live windows are checked separately.
Android 17 emulator success does not certify physical Pixel codec/task behavior
or the ChatGPT package. Wallpaper-themed monochrome icon tint is not reproduced.
