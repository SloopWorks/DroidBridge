# DroidBridge architecture

Swift Package, macOS 13+, AppKit launcher. Android executes every application. No capture leaves the host/device.

## Ownership and integration contracts

- Android expert: `Sources/DroidBridgeCore/AndroidDiscovery.swift`, `Toolchain.swift`, `ProcessRunner.swift`, Android capability/discovery tests, `scripts/android-*`, `verification/android`, `COMPATIBILITY.md`. Public `Toolchain` resolves `adb`, `scrcpy`, `server`; `AndroidDiscovery(toolchain:)` exposes async `devices() -> [AndroidDevice]`, `applications(device:) -> [AndroidApplication]`, `capabilities(device:)`. Core Models.swift belongs to lead.
- Systems expert: all `Sources/DroidBridgeStreaming/`, backend/protocol tests. Public `@MainActor BridgeSession` object initialized with `SessionDescriptor` and `Toolchain`; `start() async throws`, `stop()`, `resize(width:height:)`, `sendInput(_:)`. Expose `onFrame: ((CGImage) -> Void)?`, `onState: ((SessionState, String?) -> Void)?`, `onMetrics`, and `descriptor`. Define AndroidInputEvent and metrics in Streaming. Backend A scrcpy external window; backend B native scrcpy server protocol with VideoToolbox or another tested decoded stream. No private APIs.
- macOS expert: all `Sources/DroidBridge/`, `scripts/package.sh`, Resources and packaging. Imports Core + Streaming contracts. Owns session registry, window routing, persistence/restoration, launcher, wrappers. Backend B uses an NSView consuming onFrame and generating AndroidInputEvent. Backend A external window lifecycle owned by BridgeSession.
- Independent QA: `scripts/verify*`, QA tests, `verification/review`, `TESTING.md`; no production changes without coordination. Reviews and rejects claims without actual execution.
- Lead: Package.swift, Models.swift, integration fixes by agreement, release docs, overall verification report.

Independent files are shared in a new repository; do not revert another agent's changes. Use Swift 5 language mode initially for reliable interoperability; main-actor application state and explicit background I/O. Pin scrcpy client/server to installed version. All process commands use argument arrays, validated package IDs, scoped serials, bounded output, and deterministic teardown. Default closing policy destroys the virtual display and its tasks. Reconnection restores a new session from persisted intent, never silently reruns arbitrary shell commands.

## Evidence

Only tests actually run on the host/emulator may be marked passed. Pixel physical verification is deferred to the owner. Compilation alone is not functional evidence. Independent Cmd+Tab identities require separate launchable application bundles and must be tested separately.
