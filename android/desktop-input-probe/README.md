# Disposable fallback input probe

Original permission-free diagnostic APK, never bundled in DroidBridge. Build with
`python3 scripts/build-input-probe.py`; output is `.build/desktop-input-probe/`.
It uses its own package `dev.droidbridge.inputprobe` and cannot replace the
companion or Alpha/Beta fixtures. Device installation is a separate explicit QA
step; the builder performs no ADB operations.

The Activity logs at most128 touch dispatch records under
`DroidBridgeInputProbe`: action, coordinates, source/tool/button flags, elapsed
input timestamps, display, touch mode, focused view class, handled state and tap
counter. It never logs text, key codes or clipboard values. Coordinates are read
after child dispatch and may be transformed by Android dispatch; pair them with
actual hierarchy bounds and counter changes. Clipboard controls are inherited
from the deterministic fixture and require explicit taps; avoid them during
mouse-coordinate diagnostics.

See `verification/companion/fallback-input-investigation/REPORT.md` for the
executed unchanged-production cohort and its unproven system-event limitation.
Uninstall the disposable package and close its exact session after use.
