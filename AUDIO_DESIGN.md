# Device audio routing implementation contract

Audio is device-wide, not per virtual display/app. Use the pinned scrcpy5.0.1
client for decoding and SDL/CoreAudio playback in a separate audio-only process,
shared by both video backends. No microphone capture or unrelated app capture
fallback may be silently selected. Existing video sessions remain independent
of audio failures. Preserve mandatory hidden IME in both video backends.

## Ownership

- Systems: Core audio contracts/preferences; Streaming DeviceAudioRouter,
  subprocess/lease/recovery; focused automated tests.
- macOS: LauncherController/UI/native menus and AudioControls integration;
  focused UI tests/fixtures where possible. Do not edit Core/Streaming.
- Android expert: pinned-source research and device/API/source constraints;
  source review and Android test-tone fixture recommendations, read-only unless
  coordinated with lead.
- Lead: Android tone fixture/live integration, script source lists, packaging,
  documents and final evidence; independent QA reviews after implementation.

## Public contract (agree any adjustment before cross-module edits)

Core defines `DeviceAudioRoute: String, Codable, CaseIterable, Sendable` with
`phone`, `mac`, `macAndPhone`. Preferences add per-serial routes with a default
Mac route for new launches; backward decoding must preserve all existing fields.
Settings are shared by main launcher/wrappers through a separate authoritative audio-preferences.json file using the existing locked/atomic store.

Streaming `@MainActor public final class DeviceAudioRouter`:
- init(toolchain: Toolchain)
- onStatusChange: ((String, DeviceAudioStatus) -> Void)?
- reconcile(activeSerials:Set<String>, connectedSerials:Set<String>,
            routes:[String:DeviceAudioRoute])
- retry(serial:String)
- status(for serial:String) -> DeviceAudioStatus
- shutdown() async

`DeviceAudioStatus` exposes route, phase and user-readable message. Phases:
phone, starting, ready, shared, failed. Ready means audio output initialized,
not a claim of audible samples. Shared means another DroidBridge process owns
this serial's route. All lifecycle work must be generation-fenced and bounded.

## Runtime rules

One audio capture/playback process per physical device across independent wrapper
processes, guarded by exact-serial advisory lease and published bounded status.
A non-owner must never kill or reconfigure the owner's subprocess. Preference
changes propagate to the owning host; surviving hosts can acquire the lease
when an owner quits. Last local session releases only this owner's route; if
another process still has a session it may take over. Reconciliation retry is
bounded/backed off; failure never endlessly restarts or blocks video startup.

Mac route: --audio-source=output, silences device playback while capture runs.
Mac+Phone: --audio-source=playback --audio-dup (apps can opt out).
Phone route: no capture process, return to normal phone routing.
Both capture modes: --no-video --no-control --no-window --no-power-on,
--require-audio, explicit --serial and reserved --port; no new display, launch,
keyboard or clipboard options. Start with raw audio to avoid device encoder
compatibility; verify pinned CLI/source. Audio is not persisted to disk in normal
operation. Startup timeout/process failure => visible failure and phone fallback,
explicit Retry and Phone alternatives; no silent source or microphone fallback.

GUI route choice, device-wide scope warning and state/error/retry must be visible
in launcher and available from wrappers/native app menus. Offline devices refuse
new capture. Closing/quitting/disconnect must drain exact owned subprocesses,
leases and tunnels. Shell interpolation is prohibited. Test current system audio
output presence, playback initialized vs audible distinction, failures, retry,
concurrency across wrappers, owner transfer, route changes and recovery.

## Reviewed safeguards

The32 saved-device bound is retained. An unknown device at capacity uses normal
Phone routing and cannot start capture through Retry; accepted existing routes
are preserved. Capacity-driven transitions show pending release until the old
owner is gone. Unreadable preferences stop only local capture and do not rewrite
another host's accepted intent.

The dedicated client emits a positive output-open/resume marker and accepts a
strict31-bit8hex supervised session identity only in audio-only/read-only/forward
mode. Its staged Android JAR is unique per session; video clients cannot collide
with its push/cleanup. Forward creation uses no-rebind. The supervisor checks
serial/local/remote identity before cleanup, and owns staged JAR removal after
GUI crashes. Ordinary audio failures are not readiness or audible-sound claims.

Attempt artifacts are bounded and conservatively collected only with dead owner
and supervisor proof. Retained failure diagnostics contain no PCM and are capped
at32 files of64KiB under AudioRoutes.noindex; directory scans cap512 entries.
The test-only sample observer uses a bounded single-producer ring and background
aggregate metrics, with explicit drop counts; physical speaker listening remains
manual verification.
