# macOS launch UX review

Scope: independent source review of the Spotlight-wrapper launch path, native
window continuity, saved geometry, cancellation, reopen, and fallback handoff.
Production edits are owned by the lead agent. This review does not establish
physical foreground focus on the locked Mac desktop.

## Design reviewed

- Wrapper launch metadata is read locally before ADB/recovery work. Its Android
  name and bundled icon appear in a native loading window; the main launcher is
  not initially ordered front.
- The native backend attaches its session and decoded frames to that same
  `NativeWindowController`, `NSWindow`, and `AndroidVideoView`.
- AppKit frame autosave is scoped by device and package. Restoration happens
  before the delegate and automatic saving are installed, avoiding writes of the
  temporary centered frame over the user's previous frame.
- Loading-window close sets a terminal cancellation marker, rechecked at the
  final post-await session-admission boundary. Explicit reopen reuses the loading
  window and retries an earlier managed-availability denial.
- A first decoded frame preserves an intentional minimize. Explicit reopen may
  deminiaturize and activate the existing window.
- Fallback is an explicit handoff to the separate SDL Player window. Programmatic
  loading-window closure clears the close callback, and readiness requires both
  the intended Android-package receipt and pinned renderer evidence.
- Public `CGWindowListCopyWindowInfo` metadata can preserve fallback geometry
  without reading screen images or using Accessibility. It must remain scoped to
  a validated, currently owned Player process and retain previous geometry when
  metadata is unavailable.

## Findings sent to the lead

The review identified initial geometry-save ordering, loading-close admission,
managed-denial reopen, fallback-starting reopen, fallback readiness, and wrapper
app-browsing regressions while those changes were in progress. The lead has
incorporated the geometry, cancellation, reopen and app-browsing corrections.
Fallback geometry tracking now validates the exact supervisor-child relationship
with public `proc_pidinfo` before accepting finite public window bounds.

`qa/results.json` records a shipping-source AppKit regression with a real H.264
decoder fixture: immediate branded preview (about 8 ms), a restored 450×420-point
frame, the same window number through six decoded frames, no pre-frame user
input, explicit reopen reuse, and both delayed-admission and post-attachment close
fences. This test does not contact Android and does not prove OS foreground focus.

The first actual fallback probe failed its new Texture-log gate because redirected
client stdout was buffered. The corrected production supervisor supplies a raw
PTY for the unmodified client's stdout/stderr and relays at most 64 KiB per tick
through a nonblocking master. Close-on-exec descriptor handling, bounded relay,
stop checks and process-group cleanup were reviewed. `fallback-real.log` now
records a successful real-client renderer gate and cleanup. The initial failure
remains diagnostic evidence; it did not establish Android rendering failure.

An independent test-only SDL/AppKit/CoreGraphics probe exposed a separate geometry
error. `geometry/player.log` records one exact Player window with SDL content
480×620 points, AppKit frame 480×652, and Core Graphics bounds only 470×640. The
Core Graphics rectangle is optically inset on this macOS version. Saving it as an
AppKit frame would shrink the next launch by 10×12 points. Also SDL's y=100 means
content top=100, while the AppKit outer-frame top is 68 because of the 32-point
titlebar. Passing outer-frame top to SDL would move the window upward each launch.
The probe exited 0 and restored exact display/forward/reverse baselines; see
`geometry/resources.json`. No Android input was injected.

The corrected source maps SDL content-top coordinates explicitly and calibrates
optical bounds against the already visible loading window's own true AppKit
frame. This is safer than inferring the Player's initial size or position, which
could have changed before sampling. Missing/ambiguous calibration retains prior
geometry. No platform-specific inset constant is baked into the implementation.

Independent `geometry/calibration.json` verifies that the loading window's same
public style mask (15) has the exact same optical correction as the measured
Player: x=-5, y=-6, width=+10, height=+12 on this macOS 26 host. Applying the
runtime correction recovers the Player's actual AppKit frame exactly. This check
uses a separate local AppKit window and no Android commands or device input.

**Source review accepted.** The native path, public dynamic calibration, explicit
SDL coordinate mapping, exact-process metadata fencing and production PTY relay
have no remaining blocking issue found in this review.

The final installed 0.1.5 build 10 five-cycle test (`installed/result.json`) proves
native resize to 420×560 points, native relaunch at that size, and two fallback
launches at the same size without cumulative drift. Native window numbers are
unchanged from loading through real first frames. Observed first windows appeared
in about 0.25–0.32 seconds, and the launcher was never observed visible. The fifth
cycle launches through real `/usr/bin/open` and Launch Services. Each run
exited 0 and restored the original display/ADB resources. Production fallback logs
show real 420×560 Texture creation; no Player instrumentation or fake ADB was used.

The installed main SHA-256 is
`cc84835c5cc57fc4d3807509d7fb4b478b8dc9a3074d913e96247fe03460bb7c`;
strict bundle verification passed during this review. The independent factory
wrapper has the same Mach-O UUID and identical bytes in all 32 file-backed
sections (`installed/binary-identity.json`). Its whole-file hash differs because
the factory signs it under its separate wrapper bundle identifier.

**Final macOS launch-UX review approved for that installed candidate.**
The revised native path retains loading UI across initial blank Android frames,
then presents meaningful video in the same window without reactivation/reordering.
The bounded pixel sample is a presentation heuristic, not proof that an Android
activity finished loading or an interpretation of its content.
Its five-second blank-video notice includes a public reveal control, so a
legitimately black app can still receive input. Source-level regressions verify
the reveal/recovery path, minimum-size layout and deliberate minimize behavior.
Actual visible content arrived in about 2.08–2.32 seconds in the installed tests.
`installed/5-native/live-stable.png` was independently inspected and shows the real
Android probe with display 20 and ticks 7, resolving the earlier black-screenshot
evidence limitation. The earlier candidate and its black first-frame captures are
historical evidence under `installed-before-black-hold`, rather than the approved
hash above. Final execution results must be read alongside this source review;
compilation alone is insufficient.

## Required executable checks

1. Delayed ADB startup still shows the branded loading window immediately, with
   the launcher hidden.
2. A seeded prior frame survives construction; native window identity and size
   remain stable when real decoded video arrives.
3. Closing during readiness/catalog awaits admits no successor session or child
   process. Reopen during loading admits no duplicate session.
4. An unavailable/denied wrapper retains useful status, and explicit reopen after
   availability changes retries the original app identity.
5. User minimize during loading survives first video; explicit reopen restores it.
6. The unmodified production fallback client supplies readiness evidence while
   its output is redirected to the real session log. A test-only unbuffering shim
   cannot establish this property.
7. Fallback handoff leaves a real Player window, does not stop its session, and
   resized Player bounds are restored on the next launch without accumulating
   titlebar height.

Window visibility, identity, dimensions, decoded-frame receipts and cleanup can be
verified on the locked desktop. Actual Spotlight invocation, visible focus
switching, Dock presentation and foreground keyboard routing remain physical UI
checks unless separately exercised on an unlocked desktop.
