# Fallback IME verification

Run `scripts/verify-hidden-ime-fallback.py` only after obtaining exclusive device
and shared Mac preference/session ownership. The driver starts the installed
DroidBridge executable with `--wrapper --launch dev.droidbridge.testapp --serial
<dedicated emulator> --backend scrcpy` and verifies host/Player bytes before and
after. A test proxy appends only `--record`; production-generated arguments are
captured separately and compared to the actual client arguments.

The public Cocoa fixture could not establish input delivery on this host. Those
failed attempts remain under `api35/` and `api35-cocoa-direct/`; they are not
successful acceptance evidence. The approved `--input-method sdl` alternative
feeds public SDL input events in the unchanged client, on its main thread. A
public SDL wait-function interposition keeps that event queue responsive. This
proves the client input path, not physical OS focus while the desktop is locked.

`api35-sdl-health-retry/` establishes an actual Android 15 system-server crash
at the first click. Its crash buffer reports InputDispatcher `addPointers`
overlap with NavigationBar2, and measured system-server PID changes 6954→9550.
Earlier binder exceptions alone would not establish a system-server restart.
The `api35-sdl-queuepump*` setup failures are retained as test-fixture failures,
not Android/product evidence.

`api35-no-hover-control/` is a diagnostic control using the same installed
host a725fcaa… and unchanged Player d2e9b47b…, with the sole behavioral proxy
addition `--no-mouse-hover`. Both decorations settings pass text, raw K, clipboard
paste, repeated clicks, panel ON/OFF and resized editing; 24 scoped IME samples
pass. Real recorded frame hashes change, system-server PID remains 9550, and
crash output is empty. Its report deliberately sets `acceptance: false`: a final
installed candidate must emit that API 35 flag itself and pass without a proxy
policy override. The supported default driver asserts absence of the flag on
other Android versions, including API 37.

Every run restores exact shared preference/session bytes and own saved geometry,
checks display/tunnel baselines, and compares five Android keyboard/power settings.
Clipboard flavors stay in memory and are restored only while the fixture still
owns that pasteboard generation; a newer external copy is never overwritten.
IME checks use QA's independent display/window-state oracle. Samples are explicit
and are not described as mathematical proof of continuous invisibility.

## Final installed acceptance

Both `final-api35/result.json` and `final-api37/result.json` pass with
`acceptance: true` against installed host SHA-256
`13ea19c4226f25a132beab2e3ead81d87391ea2c3a46377afc50e374e8cd0c75`.
The proxy adds only recording; no diagnostic policy override is used.

| Check | Android 15 / API 35 | Android 17 / API 37 |
|---|---|---|
| Production no-hover workaround | Present | Absent |
| Decorations | On and off | On and off |
| Editing phases | Panel on, panel off, resized while off | Panel on, panel off, resized while off |
| Input receipts | New counter click, text, raw K, CmdV paste | New counter click, text, raw K, CmdV paste |
| Independent hidden-IME samples | 24 pass | 24 pass |
| System-server PID | 9550 unchanged | 682 unchanged |
| Crash buffer | Empty | Empty |
| Host and Player hashes | Unchanged | Unchanged |
| Preferences, intents, clipboard and settings | Restored/unchanged | Restored/unchanged |
| Displays and tunnels | Exact baseline | Exact baseline |

Each case includes real recorded frame PNGs with distinct hashes. The separate
Cocoa/Metal cached-view PNGs are black on this host and are **not** visual
acceptance evidence. Use the recorded frames, rendering receipts, input logs and
raw Android display/window snapshots. QA independently replays those snapshots.
