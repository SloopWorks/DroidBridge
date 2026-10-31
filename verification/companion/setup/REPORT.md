# Native setup component checks

Executed 2026-10-30 with Swift 6.2.3 on macOS 26.2, Apple Silicon.

`swift build` passed with no warnings from the setup components.

`swift test --filter 'Companion(QRImageReader|SetupValidation|WirelessADB)Tests'`
passed seven tests, zero failures, in 0.684 seconds:

- A real generated QR PNG was decoded by production Vision/ImageIO code and its
  URI validated for secret, device identity and expiry.
- A real non-QR PNG and an input larger than 20 MiB were rejected.
- QR parsing rejected expired, overly distant, duplicate, malformed, network-
  bearing and invalid-identity payloads.
- Wireless setup validation rejected option, shell, hostname, URL and invalid
  port/address inputs; numeric IPv4 and bracketed IPv6 were accepted.
- An executable fake ADB process verified the six-digit code arrives on stdin,
  exactly two command arguments are present, and echoed code is redacted.
- Real hanging child processes were stopped on timeout and cancellation within
  the test's bounded duration.

These are component and process tests. They are not evidence of camera capture,
successful real Android wireless pairing, companion trust, a connected phone,
complete GUI navigation or installed application acceptance. Those remain
end-to-end program gates. No physical device, ADB server or emulator was changed.
