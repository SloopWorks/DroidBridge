# Quick Access design review

Reviewed 2026-11-21 by the delegated UX/design agent. Read-only inspection of
`Sources/DroidBridge/DesktopSettings.swift` and `Sources/DroidBridge/QuickAccess.swift`.
This document records a source-level UX review, not visual or runtime acceptance.

## Information architecture and rationale

Quick Access is first in General Settings, before window rendering and recovery.
That matches its app-wide preference scope and keeps it separate from Android
permissions and Spotlight publication in Integration. The explicit checkbox
'Open automatically when my device connects' names the confirmed trigger.
The supporting text distinguishes readiness from unlocking the phone.

The three target labels name concrete destinations: DroidBridge control app,
specific Android app, and current device screen. Every target retains a saved
device; the control target does not silently follow the dashboard selection.
The summary displays device identity beside the app or screen choice, helping
users catch an unintended device before enabling automatic foreground behavior.
Selection uses the existing ready Apps catalog rather than adding a second picker.

The observed runtime consumes one admission per connected interval. Temporary
readiness loss does not re-arm the interval. This limits repeated focus stealing.
Source default and launch-helper behavior still require independent executable QA.

## Actionable findings sent to implementation owner

1. Control-target save confirmation incorrectly says 'current screen'. Use a
   target-specific confirmation naming the DroidBridge control app.
2. Disabling automatic opening leaves the previous enabled explanatory status.
   Show 'Automatic opening is off. Your saved choice is kept.' instead.
3. Open Now remains enabled while automatic opening is off, but the handler
   immediately returns. Prefer a manual action independent of the automatic
   toggle; otherwise disable the button and explain why.
4. Enabling without a saved device shows the normal ready explanation despite
   having no runnable configuration. Request selecting a connected device in
   DroidBridge and then using the save-selection button.

## Failure copy

Disconnected, unauthorized, starting and missing-app messages name the device
or app and give a retry or Settings action. Missing-app copy avoids a generic
backend-switch suggestion. No recurring modal alert is introduced. Failure is
presented in the control app for inspection. The UI should preserve the saved
choice across disconnection and failed startup.

## Pending visual and executable checks

Inspect a real AppKit Settings screenshot for wrapping, clipping, keyboard focus,
scrolling and popup/checkbox state. Verify initial off state, saved-device summary
for all three targets, disable/re-enable behavior, actual off-state manual action,
and a prolonged connected interval without repeated foreground activation.
No screenshot was supplied to this review at creation time.

## Follow-up source review and mirror image inspection

Implementation owner addressed all four findings: control-specific saved copy,
explicit off-state copy, disabled Open Now while off, and missing-device guidance.
The latter two are coherent because the checkbox governs the entire Quick Access
feature, and a disabled action no longer silently accepts a click. Current
observe-state copy gives waiting/authorization/startup instructions without
claiming launch success. No additional serious source-level UX issue was found.

Inspected `verification/quick-open-2026-11-21/mirror-after.png` with view_image.
The supplied pixel image contains readable full portrait probe content marked
Display 0, visible controls/navigation, and symmetric side letterboxing. No
visual clipping of the mirrored screen is apparent. This image alone does not
show AppKit chrome or prove native rendering/liveness; those require the
independent runtime/frame evidence. Settings screenshots remain pending.

## Settings capture inspection

Inspected both supplied settings-NSAppearanceNameAqua.png and
settings-NSAppearanceNameDarkAqua.png with view_image. These captures do not
provide sufficient visual acceptance: Aqua appears almost entirely black except
for its blue checkbox; DarkAqua shows readable labels but its popup and buttons
appear as unlabeled white bars. They appear to be transparent/offscreen view
captures, rather than faithfully composed window screenshots. Root was notified
that a WindowServer-composed actual window capture is needed to establish
control labels, contrast, and full appearance. No product-code visual blocker is
inferred from capture artifacts alone.

Visible DarkAqua text has a clear heading hierarchy, adequate paragraph wrapping,
and a complete saved-device summary. Source-reviewed labels and actions remain
coherent. Final visual acceptance is pending a faithful composed capture.

## Actual composed AppKit review (final review package)

Used CUA against the exact review bundle path:
`/Users/patrick/Library/Application Support/DroidBridge/ReviewBuilds/quick-open-2026-11-21/DroidBridge.app`.
Root identified this review instance as PID 15917 before handoff. No bundle-ID-only
selection or UI action against the user's installed copy was requested.

Executed UI sequence: getApp(full path); getScreenshot; Command-Comma;
getAXState; getScreenshot; click automatic-open checkbox off; getAXState;
getScreenshot; restore checkbox on; getAXState; open target popup; getAXState;
Escape; scroll General down one page; getAXState and getScreenshot; Command-Q.
The tool transcript contains the composed screenshots and accessibility results.

Actual composed General Settings is readable, with correctly painted popup and
button titles. The cached-view PNG artifacts did not reflect the live rendering.
Quick Access appears first, with a clear trigger checkbox, supporting readiness
text, destination popup, complete saved-device summary, actionable waiting text,
and Open Now. Text wraps cleanly at the shipped window size. The target menu
exposes DroidBridge control app, Specific Android app, and Current device screen.

Off-state AX: checkbox value 0, target popup disabled, Open Now disabled, status
'Automatic opening is off. Your saved choice is kept.' The saved current-screen
and dedicated-emulator summary remained visible. Re-enabling restored checkbox
value 1 and active target/Open Now controls. Scrolling reached the Recovery and
Device settings controls with their complete labels. No material visible Settings
blocker was found. Live dark appearance was not changed during this review.

The initial mirror window was already showing an actual connection-interrupted
splash with Retry, and Settings said the dedicated emulator was disconnected.
This review therefore does not claim a live-frame observation; root's separate
runtime evidence covers cold-connect decoded frames. The splash clearly
communicated waiting and exposed Retry.

Sent Command-Q using the full-path-bound review app. The next AX query displayed
an Apps window, potentially because the tool retargeted the other same-ID copy
after exit. No further UI input was sent. Root was asked to verify exact PID
exit and preservation of the user's original instance by process identity.
CUA completion summary: 'Reviewed Quick Access Settings'.

Process-identity follow-up from root: PID 15917 did exit; original user PID 96808
and wrappers 620/77294 remained alive. The post-quit AX query relaunched the review
bundle without QA arguments as PID 18468. Corrected by binding the exact full
review path and sending Command-Q only, with no post-quit observation. Root owns
CLI exit verification. Future exit checks must not use an app observation API
that can implicitly launch the bundle.

## Live composed mirror follow-up (held cold connection)

Root repeated the cold-connect run while retaining the parent/emulator lifetime,
then handed off exact review PID 25178 at the same full review path with isolated
QA root `/private/tmp/droidbridge-quick-cold-znym34eh`.

CUA sequence: getApp(full review path), getScreenshot, getScreenshot, Command-Q
only, completion summary 'Verified live native mirror'. No app observation API
was called after quit; root owns process cleanup verification.

Observed an actual composed AppKit window titled 'Dedicated Android 15 emulator
— Current Screen' containing the full Android probe screen. Consecutive captures
showed Display 0 ticks increasing from 173 to 184, resolution 1080×1920. Content
was visible rather than a loading/error splash, portrait geometry was preserved,
side letterboxing was symmetric, and Android navigation remained visible. No
material mirror presentation blocker was found. This supplies direct live visual
observation in addition to root's decoded-frame/runtime evidence.
