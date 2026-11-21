Connection runtime checks, 2026-11-21

Commands executed from repository root:
- `swift build --target DroidBridgeAvailability` — passed; helper-build.txt.
- `swift test --filter QuickOpenTests` — 3 tests passed; unit-tests.txt, final-tests.txt.

Tests cover exact saved-device selection, authorized/ready connection edges, no repeat on readiness flaps, disconnect/unauthorized rearm, atomic preference writes, identity validation and missing host rejection. This is fixture evidence; actual installed-app/device connect acceptance is a separate QA gate. Helper opens only the exact saved owned desktop bundle and skips an exact already-running desktop instance. Preferences are rechecked after awaits immediately before Launch Services handoff.

The helper was then split into two independent sequential workers: automatic connection observation every 1 second after completion, and the unchanged managed-catalog publication cadence. Both workers are canceled and awaited at shutdown; log rotation/appends are serialized. This prevents long registration cycles from delaying connection observation. The final pre-open preference equality check remains after all readiness/NSWorkspace awaits.
