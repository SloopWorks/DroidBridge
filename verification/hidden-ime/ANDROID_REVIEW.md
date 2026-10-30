# Android platform review: hidden virtual-display IME

Reviewed 2026-10-30 against DroidBridge base `ff22987`, pinned upstream scrcpy `v5.0.1`, and Android 15 AOSP source. This first section is a source review, not executable Android acceptance. No emulator was operated during this investigation.

## Cause and supported correction

Both production starts explicitly request LOCAL IME policy: fallback `--display-ime-policy=local`, native `display_ime_policy=local`. That correctly explains the software keyboard appearing in the Mac window when Android focuses an editable field. The previous screen-off investigation chose LOCAL to solve default/fallback display routing, and explicitly recorded that the keyboard could consequently appear inside the virtual display. That historical evidence remains valid for its old candidate; it is not acceptance evidence for hidden IME.

Pinned scrcpy 5.0.1 CLI accepts `local`, `fallback`, and `hide`; its server maps `hide` to Android's `DISPLAY_IME_POLICY_HIDE = 2`. The supported replacement is:

- Backend A: `--display-ime-policy=hide`.
- Backend B: `display_ime_policy=hide`.

`NewDisplayCapture.startNew()` applies the configured policy to the exact newly created virtual display ID before publishing display availability to the controller/app launcher. This is independent of `vd_system_decorations`; hiding navigation/system decorations alone does not hide the IME. Every new/restored/reconnected session must pass HIDE, including copied wrappers that actually run their own old executable.

## Input implications

HIDE means more than an invisible keyboard. Android 15's WindowManager contract says the display will effectively have no IME connection; InputMethodManagerService returns `InputBindResult.NO_IME` and rejects show requests under that display policy. Software-IME suggestions, composition, handwriting, and other Android IME features consequently do not run for these editors.

scrcpy SDK input has independent paths: its text injection converts supported characters into key events and injects them against the session's virtual display; raw keys use the same scoped display, and clipboard paste sets the Android clipboard then injects PASTE against that display. These paths do not require opening the Android software keyboard. That source relationship supports the proposed implementation, but does not prove app-specific typing. In particular, previous API37 default-FALLBACK routing lost text even with a focused editor; test HIDE explicitly with physical display0 ON and OFF rather than assuming the earlier LOCAL result transfers.

The Mac AppKit text-composition path and upstream SDL host keyboard path must remain tested separately. Android's SDK character map still limits directly injected text. Clipboard may carry Unicode subject to app/Android clipboard policy; suppressing the software keyboard does not add arbitrary Unicode support. Neither policy can suppress an application's own custom-drawn keypad, because that is application content rather than Android IME.

## Version and failure boundaries

- Virtual displays require Android10/API29 in this pinned server.
- HIDE is implemented by scrcpy only on Android12/API31+. On API29/30 its wrapper logs `DISPLAY_IME_POLICY_HIDE is not supported before Android 12` and ignores the request. These older Android versions cannot be advertised as satisfying a strict no-software-IME guarantee merely because startup succeeds.
- Pinned scrcpy wraps `setDisplayImePolicy` through reflection. Reflection or Android permission errors are logged rather than returned as a hard startup failure. Therefore actual display policy and visibility checks are required on the supported test matrix; CLI acceptance alone is insufficient.
- Android15 requires a trusted display for this policy. Pinned scrcpy requests TRUSTED and separate display-group flags from API33, and OWN_FOCUS from API34. API35/API37 are the present regression matrix; earlier API31/32 require independent validation rather than an inferred promise.
- AOSP15 force-desktop mode changes FALLBACK to LOCAL but preserves explicit HIDE. Therefore the explicit HIDE policy is preferable to changing desktop/global keyboard settings.

## Physical phone independence and restoration

The setting targets only the newly owned virtual display, not physical display0. It does not alter the selected/default IME, `show_ime_with_hard_keyboard`, enabled input methods, Android system timeout, or device-wide keyboard visibility preferences. No root or keyboard-disabling workaround is required. Phone panel power remains controlled separately by existing per-device policy.

AOSP15 `DisplayWindowSettingsProvider` excludes virtual displays from persisted settings and removes their in-memory overrides when the display is removed. Closing a new-display session therefore destroys its policy with its display; no global setting restoration is needed. Pinned scrcpy's separate `CleanUp` restore path applies when modifying an existing secondary display, while DroidBridge uses newly owned displays. Do not add broad keyboard-setting restoration that could race other sessions or the phone user.

The physical phone should continue to show its normal keyboard when its own editor is focused. Android's currently focused IME/session internals can change as users switch displays; verify this explicitly instead of treating a globally false `mInputShown` as proof of independence.

## Required executable evidence

For each backend on API35 and API37, retain exact process/server arguments, actual virtual display IDs, display-bound IME policy/Insets state after editor focus and an explicit software-keyboard show request, decoded video frames, and Android-side text receipts. Exercise text, raw navigation/delete keys, clipboard paste, switching between two sessions, resize/refocus, close/reopen, and physical panel OFF. Show that each virtual display remains HIDE and lacks a visible Android IME while input reaches the correct editor. Verify physical0 keyboard/policy remains independent and close restores the resource baseline. A global `mInputShown=false`, compilation, or a static screenshot alone is insufficient.

Independent QA owns the live state checker and final acceptance. A physical Pixel10Pro remains the owner's later hardware acceptance stage.

## Primary references

- [Pinned CLI option and accepted values](https://github.com/Genymobile/scrcpy/blob/v5.0.1/app/src/cli.c)
- [Pinned server policy parsing](https://github.com/Genymobile/scrcpy/blob/v5.0.1/server/src/main/java/com/genymobile/scrcpy/Options.java)
- [Pinned virtual display policy application and trusted flags](https://github.com/Genymobile/scrcpy/blob/v5.0.1/server/src/main/java/com/genymobile/scrcpy/video/NewDisplayCapture.java)
- [Pinned Android version handling](https://github.com/Genymobile/scrcpy/blob/v5.0.1/server/src/main/java/com/genymobile/scrcpy/wrappers/WindowManager.java)
- [Pinned key/text/paste injection](https://github.com/Genymobile/scrcpy/blob/v5.0.1/server/src/main/java/com/genymobile/scrcpy/control/Controller.java)
- [Pinned existing-display cleanup](https://github.com/Genymobile/scrcpy/blob/v5.0.1/server/src/main/java/com/genymobile/scrcpy/CleanUp.java)
- [Android15 HIDE contract](https://android.googlesource.com/platform/frameworks/base/+/android-15.0.0_r1/core/java/android/view/WindowManager.java)
- [Android15 input-method binding/visibility](https://android.googlesource.com/platform/frameworks/base/+/android-15.0.0_r1/services/core/java/com/android/server/inputmethod/InputMethodManagerService.java)
- [Android15 effective display IME policy](https://android.googlesource.com/platform/frameworks/base/+/android-15.0.0_r1/services/core/java/com/android/server/wm/DisplayContent.java)
- [Android15 virtual setting lifetime](https://android.googlesource.com/platform/frameworks/base/+/android-15.0.0_r1/services/core/java/com/android/server/wm/DisplayWindowSettingsProvider.java)

## Implementation review (initial candidate)

Reviewed the current two-line `BridgeSession.swift` change from LOCAL to HIDE for the fallback CLI and native server on 2026-10-30. Both spellings match pinned upstream parsing and target the same session-owned virtual display. Keep-active, no-power-on, control transport, decorations policy, task destruction, and cleanup remain intact. No global Android setting or physical0 IME policy is changed.

This is a correct implementation of the selected policy for the supported Android35/37 matrix. It is not yet a live acceptance approval. Outstanding review conditions: execute the backend/device matrix above; ensure API29/30 cannot silently claim no-IME support; and ensure installed independently copied wrappers are updated before they can continue sending LOCAL. Any later admission or wrapper-compatibility changes require separate review.

## Frozen candidate review and API31/32 finding

The later startup admission change correctly queries `ro.build.version.sdk` before client-version checking, app resolution, native staging, display creation or either child spawn. It generation-checks the awaited result and rejects unreadable values. The argument tests exercise both actual production spawn paths across new/restored session decoding and decorations on/off; obsolete JSON IME keys cannot override runtime HIDE. Unsupported/ambiguous SDK fixtures assert that only the version query occurs, with no staged/native/external child. These are configuration/admission tests, not Android behavior evidence.

**Review finding: a minimum of API31 is insufficient with this pinned server.** While Android12 introduces HIDE, pinned `NewDisplayCapture` adds `VIRTUAL_DISPLAY_FLAG_TRUSTED` only on API33+. Android12 AOSP `WindowManagerService.setDisplayImePolicy()` rejects untrusted virtual displays; `DisplayContent.getImePolicy()` returns FALLBACK for them. Its `VirtualDisplayAdapter` marks trusted only when the trusted flag was requested, and its DisplayManagerService does not implicitly grant it based on shell ownership. Pinned scrcpy's wrapper catches the resulting reflected exception. Therefore Android12/12L can silently continue without the strict hidden-IME policy. Source review requires a product minimum of **Android13/API33**, or a separately implemented and verified trusted-policy admission mechanism, before approval. This is a concrete mismatch between the pinned server's flags and Android's setter requirements, rather than a claim based merely on absence of emulator coverage.

References for that finding:

- [Android12 setter trust restriction](https://android.googlesource.com/platform/frameworks/base/+/android-12.0.0_r1/services/core/java/com/android/server/wm/WindowManagerService.java)
- [Android12 effective policy for untrusted displays](https://android.googlesource.com/platform/frameworks/base/+/android-12.0.0_r1/services/core/java/com/android/server/wm/DisplayContent.java)
- [Android12 trusted display-device flag mapping](https://android.googlesource.com/platform/frameworks/base/+/android-12.0.0_r1/services/core/java/com/android/server/display/VirtualDisplayAdapter.java)
- [Android12 create-display flag handling](https://android.googlesource.com/platform/frameworks/base/+/android-12.0.0_r1/services/core/java/com/android/server/display/DisplayManagerService.java)

## Independent state-oracle review

Reviewed `scripts/verify-hidden-ime-state.py` and the actual `qa/api35-local-positive` evidence. The captured installed old-policy app creates display2, focuses the test editor, accepts Mac-path text, and has explicit visible IME InsetsSource `[0,503][720,1080]` on that display. The checker rejects all eight supplied LOCAL snapshots for that visible inset. The result binds the old installed executable SHA and exact session identity; it is a valid positive control for reproducing the reported bug.

The checker binds display blocks and current WindowState display IDs, requires explicit hidden IME insets and a visible expected app, and refuses retained IME surfaces/presentation. Missing or ambiguous required fields fail closed. Actual dumps do not expose a direct numeric policy field, so production argv plus current display-bound window/inset state is the appropriate combined oracle. A global input-method boolean remains supplemental. The checker's explicit limitations correctly avoid claiming continuous never-visible behavior or input delivery from snapshots alone; separate sampled intervals, input receipts, and video remain necessary.

## Current API33 candidate: source verdict and native API35 evidence

The current production candidate now requires **Android13/API33** both in shared session admission and discovery capabilities. Unknown SDK values and API29/30/31/32 are rejected before activity resolution, staging or child launch. `HiddenIMEArgumentTests` now uses API33 at the accepted lower boundary and includes API31/32 in the denied matrix. Both CLI/server HIDE arguments remain invariant. This resolves the API31/32 source-review blocker above. **Source policy/admission review is approved for the current candidate; this is not blanket backend/device acceptance.**

The installed candidate SHA `a725fcaa790b9aea9d1e95daeb8f43b31a8ba9cc90c4440e66f2b130d3e2cc40` is bound in actual QA API35 native results. I reviewed `qa/api35-hide-decorations-{on,off}/result.json` and `qa/api35-hide-paste/result.json`: each records 24 passing display-bound IME snapshots, for 72 total, with actual text and raw Backspace receipts through panel-ON, panel-OFF and resized-panel-OFF phases. The paste run additionally records clipboard delivery in all three phases and Mac pasteboard restoration. Each records unchanged Android settings and restored display/forward/reverse baselines. These substantiate the native API35 matrix reported there; they do not prove fallback, API37 or physical Mac focus. The old installed LOCAL positive control remains a separately observed reproduction of the bug.

## Fallback failures: binder error interpretation

Reviewed the preserved `fallback/api35-public-sdl/session-086010BD-A350-4CB2-92FF-5D58F8C2F09A.log`. Its concrete stack is `Controller.handleEvent` → `injectText` → `injectChar` → scrcpy's reflective InputManager wrapper → Android `InputManagerGlobal.injectInputEvent`. Thus those specific text events reached the Android scrcpy controller; a host event queue that never delivered text cannot by itself explain these observed errors. The subsequent keep-active thread also receives `DeadObjectException` from `IPowerManager.userActivity`, which does not depend on typing or the IME.

The exception name alone does **not** establish an Android system-server restart, memory exhaustion or a HIDE regression. Android15 `InputManagerGlobal` catches `RemoteException` at the actual binder input call and invokes `rethrowFromSystemServer()`. That method wraps **any** `DeadObjectException` as `DeadSystemRuntimeException`; the wrapper therefore does not distinguish confirmed system-process death from a lower-level binder failure. Android's `DeadObjectException` documentation explicitly includes binder one-way queue exhaustion and binder-buffer rejection as alternatives to process death. The relevant input call is a binder transaction that occurs after host delivery; neither the name nor the host's free-memory reading determines the cause.

Pinned scrcpy caches its InputManager and PowerManager wrappers for the server process, and the manager objects retain service references. If a service binder became stale, that server has no general rebind loop to refresh both wrappers. This makes stale per-process binder references a plausible explanation for repeated failures, but the preserved stack does not establish when or why such a reference became invalid. Multiple-service errors are evidence of binder/service health trouble at those calls, not proof that display IME policy caused it.

Do not merge distinct failed runs into one diagnosis. The reviewed `api35-cocoa-direct` log has app/video startup but lacks the public-SDL injection exception stack; its missing-text timeout does not independently prove Android received that host text. The later `api35-sdl-queuepump` attempt failed in a test fixture's dynamic-library load path before client startup, according to the systems owner's diagnosis; it is not a product input or IME outcome. Failed fixtures and failed product-path attempts remain preserved.

The systems owner later reported a stable system_server PID across a finite uptime interval and an empty crash buffer. Those observations do not support an assertion of an observed runtime restart. A fresh `input keyevent KEYCODE_UNKNOWN` command exiting0 is a basic command-health fact, not proof of editor delivery. The next bounded discriminator is a fresh HIDE client with a low-rate click and short word, followed—only if it fails—by a fresh Android-process ADB input control targeted at that exact display with an app-side text receipt, plus contemporaneous service health/PID/uptime and crash/system logs. If fresh input succeeds while an older scrcpy binder repeatedly fails, stale server-process references gain support; if both fail, investigate current Android input/service state. Preserve timing, stop only owned sessions, and do not change HIDE or global keyboard settings merely to retry away a failure.

Additional primary references:

- [Android15 input binder call and exception conversion](https://android.googlesource.com/platform/frameworks/base/+/android-15.0.0_r1/core/java/android/hardware/input/InputManagerGlobal.java)
- [Android15 RemoteException wrapper semantics](https://android.googlesource.com/platform/frameworks/base/+/android-15.0.0_r1/core/java/android/os/RemoteException.java)
- [Android15 DeadObjectException alternatives and recovery guidance](https://android.googlesource.com/platform/frameworks/base/+/android-15.0.0_r1/core/java/android/os/DeadObjectException.java)
- [Pinned cached service-wrapper ownership](https://github.com/Genymobile/scrcpy/blob/v5.0.1/server/src/main/java/com/genymobile/scrcpy/wrappers/ServiceManager.java)
- [Pinned InputManager reflection wrapper](https://github.com/Genymobile/scrcpy/blob/v5.0.1/server/src/main/java/com/genymobile/scrcpy/wrappers/InputManager.java)
- [Pinned per-display keep-active wrapper](https://github.com/Genymobile/scrcpy/blob/v5.0.1/server/src/main/java/com/genymobile/scrcpy/wrappers/PowerManager.java)

## Subsequent captured InputDispatcher crash

The later `fallback/api35-sdl-health-retry/crash-buffer-after-restart.txt` changes the evidence for that specific retry: it explicitly records system_server6954's InputDispatcher receiving SIGABRT, with `addPointers - overlap with incoming pointers` for `NavigationBar2`, dispatch mode OUTSIDE, and libinputflinger's `addPointerWindowTargetLocked/findTouchedWindowTargetsLocked` stack. The systems owner also observed system_server becoming9550 while kernel uptime continued. This is actual runtime-crash evidence, unlike an inference made solely from earlier DeadSystem exception names. Preserve that distinction. The captured failure is a motion/pointer target assertion; it does not establish HIDE or host OOM as its cause.

Pinned server source also prevents a premature mouse-versus-finger explanation. `Controller.injectTouch()` chooses SOURCE_MOUSE only for its mouse pointer ID combined with HOVER_MOVE or secondary-button activity. A primary-only down/up from the SDK client is mapped to FINGER/SOURCE_TOUCHSCREEN, even when its protocol pointer ID is the mouse identity. Therefore the actual incoming action/button sequence and preceding hover state need examination before claiming fallback primary clicks differ from native touch solely by source.

A relevant primary upstream precedent is [scrcpy issue5477](https://github.com/Genymobile/scrcpy/issues/5477). Its reported Android15 crash has the same overlapping-pointer/OUTSIDE assertion; the [maintainer identifies libinputflinger](https://github.com/Genymobile/scrcpy/issues/5477#issuecomment-2471244052), and the [reporter describes `--no-mouse-hover` as a workaround](https://github.com/Genymobile/scrcpy/issues/5477#issuecomment-2586548624). This is a lead for an otherwise-identical bounded diagnostic run, not proof that our current failure shares its complete root cause or that the workaround is sufficient. No production flag change is approved solely on that report. Pinned5.0.1 supports the switch; test any candidate through actual client mouse, text, raw-key, paste, resize and hidden-IME checks before changing the frozen release.

## Android17 no-source IME oracle semantics

Reviewed the actual target display3 block in `qa/api37-hide-diagnostic/failed-displays.txt`: `mImeWindow=null`, IME targets are null, there is no IME InsetsSource in that display, and its own trailing `DisplayWindowSettingsProvider/SettingsEntry` prints `mShouldShowIme=2`. The physical display0's separate block prints `mShouldShowIme=null`; it must not be borrowed as target evidence.

The current primary AOSP `DisplayWindowSettings.SettingsEntry.toString()` literally prints the integer `mImePolicy` under the legacy string label `mShouldShowIme`. It is not a boolean. `getImePolicyLocked()` reads that integer, and `WindowManager.DISPLAY_IME_POLICY_HIDE` remains2. `DisplayContent.getImePolicy()` preserves explicit2 for a trusted display; pinned API33+ sessions request trusted displays. The moving primary source and the captured API37 dump agree on this representation; this is not a claim that AOSP main is the exact device image source revision.

Therefore the snapshot checker may accept absence of an IME InsetsSource **only** when the same unambiguous expected display block explicitly reports policy2, the expected application has a visible window, and no IME WindowState has an attached surface/presentation there. If any IME source exists, every explicit visibility flag must still be false. If a policy token is present it must be exactly2: null, LOCAL0, FALLBACK1, malformed or conflicting values fail closed. Missing sources without explicit policy2 remain a refusal. This handles a real Android17 no-IME representation rather than treating generic missing data as hidden. Input receipts, frame changes and sampled intervals remain separate requirements; the diagnostic's failed initial text trial does not become an input pass merely because its IME state is understood.

Primary references:

- [Current SettingsEntry dump label and policy storage](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/services/core/java/com/android/server/wm/DisplayWindowSettings.java)
- [Current HIDE constant](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/core/java/android/view/WindowManager.java)
- [Current effective trusted display policy](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/services/core/java/com/android/server/wm/DisplayContent.java)

## API35 hover mitigation: reviewed source and controlled result

Reviewed the updated production fallback path: `startExternal` receives the already-read, generation-fenced Android API, and appends `--no-mouse-hover` only for API35. The source tests exercise APIs33/34/35/36/37 and require HIDE independently. Pinned `mouse_sdk.c` returns early only for motion with no pressed buttons when hover is disabled; click, button-held motion/drag, and scrolling handlers remain available. Native sessions are unchanged. Source review approves this narrowly scoped mitigation.

I independently inspected `fallback/api35-no-hover-control/result.json`: the same installed a725 host and unchanged Player, with the test proxy adding only the hover switch alongside recording, passes decorations on/off, panel ON/OFF, resized-OFF, exact-display text/raw-k/clipboard receipts, 24 hidden-IME snapshots and changing recorded frame hashes. system_server9550 remains stable, five Android settings match their baseline, and resource/Mac-state baselines are restored. It correctly records `diagnostic_no_mouse_hover=true` and `acceptance=false`. This controlled result supports the mitigation and narrows the failure from generic HIDE/input hypotheses. It does not substitute for rerunning the final installed executable that emits the flag itself. Final installed-candidate fallback/API37 acceptance remains pending the relevant QA/system results.

Reviewed the implemented policy-aware checker and ran read-only in-memory parser controls against the actual retained API37 diagnostic files: the actual policy2/no-source snapshot passes; target policies0/1/null/junk/empty with no source fail; a visible IME source despite policy2 fails; policy2 only on physical0 with target3 null fails; and an attached visible IME WindowState on target3 despite policy2 fails. These are parser controls, not new emulator or input acceptance runs. A minor hardening request was sent to QA: capture an empty present policy token rather than skipping it, so malformed policy plus an otherwise false inset also fails closed.

## Exact final installed candidate review (13ea19)

Read-only review on 2026-10-30 independently recomputed all47 `release-inputs.json` production/documentation hashes against the workspace: no mismatch. The installed executable outside the build tree hashes to `13ea19c4226f25a132beab2e3ead81d87391ea2c3a46377afc50e374e8cd0c75`, matching the release manifest. Current source enforces API33+, HIDE for both backends, and no-hover only for API35 fallback. The final full-suite log records127 tests, four explicit opt-in skips and zero failures. The latest checker includes empty-token hardening; QA's19 parser regressions are recorded.

I independently replayed the actual display/window snapshots with the current checker rather than relying only on reported booleans: 96 native snapshots from `qa/final-api{35,37}-{on,off}` and24 fallback snapshots from `fallback/final-api35` pass. Every native phase's Android log has the complete expected text, a **later** shorter string from new Backspace delivery, then the restored full string and clipboard suffix, scoped to the exact display. This sequence check distinguishes a real subsequent deletion from the same shorter prefix that naturally appeared during initial typing. All12 native phases (four combinations × panelON/panelOFF/resizedOFF) satisfy that sequence and paste receipt. I also viewed API37's actual resized-OFF decoded screenshot: the expected composed text is present with no software keyboard. These are live-rendered frame pixels, not a mockup.

The final fallbackAPI35 result is `acceptance=true` and `diagnostic_no_mouse_hover=false`, bound to this13ea19 executable and unchanged installed Player. Production argv includes both HIDE and no-hover before the recording-only proxy addition. Its two decoration modes and six editing phases have exact-display text/raw-k/paste receipts, 24 passing IME/window snapshots, differing recorded frame hashes and exact cleanup; system_server9550 stays unchanged and settings match their baseline. I independently replayed those snapshots and checked the expected receipt strings in the Android log. Thus the final API35 fallback result replaces the earlier diagnostic control as acceptance evidence.

At this review checkpoint, nativeAPI35/API37 and fallbackAPI35 are approved within their recorded automation scope. Final fallbackAPI37 and managed-wrapper upgrade remain pending; this checkpoint does not approve the unfinished matrix or convert physical-focus/Pixel limitations into passes.

## Final source and Android matrix verdict

Final fallbackAPI37 is now independently reviewed in `fallback/final-api37`. It binds the same installed13ea19 executable and unchanged Player, records `acceptance=true` and no diagnostic hover override, and its production argv has HIDE with **no** no-hover switch on API37. I independently replayed all24 actual API37 fallback display/window snapshots and checked the exact per-display text/raw-k/clipboard strings in its Android log for both decoration modes and all six editing phases. Both recordings have distinct sampled frame hashes, cleanup matches the baseline, five Android settings remain unchanged, and system_server682 is stable. The captured crash buffer is empty. All47 release-manifest inputs still match the source/documentation files after this review.

**Approved: the final source policy and tested Android15/API35 + Android17/API37 matrix for both native and fallback backends, with decorations ON and OFF.** Across the final accepted runs, I independently replayed144 actual IME/window snapshots (96 native +48 fallback) and checked the corresponding Android input receipts rather than accepting result assertions alone. Explicit HIDE remains enforced after panel OFF and resize while Mac-path typing, raw keys and paste continue. API35 fallback emits the tested hover mitigation itself; API37 retains hover. Resource and settings preservation are recorded separately in each run.

This approval is bounded by the actual recorded automation: source-only API33/34 compatibility gates are not a live emulator claim; finite snapshots are not a mathematical claim about every future frame; public AppKit/SDL event paths under a locked desktop do not prove unlocked physical Mac focus; custom app-drawn keypads are not Android IME; physical Pixel10Pro/OEM behavior remains the owner's hardware stage. Managed copied-wrapper upgrade is being verified separately by the lead; old already-running or unmanaged copied executables must not be described as changed until replaced. No emulator, preference or shared runtime-state operation was performed by this reviewer during the final read-only review.
