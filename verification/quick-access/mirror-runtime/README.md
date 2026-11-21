Mirror runtime checks, 2026-11-21

Executed from repository root:
- `swift build --target DroidBridgeStreaming` — passed; streaming-build.txt.
- `swift test --filter HiddenIMEArgumentTests/testMirrorSpawnCapturesPrimaryDisplayWithoutAppOrPhonePolicyChanges` — 1 passed; spawn-test.txt.
- `swift test --filter DesktopConfigurationTests` — 3 passed; configuration-tests.txt.

These fixtures exercise real session subprocess admission and capture native/fallback arguments but do not supply native decoded video. Actual emulator screen/video and input acceptance remain separate QA gates. Pinned source confirms primary-display IME-policy CLI rejection, so mirror intentionally omits virtual-display IME and keep-active settings.
