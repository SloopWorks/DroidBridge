# DroidBridge companion improvements — acceptance map

The requested scope is the complete ten-feature DroidBridge brainstorm, mobile
design and Material UI, actual SWIP and DebugDrawer integration, Shipyard Deploy,
and end-to-end validation. Implementation alone is not acceptance.

| Requirement | Owning implementation | Required evidence |
|---|---|---|
| Connection Quick Settings tile | BridgeTiles, BridgeService | Installed tile state, explicit start/stop, independent stream lifetime |
| Quick actions tile/panel | QuickAccessActivity | Installed audio/screen/session actions and canonical receipts |
| Per-Mac app shortcuts | QuickAccess | Installed pinned launch, revoked/forged trust refusal |
| Recipient/action-aware share | MainActivity, CompanionActions, broker/desktop adapter | Phone share consent to named Mac, send/copy/open exact outcome |
| Faster action delivery | Broker persisted-command wake hint, desktop adapter | Actual command latency observations and missed-wakeup fallback |
| Notification controls | BridgeService | Installed notification state/actions/progress |
| Saved clipboard snippets | CompanionLibrary, MainActivity | UI search/pin/copy/delete, encrypted persistence, limits |
| Transfer improvements | BridgeTransfers, TransferProvider, MainActivity, CompanionTransfers | Verified thumbnails, grouped batch, granted share onward, Finder reveal, interrupted receipt recovery |
| Desktop presets | CompanionLibrary, broker, desktop adapter | Explicit named Mac review; profile/audio before bounded launches; honest partial receipt; no uncertain replay |
| Home widget | BridgeWidget | Actual installed widget state/actions, historical timestamps |
| Material mobile design | MainActivity/resources, QuickAccessActivity | Rendered screenshots, small screen/font/keyboard/accessibility checks |
| SWIP | Generated DroidBridge schema, CompanionDiagnostics | Schema validation and actual typed categorical events with consent |
| DebugDrawer | Debug source set | Actual inspector UI, opt-in/purge, absent release collectors |
| Shipyard Deploy | Development-only Gradle plugin/config | Exact signed development APK inspect, authorized dev publication/download |
| Distributed system boundaries | Existing pinned TLS/ADB, receipts and owner fencing | Swift suite, Android security tests, installed Mac+Android flow |
| Deliverable artifacts | Signed Android APK + packaged Mac application | Exact hashes, verified install outside build directory |

Runtime device: dedicated `DroidBridge_API35` on `emulator-5580` only. Existing
unrelated devices, especially `emulator-5554`, remain untouched. Physical Pixel
verification remains an explicit owner-only hardware acceptance boundary.

Publication constraint observed during this run: the saved development Deploy
login reaches the trusted dev server but cannot provision the missing DroidBridge
project. This is pending authorized provisioning; it is not a successful upload.

Final results and remaining limitations belong in REPORT.md after executing the
checks. Historical evidence elsewhere is not evidence for these new bytes.
