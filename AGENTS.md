# DroidBridge agent guide

The architecture and ownership contracts live in ARCHITECTURE.md. Preserve concurrent changes and coordinate API changes. Source modules are Core (discovery/process), Streaming (scrcpy/native transport), and DroidBridge (AppKit UI). Android applications execute on Android. Native means actual decoded video inside an AppKit NSView; an empty window or screenshot stream does not qualify.

Use argument arrays, validate package names and serials, keep I/O off MainActor, fence late session callbacks, and clean up exact owned forwards/processes/displays. Never kill a shared ADB server or unrelated emulator. Dedicated test AVD is DroidBridge_API35 on port 5580. User's emulator-5554 must remain untouched.

Pin client/server protocol to scrcpy 5.0.1. Test with actual emulator and deterministic test app. Record executed commands and outputs under verification/. Do not mark acceptance passed on compilation or assertions alone. Physical Pixel 10 Pro verification is deferred to the owner.

Build: swift build. Unit tests: swift test. Release: scripts/package.sh. Independent QA may reject milestones until executable evidence exists. Final artifact must be copied outside build directory and run there. No push, public upload, production actions, or notarization claims without authorization and credentials.
