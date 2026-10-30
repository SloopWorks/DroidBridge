# DroidBridge 0.1.5 build 10 — launch UX verification

Final installed executable SHA-256:
`cc84835c5cc57fc4d3807509d7fb4b478b8dc9a3074d913e96247fe03460bb7c`.
The release DMG was mounted and copied to `~/Applications/DroidBridge.app`.
`release.json` binds 49 production/build/resource/document inputs, five installed
files including the bundle seal, and both release archives. Independent QA
recomputed every hash with zero mismatches. Signing is ad-hoc; no notarization
or Developer ID claim is made.

## Delivered behavior

Wrapper startup immediately presents a local loading window containing the saved
Android launcher icon, app name, spinner and connection progress. It does this
before recovery or Android I/O. The main launcher remains hidden. The saved
package launches directly, avoiding full application enumeration and icon work.
Authorization, boot readiness and managed-app admission still run.

The native backend attaches to that same NSWindow. Size and position restore
through per-device/package AppKit autosave; setup cannot overwrite the saved
frame, and removed-monitor geometry is constrained to an available screen.
Attaching and receiving video do not undo a minimize or steal focus. Reopen
reveals the same window. Closing during admission or first-frame startup fences
late work and releases the owned session.

Initial solid-black frames retain the branded splash. A bounded thumbnail check
is a presentation heuristic, not proof of Android capture restrictions. After
five seconds of blank video, an explanation and **Show Android Screen** button
allow deliberate access to a legitimate dark stream; visible frames also clear
the notice automatically. Input cannot pass behind the loading/status screen.
The compact notice/button layout is verified at 240×208 content points.

Fallback retains a loading host until the expected package launch and actual
client Texture receipts arrive. Its unchanged client gets line-buffered output
through the supervisor's raw PTY, with bounded nonblocking relay and existing
process-group/port ownership. Pinned scrcpy rejects window width/height flags
with flex-display, so initial content dimensions use new-display instead.
Exact-child public WindowServer metadata tracks later size changes. A local
same-style AppKit calibration compensates optical-frame insets; unknown metadata
retains the last known frame. SDL positions use content top. No screen pixels,
private APIs or accessibility permission are required by this metadata path.

## Executed evidence

| Requirement | Evidence and result |
|---|---|
| Immediate branded window | `installed/result.json`: all five installed launches present in 0.25–0.32 seconds; main launcher never visible. Actual Android icon from the shipping factory. |
| Native window continuity | Same window numbers before loading and visible decoded content; native visible content in 2.08–2.32 seconds on the dedicated emulator. |
| Previous size | Resize native to 420×560, relaunch native, launch/relaunch fallback, then Launch Services native: all retain 420×560. |
| macOS launch path | Fifth installed cycle uses `/usr/bin/open -n -W` with the real factory wrapper, exercising Launch Services. No fake Android tools or Player instrumentation. |
| Completed app content | `installed/5-native/live-stable.png` visibly shows the Android probe on display20, ticks7. Initial loading and later stable draws are separately retained. |
| Startup/input/cancellation | `qa/results.json`: five shipping-UI scenarios, real black/red H264 decode, zero hidden user-input bytes, exact later text, same window, both early-close boundaries, reopen, five-second explicit reveal. |
| Unit suite | `unit-final.log`: 124 tests, four explicit hardware skips, zero failures. Includes initial-frame classification and live buffered-child PTY relay. |
| Actual emulator streams/input | `streaming-final.log`: four tests pass, including two concurrent decoded streams, mouse/text, resize, secondary activity and cleanup. Associated captures/logs are in `streaming/`. |
| Crash cleanup | `installed-crash/results.json`: both backends pass actual installed-host SIGKILL; no owned surviving processes, forwards, reverse tunnels or displays. Native cleanup0.438s, fallback0.909s in this run. |
| Packaging | `package-validation.json`: strict signature verification, 23 Mach-O dependency trees and bundled tools with isolated PATH. |
| Independent review | `qa/QA_REVIEW.md`, `qa/approval.json`, `MACOS_REVIEW.md`; all final candidate checks approved. |
| Final state | `final-state.json`: dedicated emulator5580 stopped; user emulator5554 preserved. All test GUI sessions ended and exact known wrapper registration unregistered. |

## History and limits

`installed-before-black-hold/` records the superseded candidate; its initial black
capture motivated keeping the manufactured splash through blank frames.
`installed-prior-sessions/` retains earlier session copies. Initial unsupported
scrcpy geometry flags and buffered readiness failures are retained separately.
`unit-harness-stall.log` and the QA sample identify the new test's Foundation
waitUntilExit deadlock, corrected with bounded async teardown. An installed test
initially mixed unrelated unit-fixture logs into its assertions; its failure is
preserved, and final assertions filter the exclusive device/package/backend.
QA records its own corrected startup-packet, minimize and notice-wording fixture
assertions. These historical failures are not relabeled as passing product tests.

The Mac desktop was locked and no physical Pixel was attached. Public AppKit
calls, view draws and Launch Services execution prove the measured paths but do
not prove a physical Spotlight search selection, Dock click, Cmd+Tab or foreground
keyboard focus. The existing Pixel guide remains the physical acceptance stage.
The pixel heuristic may hold very dark or sparse content; its explicit reveal
control avoids blocking such apps indefinitely. Fallback unknown metadata and
monitor/style changes retain the last known size; cross-monitor scale changes
while a Player runs have not been exercised.
