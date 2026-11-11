# Wireless ADB without typing — November 11, 2026

The existing Mac flow asks users to copy two different address/port pairs and a short code. Android can instead scan a Mac-generated ADB invitation and authorize it in system Settings. The companion's separate trust remains optional for app windows.

| Route | Decision |
| --- | --- |
| Android Settings scans a Mac QR | Default. Fresh one-use invitation, exact Bonjour service matching and Android's PAKE exchange. Mac displays it; no Mac camera access. |
| Already authorized USB | Shortcut. Read the selected device's WLAN address and continuity fingerprint over that exact authorized transport, then discover its TLS service. Android still controls whether wireless debugging is enabled and whether the Mac is trusted. If needed, offer QR. |
| Android companion | Explain and open the supported Android settings route. Keep companion approval and wireless debugging independent. Avoid special permissions, a new LAN server, or secret handoff. |
| Codes and IPs | Keep under Manual Setup for a network or device that cannot use Bonjour. Pairing and connection ports are distinct. |

1. Replace the default Mac form with QR, USB assistance, and a saved-phone reconnect action. Start local discovery only for setup or remembered phones, and expose a way to forget a saved phone.
2. Use the GUID from successful ADB pairing as a discovery locator. Bind the first connection to the pairing address and store a fingerprint of the shell-visible Android identity only after connection. For USB, require the fingerprint read from the selected USB transport to match on Wi-Fi. The Android 15 emulator's shell cannot read the internal GUID or TLS port property, so do not require them. Rediscover `_adb-tls-connect._tcp` and verify the fingerprint on the exact ready transport. On rotation, a saved fingerprint allows a small bounded set of live candidates for the same GUID; initial pairing remains strict. Bound retries and cancel owned work. No cloud service, IP scan, cached endpoint replay, global ADB restart, legacy TCP debugging, or automatic Android permission changes.
3. Preserve identity and ownership through reconnect. The fingerprint is continuity for a paired phone, not a cryptographic device pin. Do not retarget an existing session or companion authority to a new address based only on a discovery result. The existing pinned companion protocol remains the authority for cross-transport companion identity. Support explicit app reopening on the recovered transport.
4. Verify QR/cancel/manual/USB presentation, successful Android pairing and connection, reconnect after port rotation, wrong-device rejection, no new network activity without an enrolled phone, and an actual decoded Android app window over the wireless transport. Run the packaged build externally on the dedicated emulator; record limitations of its LAN and camera simulation separately from physical-device acceptance.

Primary references: [Android ADB setup](https://developer.android.com/tools/adb), [AOSP wireless ADB architecture](https://android.googlesource.com/platform/packages/modules/adb/+/HEAD/docs/dev/adb_wifi.md), [Apple local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).
