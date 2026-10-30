# Independent hidden-IME acceptance

No device result is claimed yet. QA has not been granted device ownership.

- Test both production backends on Android15/API35 and Android17/API37, with two distinct application/display identities.
- Verify exact production client/server argv requests display IME hide for every session, including restored/reconnected sessions. A literal source edit is unit evidence only.
- At editing start, repeated text/raw-key input, physical panel ON/OFF, and post-resize, collect current `dumpsys window displays`, `dumpsys window windows`, `dumpsys input_method`, and app receipt logs. Display IDs must come from exact session/package launch receipts.
- Require explicit IME InsetsSource visible=false for each tested virtual display, no IME surface/presentation attached there, and the expected visible app window. Missing/ambiguous fields fail closed. Global mInputShown alone is insufficient; input_method history is not current state.
- Require actual typed text and raw-key suffix on the correct display, repeated after panel-off and resize. Native NSEvents/control messages or public SDL events must pass through unmodified production paths. ADB input is diagnostic only and cannot substitute for Mac-client delivery.
- Sample during a finite editing interval, not just before/after it. Keep all offending snapshots; do not retry away an observed keyboard flash. Screenshots/live changing frames supplement Android window evidence.
- Use the same LOCAL policy as a positive control when practical, showing the oracle detects an IME that appears. Prefer a test application explicitly requesting soft input to changing a global Android setting.
- Preserve phone-side keyboard configuration and global/secure settings byte-for-byte. Do not toggle show_ime_with_hard_keyboard or replace the default IME. Scoped virtual-display policy must not disable unrelated device input.
- Close/relaunch and reconnect once with fresh IDs; ensure policy is not lost after virtual display recreation. Restore actual phone panel state and exact owned forward/reverse/display baselines. Never touch emulator5554.

`scripts/verify-hidden-ime-state.py` is a read-only snapshot checker. Its passing output deliberately says it does not alone prove continuous absence or keyboard delivery. Parser unit fixtures may be synthetic; acceptance snapshots and input receipts must come from actual Android sessions.

API limitations must be explicit. Upstream scrcpy ignores hide on Android29/30; never describe those unverified versions as satisfying an absolute guarantee. The supported/tested Android15/17 display policy, app-drawn keyboards and OS software IME must remain distinguished.
