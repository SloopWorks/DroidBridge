# Screen-power QA plan — not yet executed

Contract supplied by the lead: opt-in physical-screen-off intent is a per-device serial set, initially empty. It applies while Mac sessions run. Explicit ON clears the intent and requests primary display 0 ON; OFF/checkbox records intent and requests primary display 0 OFF when appropriate. Closing the final session does not automatically wake the phone. Both virtual-display backends use verified `keep_active=true` and `power_on=false`. Product code uses supported Android display commands, without power-key toggles, root or global stay-awake-setting changes. Phone lock/PIN policy remains intact.

## Deterministic regression gates

1. Old preference JSON decodes an empty set; serial validation, bounded persistence and concurrent preference merges preserve unrelated fields. Existing session/restore/backend settings remain pinned.
2. Record actual primary display 0 state before/after a command. Missing/ambiguous output is unknown, never coerced to ON/OFF. Unsupported command/API, unauthorized transport, timeout and disconnect produce actionable diagnostics without failing the Android video session.
3. Hold the exact per-device actuation mutex. Admission is bounded and cancellation terminal; different serials proceed independently. No catalog lock is held across ADB work.
4. Delay OFF before and during command execution, then request ON. Fresh preference checks after mutex acquisition prevent stale OFF; a queued successful ON wins against an earlier in-flight OFF. Test the reverse sequence too: a newer OFF must not be overwritten by stale ON.
5. A failed/busy ON must retain an explicit retry path even though it clears the OFF intent. Test application shutdown while waiting, lost transport and later retry; do not silently claim the display changed.
6. Only the selected authorized serial and physical display 0 are addressed. No virtual-display IDs, shared ADB server termination, shell injection, `KEYCODE_POWER` substitution or global setting writes occur.

## Real emulator integration

Reserve only dedicated 5580/API35 and 5582/API37; preserve user5554. Capture scoped power/display dumps and exact commands.

- For each backend, launch a deterministic changing app. Enable intent: primary display 0 becomes OFF while its virtual display stays active, decoded frames continue changing and click/keyboard input still changes the correct app.
- Resize after OFF; confirm geometry/input mapping and continued frames. Start a second app, then close each in both orders. The remaining stream stays live and neither close wakes primary display 0; final close retains the explicit OFF intent.
- Mix native/fallback wrappers and independent processes on one device. Repeat explicit ON/OFF races through separate processes and require final power state to match the latest successful intent.
- Test two devices simultaneously; switching the selected device or closing another device's wrapper must not alter the first device's state/intent.
- Quit/relaunch the host and a copied wrapper; reconnect/reboot the dedicated emulator. Persisted OFF intent is reapplied when eligible, and failed attempts are visibly retryable. Sessions continue through power-command failure.
- Compare relevant Android settings before/after to prove no stay-awake/global mutation. Snapshot resources and ensure exact session forwards/displays/processes are cleaned; intentional physical OFF persistence is not misreported as a resource leak.

## Installed GUI and physical handoff

Use the final installed artifact for public AppKit checkbox/menu target/actions and capture its hash. Verify checkbox state follows the selected device and explicit ON clears persisted intent. Label test instrumentation separately from physical OS clicks under the locked Mac desktop.

The owner’s Pixel check must confirm actual panel behavior, continued independent Mac app interaction, explicit ON, lock/PIN preservation and disconnection/reconnection. Emulator display dumps cannot prove physical panel brightness or hardware-specific power behavior. No screen-power acceptance claim is made until executable evidence exists.
