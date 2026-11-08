# Pixel connection incident — 7 November 2026

## Conclusion

The observed failure has three parts: a real interruption of the USB data link terminates running video sessions; DroidBridge's reconnect admission misses short interruptions between device polls; subsequent reconnection attempts can time out with no video when the phone is dozing. The owner confirmed that waking and unlocking the Pixel and clicking Retry restores the app screen.

The cable remaining plugged in and the phone appearing connected afterward are consistent with these observations. The original stream's sockets and Android server do not survive the interruption.

## Executable evidence

Times below are Mac local time, PST; session JSON timestamps are UTC (+8 hours). Android's clock is approximately two seconds ahead of the Mac in this sample; cross-system events should not be treated as millisecond synchronized.

- At **09:34:07.045**, the Mac kernel terminates the Pixel USB device with **`link change interrupt`**. It enumerates the same Pixel again at **09:34:07.880**, at 5 Gbps. See `macos-usb.log`.
- At **09:34:07**, three native Messages sessions transition from running to `transport_failure`, with **zero decoder errors**. Their server/cleanup logs say **`adb: device '57091FDCH01331' not found`**. Session IDs: `F4B56033-ED72-474E-AC47-8C055E0676F1`, `A7A264B7-46B2-40FA-9AF2-277A8C3F31E7`, `71E1770A-6F82-4BA0-BB29-B8B6F496975B`.
- Additional Mac USB detach/re-enumerations occur at **09:35:08**, **09:35:43**, and **09:36:13**. Android's UsbDeviceManager independently records DISCONNECTED → CONNECTED → CONFIGURED transitions. See `android-transport.log` and `usb.txt`.
- The launcher does not mark those failed sessions `device_unavailable` until **09:36:13**, roughly two minutes after the initial transport failure. See `timeline.json` and the per-session JSONL files.
- The phone goes to sleep at **09:34:17 Android time**. Read-only `dumpsys power` reports `mWakefulness=Dozing`; `dumpsys display` reports the scrcpy virtual display **OFF**, despite the device being booted, powered and ADB authorized. See `power.txt`, `display.txt`, and `adb-devices.txt`.
- Later scrcpy 5.0.1 servers create displays and accept the start-app command, but startup fails after 15 seconds with **video packets=0, bytes=0, decoded frames=0, decoder errors=0**. This is absence of encoded video, rather than a VideoToolbox decoding failure.
- Owner check: **wake/unlock the Pixel, click Retry → screen returns**. The newest copied session logs and `after-owner-unlock-power.txt` record the subsequent runtime state. This supports sleep/display power as the secondary startup blocker; it is not a full physical-device release acceptance test.

## Code path responsible for remaining stuck

- `Sources/DroidBridge/Launcher.swift:322`: device polling every four seconds; long refresh work can further delay observations.
- `Sources/DroidBridgeStreaming/BridgeSession.swift:288`: a broken video socket stops the session and transitions it to **failed**.
- `Sources/DroidBridge/Launcher.swift:348`: only a poll that observes the device absent/unauthorized changes the session to **disconnected**.
- `Sources/DroidBridge/Launcher.swift:379`: automatic reconnect considers only **disconnected** sessions. A device that disappears and returns between polls therefore leaves a **failed** session outside reconnect admission. The observed 09:34–09:36 delay matches this path.
- `Sources/DroidBridgeStreaming/BridgeSession.swift:271`: native startup specifies `power_on=false`; readiness in `DeviceReadiness` checks boot completion and package service, without checking whether the virtual display can produce video. After 15 seconds of no frames, the session fails.
- `Sources/DroidBridge/Launcher.swift:563`: every terminal failure receives the same generic “Session ended / Retry or switch backend” text in the video window. The actionable cause is relegated to the launcher and logs.

## Required changes

1. Route unexpected transport termination into a bounded recovery intent, even if device enumeration already shows the phone connected. Preserve the existing three-attempt budget, delay, ownership, cancellation and generation fences. Explicit Close/Quit must remain terminal; configuration, permission and decoder errors must not become blind retry loops.
2. Distinguish a connected but sleeping/no-video device from an unavailable ADB device. Present a clear wake/unlock action and recheck readiness without consuming repeated video launches. Any automatic wake behavior must respect the user's explicit screen-off preference and device-specific behavior; never bypass the lock screen.
3. Display the actual failure category in the affected app window with an accessible Retry action. Suggesting a backend change is not a remedy for an unstable shared USB link.
4. Test a sub-four-second USB interruption and sleep/retry with the deterministic app on the dedicated emulator, followed by owner verification on the Pixel. Keep exact cleanup and close-during-recovery coverage.

## What remains unisolated

The logs establish the USB link interruption, but do **not** identify whether its underlying cause is the cable, connector/port, an intervening accessory, phone USB controller/firmware, or host software. Use a known-good data cable directly to another Mac port and observe the same kernel events to isolate that layer. Do not claim a bad cable from these logs alone.

Chrome and ADB both attempt USB opens during re-enumeration; some opens are refused for exclusive access. This is an observation, not proof that Chrome caused the preceding link changes. Do not kill the shared ADB server as a diagnostic shortcut.

Two identical build-20 GUI copies were running (installed app PID 29113, `dist` app PID 81045). The incident sessions belong to PID 81045. Both binaries have SHA-256 `d0a4207cd7dbf9567d5e6e12004d1bbace97ecc31a1e33bd9c966fd73f530b55`; this is not evidence of an old binary causing the fault. A single main app instance would reduce operator ambiguity, but the evidence does not establish it as this incident's trigger.

## Scope

Read-only runtime diagnosis and source review; evidence files added only. No source fix, app replacement, session/process termination, ADB server restart, emulator modification, signing, push or notarization was performed. The owner's explicit wake/unlock/Retry action is the only recovery experiment. Physical-device production acceptance remains open.
