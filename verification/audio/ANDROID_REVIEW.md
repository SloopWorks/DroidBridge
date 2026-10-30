# Android audio architecture/source review

Reviewed 2026-10-30 against DroidBridge base `cd65d07`, `AUDIO_DESIGN.md`, and pinned scrcpy5.0.1 source (`a60891aea193d92e7e5c3942700eca63f9d19a5f`). The installed development CLI reports5.0.1. This is source/architecture review, not live audio acceptance. This reviewer did not operate emulators, preferences or device state.

## Capture scope and supported routes

The proposed shared device-wide audio owner is the right boundary. Pinned client audio has no virtual-display or package filter. `AudioDirectCapture` maps `output` to REMOTE_SUBMIX; the normal result routes eligible device output to the Mac and suppresses corresponding device playback while capture is active. This can include audio from Android applications outside the focused Mac window. The UI must call the scope device-wide rather than suggesting one stream belongs to one Android window.

`playback --audio-dup` uses `AudioPlaybackCapture`: a dynamic AudioPolicy playback mix, with LOOP_BACK_RENDER when duplication is requested. This keeps eligible audio on the Android device as well as producing the Mac capture. Without duplication its mix uses LOOP_BACK. The implementation does not select an app UID; its usage rules include multiple Android categories. Existing video sessions must continue to pass no-audio, preventing one capturer per video window.

Neither source is a microphone source. Do not silently replace failed playback duplication with output capture: that changes both privacy scope and whether the phone plays sound. No call, protected-media, notification, alarm or vendor-specific guarantee follows from successful initialization. In particular, although scrcpy's playback rule lists several usages and requests voice communication capture, Android's native policy independently filters LOOP_BACK_RENDER mixes. AOSP15 permits a limited usage set and honors NO_SYSTEM_CAPTURE and, without privileged capture, NO_MEDIA_PROJECTION flags. The upstream maintainer also reported inability to capture a voice call despite that request. Silence from an opted-out app is not necessarily transport failure.

Android's ordinary MediaProjection documentation describes its public capture API restrictions; scrcpy uses shell-authorized dynamic AudioPolicy rather than that permission-popup flow. Do not apply the public three-usage list as a complete description of scrcpy, or infer that privileged shell capture overrides every restriction. An explicit USAGE_MEDIA/ALLOW_CAPTURE_BY_ALL AudioTrack is the appropriate positive fixture; an opt-out fixture is useful for the duplication negative case.

## Version and CLI validation

Pinned direct output capture and raw audio require Android11/API30 or newer. API30 has a foreground/unlocked-start workaround that briefly launches a shell activity; Android12+ uses direct startup. Playback duplication requires Android13/API33. DroidBridge's existing API33 minimum therefore covers both modes without introducing the Android11 popup workaround. Keep explicit minimum-version admission for an audio-only entry point; don't assume its caller necessarily started a video session first.

The following argument-array shapes match pinned CLI parsing:

- Mac: explicit serial/leased port, `--no-video --no-control --no-window --no-power-on --require-audio --audio-codec=raw --audio-source=output`.
- Mac + Phone: the same safety flags with `--audio-source=playback --audio-dup`.
- Phone: no audio capturer; drain only the exact owned capture process/tunnel before reporting normal phone routing.

Keep `--no-control` explicit. Pinned audio documentation's shorthand says no-window implies no-control, but the current CLI parser deliberately retains controls without a window. No-video disables startup power-on as a parser side effect; the explicit no-power-on flag still communicates and pins the desired behavior. No new-display, start-app, keyboard, clipboard, microphone, power-toggle, kill-adb-on-close, recording or no-playback option belongs on the normal audio route. No-playback/no-audio-playback would defeat Mac output. Force-adb-forward is a tunnel-direction choice, not an audio source or screen-power policy.

Raw is PCM16LE,48kHz,stereo on the Android wire:192000bytes/second before framing. It avoids Android encoder availability, not host decoding/playback dependencies. The pinned Mac client still decodes and converts to interleaved F32LE for SDL output.

## Readiness and failure feedback

The unmodified pinned audio player has no positive log after successful SDL output open/resume. Its debug decoder-selection line occurs before codec-context creation and frame-sink initialization, so it is not readiness evidence. The regulator's sample log statements are compiled out by default, even at debug verbosity. Server connection and an alive process are also insufficient.

The lead's agreed separate `DroidBridgeAudioClient` is appropriate: a tracked minimal patch emits `DROIDBRIDGE_AUDIO_OUTPUT_READY` only after SDL_OpenAudioDeviceStream succeeds and SDL_ResumeAudioDevice returns success. That execution point follows receipt of the Android audio header and opening the audio frame sink. The video Player remains unchanged. Pin the audio client/server/build inputs and notices; recognize the exact marker only from the currently owned generation's child. A later process failure must still replace ready with visible failure.

This marker means **output initialized**, not that nonzero samples exist or the user's speakers are audible. Audio can legitimately be silent, the current system output can be muted/unplugged, or an app can opt out. A default-output presence check is a useful preflight but cannot replace the child marker. The product should offer visible Retry and Phone alternatives without requiring terminal diagnostics. A failed Mac+Phone route must not silently switch to output/muting capture.

Pinned error evidence includes SDL subsystem/open/resume failure logs, decoder/demuxer errors and server capture/configuration errors. The client uses exit0 for normal termination,1 for failure and2 for disconnection; preserve the distinction from POSIX signal termination and supervisor stop receipts. No-video also makes require-audio mandatory internally. Initialization/capture failure therefore terminates the audio client rather than keeping a fake healthy silent audio-only process. However, a live silent stream can remain initialized and is not automatically an error. Bound startup waits/retries; video admission and playback remain independent of audio failure.

## Phone restoration, screen OFF and ownership

Capture lifetime changes routing; broad persistent Android volume, audio-focus or keyboard changes are unnecessary. Direct capture releases AudioRecord in its finally path. Playback capture also releases AudioRecord, but registers a dynamic AudioPolicy whose lifetime is tied to its callback/process; Android AudioService's binder-death handler releases the policy/mixes. Await actual owned client/server/tunnel drain before assuming the previous route has ended, especially during route changes and crash recovery. Normal phone routing means the user's existing Android volume, headset and app policy, not a promise of speaker sound when muted. Preserve settings rather than restoring guessed values over concurrent phone changes.

The API33+ capture paths contain no dependency on display0 being ON, nor a power-on actuation. Existing virtual-display keep-active and explicit phone-panel control stay separate. An Android app may pause playback after losing focus, stopping its activity, or entering background policy; silence in that state must be distinguished from a capture failure. Screen-OFF acceptance needs actual app write receipts plus host sample evidence, not a source-only assumption.

A single exact-serial lease across launcher and copied wrappers prevents duplicate device capture. A non-owner must observe shared ownership and propagate preference intent, never kill another host's capture. Use a stable lock inode, owner/generation identity and bounded atomic published status; stale ready files alone cannot establish a live owner. Different serials must not contend on one global audio lock.

The owner lease must survive GUI death until the supervisor drains the child and exact Android cleanup. Otherwise a successor can acquire the released GUI lock while the old capturer still suppresses/duplicates audio. The lead/systems team agreed that the supervisor retains the per-device lease through cleanup, while stdin retains the existing port lease. Last-local-session release and takeover by a surviving wrapper are valid but may produce a short gap; do not claim gapless ownership transfer. This coordination covers DroidBridge participants, not arbitrary external scrcpy/audio tools.

Force-adb-forward cleanup must bind exact serial/local port/remote socket identity. Socket shutdown makes raw capture exit on EOF/broken pipe, release capture and finish the Android server; parent-crash cleanup must not rely only on a GUI state transition. Avoid deleting a foreign forward that replaced an owned mapping, killing a shared ADB server, or starting a second capture before the first has drained.

## Deterministic executable acceptance

The lead's fixture design is suitable: bounded10-second explicit start/stop,48kHz stereo PCM16 AudioTrack with USAGE_MEDIA, CONTENT_TYPE_MUSIC, ALLOW_CAPTURE_BY_ALL and manifest allowAudioPlaybackCapture=true;997Hz and1499Hz distinguish two app sources. Different package identities avoid Android single-task movement being mistaken for concurrent independent producers. Use a finite worker with automatic stop/release and Android-side creation/write/play-state receipts. AudioTrack is preferable to ToneGenerator because exact PCM samples, usage and capture policy are under test control.

A test-only observer of the installed audio client's actual SDL_PutAudioStreamData can verify nonzero finite F32LE PCM, sample counts, RMS and expected tone frequency after the Android app starts. The pinned audio callback may produce initial/underflow silence; callback invocation alone is insufficient. Use tone ON/OFF or frequency changes as a causal control and avoid doing file I/O in the real-time callback. This proves samples reached the real Mac output queue, not physical speaker audibility or per-display audio isolation. It does not require shipping a production DYLD observer or recording device content during normal use.

Run both routes on API35/API37 with both video backends, physical panel ON/OFF, route changes, explicit Phone, invalid/unavailable host output, forced audio-client failure, disconnect/reconnect and owner-transfer across wrappers. Verify one capture per serial, different-device independence, no second video/audio process per extra window, exact cleanup and preserved device/Mac state. Launcher and wrapper menus must exercise the actual route/retry/phone controls and show the shared device-wide status. Keep initialization, real nonzero samples and physical audibility as distinct evidence layers.

## Review verdict and primary references

Architecture and the agreed readiness patch are supported by pinned source, conditional on executable lifecycle/ownership/UI/sample evidence. No audio route, restoration or screen-OFF result is marked passed by this research review.

- [Pinned audio documentation](https://github.com/Genymobile/scrcpy/blob/v5.0.1/doc/audio.md)
- [Pinned CLI parser](https://github.com/Genymobile/scrcpy/blob/v5.0.1/app/src/cli.c)
- [Pinned direct capture](https://github.com/Genymobile/scrcpy/blob/v5.0.1/server/src/main/java/com/genymobile/scrcpy/audio/AudioDirectCapture.java)
- [Pinned playback/duplication mix](https://github.com/Genymobile/scrcpy/blob/v5.0.1/server/src/main/java/com/genymobile/scrcpy/audio/AudioPlaybackCapture.java)
- [Pinned raw capture and release](https://github.com/Genymobile/scrcpy/blob/v5.0.1/server/src/main/java/com/genymobile/scrcpy/audio/AudioRawRecorder.java)
- [Pinned host audio initialization/callback](https://github.com/Genymobile/scrcpy/blob/v5.0.1/app/src/audio_player.c)
- [Pinned decoder initialization order](https://github.com/Genymobile/scrcpy/blob/v5.0.1/app/src/decoder.c)
- [Pinned audio regulator debug guards](https://github.com/Genymobile/scrcpy/blob/v5.0.1/app/src/audio_regulator.c)
- [Pinned exit/error handling](https://github.com/Genymobile/scrcpy/blob/v5.0.1/app/src/scrcpy.c)
- [Upstream alternate-capture rationale and call limitation](https://github.com/Genymobile/scrcpy/issues/4380)
- [Android15 native audio-mix filtering](https://android.googlesource.com/platform/frameworks/av/+/android-15.0.0_r1/services/audiopolicy/common/managerdefinitions/src/AudioPolicyMix.cpp)
- [Android15 duplication route semantics](https://android.googlesource.com/platform/frameworks/base/+/android-15.0.0_r1/media/java/android/media/audiopolicy/AudioMix.java)
- [Android15 dynamic-policy binder-death cleanup](https://android.googlesource.com/platform/frameworks/base/+/android-15.0.0_r1/services/core/java/com/android/server/audio/AudioService.java)
- [Android public capture policy overview](https://developer.android.com/media/platform/av-capture)
