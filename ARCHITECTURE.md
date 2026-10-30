# DroidBridge as-built architecture

DroidBridge is a Swift/AppKit application. Android executes every application on an authorized USB ADB device or emulator. Each session creates its own Android virtual display and task. Device video remains on the local Android/Mac connection; no external service receives screen content or input.

## Modules

`DroidBridgeCore` contains Codable device/application/session descriptors, backend selection, strict external-input validation, aspect-fit coordinate transforms, bundled-first tool resolution, and asynchronous bounded subprocess execution. The process runner uses executable/argument arrays rather than a shell and stages combined output in bounded temporary files.

`DroidBridgeStreaming` owns `@MainActor BridgeSession`, state transitions, logs/metrics, startup fencing, scrcpy protocol serialization, socket transport, H.264 decoding, and recovery receipts. The public session operations are async `start()`, synchronous `resize(width:height:)`, `sendInput(_:)`, `stop()`, and async `stopAndWait()`. Frame/state/metric callbacks return to the main actor; socket and decoder work runs on background queues. A stopped session is terminal; restoration creates a new session.

`LauncherUI` composes the native two-pane launcher using existing controller-owned controls and selectors. Its presentation refresh performs no network, catalog or process admission. Sidebar and session documents track their own scroll viewport widths. A per-session presentation fingerprint preserves control identity and keyboard focus during unchanged polling. App discovery uses explicit loading/error serials plus a request-generation fence; superseded selection tasks are retained and all are drained on shutdown. Launch and Spotlight setup enablement share their action predicates, and numeric app counts require an authorized, ready, matching loaded catalog. Return routes only from search/table; Find App menu validation leaves Android-window shortcuts alone.

`DroidBridge` owns the native launcher, device/app search, session registry, native rendering views/windows, keyboard/mouse mapping, persistence, reconnect polling, menus and application wrappers. No video decoding or blocking ADB command runs in UI composition.

`DroidBridgeSupervisor` is a small C executable outside the GUI's lifetime. It launches the exact session child in a dedicated process group, monitors its original parent and child, and stops only its owned process group when the GUI exits or crashes. Native sessions supply exact ADB forward and remote-JAR cleanup arguments. Cleanup is bounded and uses argument arrays.

## Two backends, one session model

The **scrcpy** backend starts the pinned upstream 5.0.1 client with `--new-display`, `--start-app`, `--flex-display`, H.264 and no audio. Upstream SDL windows own their event and resize handling. DroidBridge tracks the supervised client lifecycle and offers launch/close controls. Concurrent fallback clients receive distinct host TCP ports from cross-process leases. The supervisor inherits each lease through stdin and retains it through parent-crash cleanup, avoiding the pinned client’s reverse-tunnel/bind startup race. Foreign listeners are skipped. External windows have standard upstream controls; the launcher's native Focus action is disabled for this backend.

The **native** backend pushes the matching scrcpy 5.0.1 server, obtains a random session ID and dynamic loopback ADB forward, and starts the server on Android. Separate video/control connections use scrcpy's version-specific protocol. Session/codec headers and bounded packet lengths are validated. Android MediaCodec emits H.264 Annex-B data; VideoToolbox decodes it, CoreImage creates CGImages, and an AppKit NSView renders those live frames. The native Swift process does not link FFmpeg.

The fallback always adds pinned scrcpy's `--no-mouse-hover`. Buttonless motion caused an InputDispatcher crash on Android15/API35 and prevented clicks on Android17/API37 in actual tests; suppressing it restored input. Clicks, drags and scrolling remain enabled. Hover-only tooltips are unavailable. The native backend also does not forward hover events. Argument-policy tests cover API33–37; actual device evidence is limited to the tested emulator versions.

The view uses the same aspect-fit transform for drawing and pointer coordinates. Letterbox clicks are rejected; an active drag can finish outside the image with coordinates clamped to the edge. Mouse, drag, scroll, keys, text, Back and Mac-to-Android clipboard paste become scrcpy control messages. Native resize is debounced, bounded, and sends scrcpy's virtual-display resize message. Initial session startup requires an actual decoded frame, rather than merely a process or empty window.

## Lifetime, failure and recovery

Every startup has a generation fence; late frame, process and transport callbacks cannot revive a closed session. Serial/package and dimensions are validated before work. Startup cancellation retains ownership of late ADB allocations. `stopAndWait()` waits for in-flight startup completion and drains cleanup work, including cleanup registered after cancellation. AppKit delayed termination waits for active and recently closed sessions before exiting.

Wrapper startup creates a local icon/name loading host before recovery or Android I/O. The immutable bundle launch identity bypasses full app enumeration; authorization, readiness and managed admission still run. The same native NSWindow is attached after admission, retains its loading content through startup, and swaps to decoded frames after a bounded 8×8 thumbnail detects visible content. Initial solid-black frames retain the local splash; after 5 seconds they show a blank-video explanation and an explicit reveal control, which permits interaction with legitimate dark content. The explanation clears automatically when visible video arrives. Early-close cancellation is checked again at final admission; reopen reuses the loading host. AppKit autosave keys bind device/package and restore points separately from Android pixels. Programmatic setup cannot overwrite a saved frame; restored geometry is clamped to the visible screen. First-frame presentation respects a deliberate minimize. Fallback handoff requires both the expected package launch receipt and the pinned client’s video-texture log. The supervisor uses a raw PTY for fallback output and relays a bounded nonblocking diagnostic batch, making the unchanged client’s readiness lines observable before it exits. Public CGWindow bounds are sampled at most twice per second only for the receipt-bound child whose live parent is the current supervisor. WindowServer optical insets are calibrated against the loading host’s own same-style AppKit frame before handoff, and SDL position uses content top, avoiding titlebar/optical drift. Unknown/minimized metadata preserves the last size; no pixels or unrelated window titles are captured.

Before native staging, an immutable session receipt records owner PID, device serial and random scrcpy session ID. Recovery skips active owners (including independent wrappers), validates identities, and removes only abandoned matching forwards and the derived remote JAR. Offline cleanup retains the receipt for a later retry. The launcher completes recovery before beginning discovery polling or new admission. The supervisor handles running-child crash cleanup; receipts cover the earlier staging interval.

Closing a session destroys its virtual display and its tasks under scrcpy's default content policy. Android controls persistent app state, task affinity, orientation and activity recreation. Saved session intent supports explicit restore after relaunch, while enabled reconnect polling waits for boot completion and package-service readiness before replacing disconnected sessions. Readiness is reconsidered on later polls even if the device list is unchanged. Each outage permits three failed launches with at least eight seconds between failures; closing an intent cancels its retry. Discovery results are fenced against a changed selection or application shutdown.

## Native application experience

AppKit windows supply move/resize/minimize/full-screen controls, focus and Mission Control integration. Windows in the main launcher process share one Cmd+Tab identity. Generated wrappers copy the Mach-O executable into separate bundles with package-specific application identities and launch parameters. They use isolated intent stores and copy the pinned runtime into each wrapper, so each wrapper is independently portable and can pass strict signature verification. Explicitly closing the final wrapper session ends that wrapper process; unexpected termination retains visible diagnostics and retry/fallback controls.

`AndroidIconProvider` runs the bundled original DEX helper through authorized ADB shell, resolves the MAIN/LAUNCHER activity or alias (with a Leanback fallback) and has Android render its drawable to a bounded 512-pixel PNG. It awaits exact temporary-file cleanup. Wrapper creation runs off the main actor, converts that PNG to ICNS, signs and verifies a complete staged bundle, and atomically publishes it. Updates retain original launch settings and a recoverable previous generation. Each wrapper declares its own Android icon and loads it as the running NSApplication icon. See `WRAPPER_DESIGN.md` for failure policy and boundaries. Spotlight indexing and switching behavior must be reported from observed tests, not inferred from bundle IDs.

For fallback wrappers the copied Player bundle also receives a package-specific identity and Android name/icon. The wrapper host uses accessory activation while a Player owns the live window, and restores regular activation when showing terminal diagnostics. Launcher icon loading has two active requests, a 64-entry queue and a 128-entry cache; application termination cancels and awaits icon and wrapper-creation tasks alongside session cleanup.

Icon requests persist an ownership receipt before any remote staging. The tracked device-refresh task performs finite, time-budgeted recovery before discovery: live PID owners and exact active producer commands are preserved; abandoned request UUIDs derive exact temporary JAR/PNG paths; unavailable devices retain their receipts. Subsequent polls retry retained requests with a rotating capped batch, and shutdown cancels and awaits refresh work. This covers abrupt host death as well as awaited normal cleanup. Native wrapper presentation is repeated at first decoded frame and on application reopen, with bounded visibility/activation facts and caller-specific stop reasons in the session log.

## Managed device applications

Bulk onboarding is explicit and controlled by a default-enabled shared preference. A captured device/application cohort runs with at most two workers; completed wrappers persist across cancellation. `ManagedAppCatalog` in Core owns a bounded local manifest, cross-process locking, generation-fenced reservations/publication and durable Launch Services actions. The off-main wrapper factory clones runtime files using copy-on-write where available, signs/verifies a private generation and publishes only complete bundles. Existing matching manual wrappers require ownership validation before migration; unrelated or running apps remain protected.

Managed identities include a device hash and Android package. Public bundles live below `~/Applications/DroidBridge Apps/Devices`; unavailable bundles and previous generations live below `~/Library/Application Support/DroidBridge/ManagedApps.noindex`. Availability is positive authorization plus boot/package-service readiness. Missing, unauthorized, failed probes and feature-off state fail closed. Exact owned bundles move atomically; Launch Services work runs outside catalog locks and is reconciled through durable receipts. Launch admission checks also protect against stale indexed results.

`DroidBridgeAvailability` is a Core-only executable installed as an owned per-user LaunchAgent after the first explicit onboarding. Its stable helper/runtime survives host-bundle movement and GUI quit. It probes only device/catalog readiness and reconciles the same catalog, with bounded work and retries. Shared atomic preferences are read by the GUI, wrappers and helper. Turning bulk onboarding off retains history while hiding managed apps and stopping Android polling. See `APP_ONBOARDING_DESIGN.md` for contracts and `BUILD.md` for uninstall steps.

Managed wrapper filenames contain only the Android label, with readable package disambiguation for actual same-device collisions. A main-GUI-only bounded maintenance controller upgrades incompatible copied executables before changing any hashed paths, then republishes signed clean-name bundles using saved icons and launch options. Durable retired-path ownership compensates delayed Launch Services callbacks after filename changes; IDs and offline admission remain stable.

Session configuration pins `showSystemDecorations`; older JSON defaults to true. The fallback maps false to `--no-vd-system-decorations`, while native passes `vd_system_decorations` to the matching scrcpy server. This controls the virtual display only and does not remove application-drawn UI.

## Physical phone display control

Both backends enable pinned scrcpy virtual-display keep-active behavior and disable startup power-on. Every session uses the owned virtual display's hidden IME policy: `--display-ime-policy=hide` for the fallback and `display_ime_policy=hide` for the native server. This is a runtime invariant, independent of decorations or persisted session configuration. Android's software keyboard cannot be requested locally or redirected to the phone by old saved settings. Shared startup refuses Android versions before API33, or an unreadable API level, before staging or launching anything, because older Android either lacks the hide policy or lacks trusted displays in the pinned runtime. Mac key/text injection still targets the Android display directly. Activity signals target the virtual display every four seconds; no global keyboard, stay-awake or timeout setting changes. Per-device screen-off intent is an opt-in serial set in shared preferences. The launcher and independent wrappers apply it only to their running devices, with finite polling, backoff and a separate short-lived actuation task. Explicit Phone-menu Off/On controls also work without a running session. Pending failed On actions retry while their host remains open; a newer Off intent supersedes them.

Core `PhoneDisplayPower` serializes actuation across processes with per-device filesystem locks, outside catalog/preference critical sections. Only authorized serials and physical display 0 are addressed. It detects advertised Android 15+ commands, handles nonzero read-only help exits, reads actual display state, and verifies effects. Android 17 uses power-reset and, if normal policy is asleep, the advertised display-scoped power wakeup command. Fresh intent checks before/after asynchronous boundaries compensate superseded effects in either direction. Closing any or all sessions never implicitly wakes the phone; explicit user intent persists. Lock/PIN and secure-content policy remain Android behavior.

## Build and evidence

The runtime is pinned to scrcpy 5.0.1 and the captured Homebrew versions. Packaging recursively bundles and relinks Mach-O dependencies, collects notices, ad-hoc signs the application, verifies signatures, and emits a DMG, ZIP and SHA-256 checksums. The packaged runtime requires Apple Silicon/macOS 26; the Swift source's lower deployment target is not a portability claim for those bundled dependencies.

Unit, actual emulator, AppKit event/rendering, lifecycle, recovery, supervisor, installed-bundle and GUI checks are separate evidence layers. See `TESTING.md`, `verification/REPORT.md`, and independent review in `verification/review/`. The physical Pixel 10 Pro stage is explicitly deferred to its owner.

## Device-wide audio

Both video backends keep their own audio disabled and share DeviceAudioRouter.
For each active device, it starts a separate audio-only pinned scrcpy5.0.1 client
(raw PCM) with no video, input, window, clipboard or power-on. CoreAudio confirms
an available output; a tracked client patch emits readiness only after successful
SDL output open/resume. Mac uses output capture; Mac + Phone uses playback+dup;
Phone has no capture. No per-app isolation or physical audibility is inferred.

A supervisor-held per-serial lease spans playback and teardown, including GUI
crashes. Per-attempt receipts are followed through the UUID in that lease inode;
late old-GUI status cannot publish over a successor. A route/retry-scoped failure
latch is fenced by the supervisor, preventing wrappers repeatedly restarting a
failed capture. Explicit Retry or a route change admits a new attempt. Port
leases persist through exact serial/local/remote forward cleanup. The custom
client uses no-rebind and delegates supervised forward cleanup to the owner.
Launcher and native-wrapper menus share atomic audio-preferences.json independently of the older screen/Spotlight settings file; legacy wrappers cannot erase audio intent. Audio work and
failure are independent of video sessions. See AUDIO_DESIGN.md and
verification/audio/ for contracts, limits and executable evidence.

## Android companion boundary (0.2 development candidate)

The companion extends discovery, explicit sharing and controls; scrcpy remains
the video, input, display-power and audio implementation. No video or PCM crosses
the companion API. The ordinary Android foreground service listens only on
`127.0.0.1:37841` using TLS1.2/1.3 and an installation-stable Android Keystore
P-256 identity. Mac transport uses an exact-owned ADB forward over USB/emulator
or Android's authenticated wireless-debugging transport. It never opens an
unauthenticated LAN listener or enables debugging silently.

Enrollment starts with the complete phone-generated URI: a short-lived secret,
expiry, installation UUID and exact certificate fingerprint. The Mac verifies
that pin, certificate validity and loopback hostname before sending HTTP bytes,
then matches the installation UUID before submitting the secret. The phone
requires explicit approval of the named Mac and comparison code. Saved trust
binds installation UUID, trust ID, credential and pin in one Keychain record;
Android persists sensitive state encrypted with Keystore-backed AES-GCM. No
TOFU, bare-secret enrollment or plaintext fallback is supported. Ad-hoc updates
can make an old Mac Keychain ACL inaccessible; the store fails promptly without
UI, and explicit Forget/re-pair preserves separate export/profile intent.

`DroidBridgeCompanionBroker` is a per-user NSXPC service and the single owner of
companion credentials, pinned connections and event polling. Its private runtime
is installed independently of the GUI bundle. Requests are bounded JSON,
authenticated by same-user peer identity plus a private nonce. The broker owns a
private, bounded journal published through file fsync, rename and directory
fsync. Immutable request IDs and canonical receipts distinguish accepted,
applied, rejected and unknown outcomes; an uncertain external effect is not
reported as exactly-once execution. Per-trust event epochs/cursors force a
snapshot after expiry and fence revocation. Read-only status does not start a
new phone operation.

Verified phone installation UUIDs are canonical identities; ADB serials are
transport aliases. Cross-process filesystem leases admit concurrent video/audio
sessions on one selected alias and refuse another alias until cleanup drains.
Supervisors retain ownership through GUI crashes and exact process/forward/JAR
teardown. Session registry entries bind process start identity and generation.
This protocol applies to updated hosts; close old0.1 hosts/audio and update
wrappers before pairing or switching aliases. Old executables cannot acquire the
new canonical leases. Companion revocation does not revoke ADB authorization or
terminate an otherwise independent ADB capture.

Transport reservation registers a recoverable ownership receipt before ADB
allocation. Failed close remains owned and retries with finite backoff even
when journal publication is unavailable. Removal checks the exact
serial/local/remote tuple and preserves a replaced mapping. Shutdown fences late
hello/identity/admission replies, policy/credential publication and journal
writes. The owner lock remains until accepted requests drain; it cannot authorize
a second writer while late work can still publish.

Control scheduling permits one request per canonical phone and four globally,
with bounded fair eligible queues. Bulk work has a separate global limit of two
and profile-specific per-phone capacity. Catalog pages contain at most64 apps;
JSON, icons, file sizes, staged bytes, transfer slots and event retention have
hard bounds in `docs/companion/BOUNDARY_CONTRACT.md`. Files use64KiB raw chunks,
SHA-256 verification and explicit Open/Save decisions. Shared files are not
executed or automatically opened; received Mac files retain quarantine. Clipboard
handoff is an explicit user action with foreground Android access. Optional
notification access is granted through Android settings; replies bind the current
notification generation and actual RemoteInput action.

Notification controls require the `notification_scope_v2` capability and an exact
expected trust UUID in both IPC and the hashed phone command. The broker fences
queue admission, original inbox origin and transport generation; the phone checks
scope before receipt lookup or execution. A reset/changed event epoch or an event
poll's authorization refusal clears only the affected device's active notification
projection, preserving shares. Cancelled pollers carry generation/token fences
and cannot tear down a newer authenticated connection. AppKit permission callbacks
also bind the current intent, window lifetime, phone, trust and edited filters.

Phone export selections bind monotonic policy revisions to managed Mac wrapper
admission. Reconciliation preserves names/icons, offline hiding and stale-result
refusal. The phone dashboard uses the cross-process host registry, so typed
Open/Stop/Audio/Screen requests can target independent wrappers. Profiles select
15/30/60fps for new streams,1/2/5s publication/status cadence and bounded asset
work without changing global Android settings. Unchanged peer-state heartbeats
are capability-negotiated; older protocol1 peers receive complete state.

The phone offers an explicit official Mac release lookup. Its versioned manifest
pins architecture, minimum OS, artifact size, SHA-256 and fixed GitHub URLs.
Missing or invalid metadata disables download controls. An ordinary phone app
cannot install or approve a Mac application. Publication and installed-flow
acceptance are tracked separately from implementation in
`verification/companion/PROGRAM_STATUS.md` and `docs/companion/ROADMAP.md`.

Source-built ADB37 ships as a separately signed flat cohort with a hash-bound
inventory, exact sibling dynamic dependencies and upstream notices. Private
broker and availability generations copy and verify that complete cohort
without changing bytes. Availability keeps its eight-generation cap; broker
keeps four. Their bounded recovery journals preserve validated current plist
pins, live process/lease owners and unverified bytes rather than deleting an
unknown generation. Exact source archives, patches, build recipes and provenance
are prepared alongside release artifacts; see `docs/companion/ADB_RUNTIME.md`.
