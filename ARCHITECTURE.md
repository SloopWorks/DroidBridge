# DroidBridge as-built architecture

DroidBridge is a Swift/AppKit application. Android executes every application on an authorized USB ADB device or emulator. Each session creates its own Android virtual display and task. Device video remains on the local Android/Mac connection; no external service receives screen content or input.

## Modules

`DroidBridgeCore` contains Codable device/application/session descriptors, backend selection, strict external-input validation, aspect-fit coordinate transforms, bundled-first tool resolution, and asynchronous bounded subprocess execution. The process runner uses executable/argument arrays rather than a shell and stages combined output in bounded temporary files.

`DroidBridgeStreaming` owns `@MainActor BridgeSession`, state transitions, logs/metrics, startup fencing, scrcpy protocol serialization, socket transport, H.264 decoding, and recovery receipts. The public session operations are async `start()`, synchronous `resize(width:height:)`, `sendInput(_:)`, `stop()`, and async `stopAndWait()`. Frame/state/metric callbacks return to the main actor; socket and decoder work runs on background queues. A stopped session is terminal; restoration creates a new session.

`DroidBridge` owns the native launcher, device/app search, session registry, native rendering views/windows, keyboard/mouse mapping, persistence, reconnect polling, menus and application wrappers. No video decoding or blocking ADB command runs in UI composition.

`DroidBridgeSupervisor` is a small C executable outside the GUI's lifetime. It launches the exact session child in a dedicated process group, monitors its original parent and child, and stops only its owned process group when the GUI exits or crashes. Native sessions supply exact ADB forward and remote-JAR cleanup arguments. Cleanup is bounded and uses argument arrays.

## Two backends, one session model

The **scrcpy** backend starts the pinned upstream 5.0.1 client with `--new-display`, `--start-app`, `--flex-display`, H.264 and no audio. Upstream SDL windows own their event and resize handling. DroidBridge tracks the supervised client lifecycle and offers launch/close controls. External windows have standard upstream controls; the launcher's native Focus action is disabled for this backend.

The **native** backend pushes the matching scrcpy 5.0.1 server, obtains a random session ID and dynamic loopback ADB forward, and starts the server on Android. Separate video/control connections use scrcpy's version-specific protocol. Session/codec headers and bounded packet lengths are validated. Android MediaCodec emits H.264 Annex-B data; VideoToolbox decodes it, CoreImage creates CGImages, and an AppKit NSView renders those live frames. The native Swift process does not link FFmpeg.

The view uses the same aspect-fit transform for drawing and pointer coordinates. Letterbox clicks are rejected; an active drag can finish outside the image with coordinates clamped to the edge. Mouse, drag, scroll, keys, text, Back and Mac-to-Android clipboard paste become scrcpy control messages. Native resize is debounced, bounded, and sends scrcpy's virtual-display resize message. Initial session startup requires an actual decoded frame, rather than merely a process or empty window.

## Lifetime, failure and recovery

Every startup has a generation fence; late frame, process and transport callbacks cannot revive a closed session. Serial/package and dimensions are validated before work. Startup cancellation retains ownership of late ADB allocations. `stopAndWait()` waits for in-flight startup completion and drains cleanup work, including cleanup registered after cancellation. AppKit delayed termination waits for active and recently closed sessions before exiting.

Before native staging, an immutable session receipt records owner PID, device serial and random scrcpy session ID. Recovery skips active owners (including independent wrappers), validates identities, and removes only abandoned matching forwards and the derived remote JAR. Offline cleanup retains the receipt for a later retry. The launcher completes recovery before beginning discovery polling or new admission. The supervisor handles running-child crash cleanup; receipts cover the earlier staging interval.

Closing a session destroys its virtual display and its tasks under scrcpy's default content policy. Android controls persistent app state, task affinity, orientation and activity recreation. Saved session intent supports explicit restore after relaunch, while enabled reconnect polling waits for boot completion and package-service readiness before replacing disconnected sessions. Readiness is reconsidered on later polls even if the device list is unchanged. Each outage permits three failed launches with at least eight seconds between failures; closing an intent cancels its retry. Discovery results are fenced against a changed selection or application shutdown.

## Native application experience

AppKit windows supply move/resize/minimize/full-screen controls, focus and Mission Control integration. Windows in the main launcher process share one Cmd+Tab identity. Generated wrappers copy the Mach-O executable into separate bundles with package-specific application identities and launch parameters. They use isolated intent stores and copy the pinned runtime into each wrapper, so each wrapper is independently portable and can pass strict signature verification. Explicitly closing the final wrapper session ends that wrapper process; unexpected termination retains visible diagnostics and retry/fallback controls.

`AndroidIconProvider` runs the bundled original DEX helper through authorized ADB shell, resolves the MAIN/LAUNCHER activity or alias (with a Leanback fallback) and has Android render its drawable to a bounded 512-pixel PNG. It awaits exact temporary-file cleanup. Wrapper creation runs off the main actor, converts that PNG to ICNS, signs and verifies a complete staged bundle, and atomically publishes it. Updates retain original launch settings and a recoverable previous generation. Each wrapper declares its own Android icon and loads it as the running NSApplication icon. See `WRAPPER_DESIGN.md` for failure policy and boundaries. Spotlight indexing and switching behavior must be reported from observed tests, not inferred from bundle IDs.

For fallback wrappers the copied Player bundle also receives a package-specific identity and Android name/icon. The wrapper host uses accessory activation while a Player owns the live window, and restores regular activation when showing terminal diagnostics. Launcher icon loading has two active requests, a 64-entry queue and a 128-entry cache; application termination cancels and awaits icon and wrapper-creation tasks alongside session cleanup.

Icon requests persist an ownership receipt before any remote staging. The tracked device-refresh task performs finite, time-budgeted recovery before discovery: live PID owners and exact active producer commands are preserved; abandoned request UUIDs derive exact temporary JAR/PNG paths; unavailable devices retain their receipts. Subsequent polls retry retained requests with a rotating capped batch, and shutdown cancels and awaits refresh work. This covers abrupt host death as well as awaited normal cleanup. Native wrapper presentation is repeated at first decoded frame and on application reopen, with bounded visibility/activation facts and caller-specific stop reasons in the session log.

## Build and evidence

The runtime is pinned to scrcpy 5.0.1 and the captured Homebrew versions. Packaging recursively bundles and relinks Mach-O dependencies, collects notices, ad-hoc signs the application, verifies signatures, and emits a DMG, ZIP and SHA-256 checksums. The packaged runtime requires Apple Silicon/macOS 26; the Swift source's lower deployment target is not a portability claim for those bundled dependencies.

Unit, actual emulator, AppKit event/rendering, lifecycle, recovery, supervisor, installed-bundle and GUI checks are separate evidence layers. See `TESTING.md`, `verification/REPORT.md`, and independent review in `verification/review/`. The physical Pixel 10 Pro stage is explicitly deferred to its owner.
