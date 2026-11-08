# Executed diagnostics

Working directory: `/Users/patrick/workspace/DroidBridge`.

All ADB invocations use `dist/DroidBridge.app/Contents/Resources/Runtime/bin/adb` and argument arrays via Python subprocess where filtering/capture was needed. No server restart or device mutation was invoked.

| Command / inspection | Output |
| --- | --- |
| `git status --short --branch` | `main...origin/main`; two unrelated pre-existing untracked naming-review JSON files preserved; this incident directory subsequently added. |
| `rg` / `sed` / `nl` over Launcher, BridgeSession, SocketTransport, DeviceReadiness, PhoneDisplayPower, ARCHITECTURE | Relevant source locations and conclusions in REPORT.md. |
| Read/copy today's `~/Library/Logs/DroidBridge/session-*` files | Original per-session `.log` and `.log.jsonl` copies in this directory; `timeline.json` extracts today's categorical lifecycle events. |
| `ps -axo pid,ppid,etime,command` filtered for DroidBridge and shared ADB | `processes.txt`. |
| SHA-256 of installed and dist `Contents/MacOS/DroidBridge` | Identical hashes recorded in REPORT.md. |
| `adb devices -l` (twice) | `adb-devices.txt`: Pixel authorized on USB, transport_id 63. |
| `adb -s 57091FDCH01331 logcat -d -v threadtime -t 12000` | Initial console inspection, output truncated; superseded by targeted capture below. Broad log not retained. |
| `adb -s 57091FDCH01331 logcat -d -v threadtime -t 20000 adbd:V UsbDeviceManager:V UsbPortManager:V UsbDeviceManager-JNI:V scrcpy:V CCodec:W Codec2Client:W MediaCodec:W DisplayPowerController:V PowerManagerService:V '*:S'` | `android-transport.log`. |
| `adb -s 57091FDCH01331 shell dumpsys power` | `power.txt`; after owner wake, categorical lines in `after-owner-unlock-power.txt`. |
| `adb -s 57091FDCH01331 shell dumpsys display` | `display.txt`. |
| `adb -s 57091FDCH01331 shell dumpsys usb` | `usb.txt`. |
| `/usr/bin/log show --style compact --start '2026-11-07 09:33:50' --end '2026-11-07 09:36:25' --predicate '(process == "kernel" OR process == "usbd" OR process == "powerd") AND (eventMessage CONTAINS[c] "USB" OR eventMessage CONTAINS[c] "57091" OR eventMessage CONTAINS[c] "sleep")'` | `macos-usb.log`, exit 0. |
| Filter availability JSONL for incident UTC minute window | `availability-window.json`: no matching events; not used as evidence of availability. |

No build/unit tests were run because this investigation changes no executable source. Existing compilation or emulator tests would not prove the cause of a physical USB interruption.
