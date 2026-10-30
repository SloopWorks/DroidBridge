# Audio routing verification

Objective: review routing and enable audio with guards, feedback, alternatives
on failure, and end-to-end launcher verification. Final installed build14 passes
the executed automated gates below; physical Pixel and speaker checks remain manual.

## Implemented behavior

Audio is device-wide, including Android apps outside DroidBridge, rather than
isolated to an app/window. Both video backends retain audio=false/no-audio and
share one separate audio-only pinned scrcpy5.0.1 client per connected device.
Mac is the default for an active app, Phone stops capture, and Mac + Phone uses
playback duplication subject to app policy. No microphone or silent capture-source
fallback is selected. Settings live in a separate audio-preferences.json so old
screen/Spotlight preference writers cannot erase Phone intent.

The client decodes raw audio through upstream FFmpeg/SDL and uses the normal Mac
output. The tracked five-file patch reports readiness only after SDL output
open/resume, validates supervised31-bit identity, stages a unique Android JAR,
creates non-rebinding forwards and delegates exact cleanup to the supervisor.
Output initialized is not a claim of audible sound. The launcher/sidebar and
native-wrapper Audio menu explain scope and expose Retry Audio / Use Phone;
SDL fallback users use the main launcher's controls/menu; the separate upstream Player menu does not gain an Audio submenu.

Guards include Android13 admission, an available CoreAudio output, typed routes,
32 bounded saved devices (unknown devices use Phone at capacity), generation and
cancel fences, per-device ownership held by a crash-independent supervisor until
cleanup, and shared route/retry-scoped failure latches. A late old GUI cannot
publish over a successor. Audio failure never stops video sessions. Explicit
Retry or changing route admits a new attempt; video reconnect does not imply a
latched audio failure has cleared. Attempt recovery and diagnostic retention are
bounded and preserve live owners. No production PCM is recorded or uploaded.

## Evidence matrix

| Requirement | Status | Evidence |
|---|---|---|
| Full Swift suite | Pass:153 executed,4 device-opt-in skips,0 failures | unit.log |
| Real patched-client invalid identity/mode refusal | Pass:8 cases before any ADB invocation | client-admission.json |
| Device ownership, lifecycle and cleanup fencing | Pass in isolated executable tests | qa/supervisor-lease.json, qa/supervisor-fences.json, unit.log |
| Legacy global writer preserves independent Phone intent | Pass | unit.log, QA_REVIEW.md |
|32-device capacity, preference refusal, delayed admission | Pass | unit.log, QA_REVIEW.md |
| Shipping AppKit controls/menu/error/wrapping | Pass isolated injected router; no device claim | ui-run.log, actions/ |
| Native API35/37 real launcher/audio/UI | Pass:26 phases,438 aggregate PCM blocks,zero observer drops; actual route/retry/Phone controls and screen-OFF | native/api35/result.json, native/api37/result.json |
| Fallback API35/37 real launcher/audio/UI | Pass:26 phases,1181 aggregate blocks,zero observer drops; actual route/retry/Phone and panel-OFF/resize | fallback/api35/result.json, fallback/api37/result.json |
| Concurrent real wrappers / owner transfer | Pass:real signed production-factory copy shares mixed audio; surviving native wrapper takes ownership after main GUI SIGKILL and applies native-menu routes | fallback/api35/wrapper-ownership/result.json |
| Final DMG install/signature/dependency isolation | Pass:build14 installed from DMG outside build tree; strict signature and24 Mach-O trees | install.json, package.json |
| Actual emulator shutdown/reboot/recovery | Pass:same GUI survives changed boot ID; retained video and new audio owner recover with real1499Hz samples | fallback/api37/disconnect-recovery/result.json |
| Existing launch/wrapper GUI regressions | Pass:shipping-source fixtures, no actual-device claim | regression/launch-ux/, regression/wrapper-failure/ |
| Final owned-device cleanup | Pass:one display,no forwards/reverses/staged audio JARs; only exact owned AVDs stopped | final-device-resources.json |
| Physical Pixel/speaker audibility/OS focus | Not performed | Owner manual verification |

## Failed and intermediate candidates

The installed2fea8581… build13 reached191 successful queued silent PCM blocks but
its launcher stayed Connecting. The real client prefixed the readiness line with
an OSC terminal title; the original exact line parser missed it and timed out.
That is a real product defect, not a passing audio/UI run. The failed native35
run is retained with acceptance=false and baseline restoration. The correction
strips complete bounded OSC(BEL/ST) and CSI controls, then still requires the
exact complete client INFO marker line. Unfinished escapes, payload-embedded
markers, arbitrary prefixes and server-prefixed messages do not qualify. The
final build is14 so copied wrappers can distinguish it from the launched interim.

Earlier9917018… used the first shared preference layout and was never accepted.
Interim install/package records are named explicitly. The first test-only PCM
observer recursively reapplied dyld interposition and crashed; its scoped crash
record is preserved. It was corrected to reference the original SDL function,
then changed to a bounded SPSC ring with background aggregate processing. The
initial all-zero samples are a silence control, not tone acceptance. A negative
client fixture also initially omitted only no-video, but the pinned CLI
normalized no-window into video-disabled; its corrected negative case requests
video by omitting both. No real ADB was invoked by that fixture.

Initial packaging failed rewriting Mach-O dependencies inside a generated app.
An identical outside-app relocation control passed; runtime relocation now occurs
in private build staging before assembly. A later Code Signing subsystem internal
error succeeded on a controlled retry. Signing is bounded to3 attempts; strict
deep verification remains mandatory. These packaging failures are retained.

Initial fallback recording-based attempts exposed test-harness freshness limits, not accepted video results: the still-growing MKV buffered packets and retained an obsolete initial size/index while the completed same-run recording contained later frames. Those attempts remain failed. The final fallback acceptance must establish genuinely changing current-run content and exact source dimensions; delayed/retained images cannot substitute.

## Live evidence boundary

Live tests use only dedicated emulator5580/5582, never emulator5554 or a physical
phone. Android AudioTrack fixtures produce bounded low-volume997/1499Hz tones
from actual app buttons. The test-only observer sees successful SDL PCM
submissions, copies bounded mono samples into a nonblocking SPSC ring and writes
only aggregate RMS/frequency/drop metrics from a background thread. Positive
acceptance requires owned-PID samples, tone ON/OFF/frequency contrast, initialized
output, zero drops, unchanged production argv and actual Android receipts.
No raw audio payload is persisted. Expected-frequency checks use measured silence, a gain-independent spectral tolerance (absent tone below2% of the requested tone), and explicit Stop controls; they do not claim zero spectral leakage. See native/CALIBRATION.md and the independent synthetic calibration under qa/. This proves queued playback, not a human's
hearing or microphone-loopback recording. Public AppKit/SDL actions on the locked
desktop do not prove physical OS focus.

Raw session evidence is scoped to the owned serial; unrelated ADB inventory is
redacted with counts. Shared settings, intent, geometry, panel state and exact
resource baselines must be restored and recorded. Independent Android, macOS and
QA findings distinguish source support, isolated tests and live acceptance.

## Build repeatability

Two consecutive release packaging runs completed. The signed app and archives are not bit-identical: icon-helper JAR timestamps and the private staging path in the recorded ADB version differ, which also changes the resource seal and host signature. Disposable signature-stripped host copies have identical SHA-256 payloads. See repeated-build.json; no byte-for-byte reproducibility claim is made.

## Resource observations

The copied-wrapper run sampled only its owned processes: the shared audio client used approximately30–31MiB RSS and0.9–1.2% CPU in those snapshots, with one capture across main/fallback and native-wrapper apps. These are local observational samples, not a sustained performance benchmark. See the wrapper-ownership result resource_observations.

## Final acceptance boundary

Native and fallback each passed13 phases on both API35 and37. Copied-wrapper ownership passed6 phases, and actual emulator restart passed6 phases. The reboot run recovered video intent and audio automatically; explicit Retry is independently exercised in each normal matrix, rather than claimed to be required in that reboot. Independent QA replays raw sample controls, Android receipts, rendered frame changes and ownership/resource evidence. Final launcher/wrapper source regressions also pass. No test observer ships in the bundle.

The64 accepted live phases total1891 successful aggregate PCM blocks with zero observer drops.

Final evidence uses fresh public SDL Metal renderer readback for fallback API37, wrappers and restart; fallback API35 retains actual changed current-run recording frames with bounded freshness waits. The renderer helper binds request ID,current Player PID,main thread, output dimensions and bitmap dimensions; Retina output is distinguished from Android texture size. Offline red/blue, absent/duplicate/stale-request controls are retained. Earlier recording-based failures and the premature wrapper vmmap attempt remain failed.
