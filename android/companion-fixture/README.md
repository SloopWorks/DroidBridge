# Companion boundary verification fixture

Original test-only Android application, package `dev.droidbridge.companionfixture`.
It is not bundled into the shipping Mac app or companion APK.

Build without installing: `scripts/build-companion-fixture.sh`.
Install only on explicitly owned `emulator-5580` or `emulator-5582`; never use an
unqualified ADB installation command. The build output is under `.build/`.

The native activity provides:

- Public reply-capable, public non-reply and private notifications. Replacing a
  notification retains its Android notification ID but must invalidate the old
  companion action identity. The private notification must not reach the Mac.
- A real `RemoteInput` broadcast receiver. The activity shows the received text
  and cumulative deliveries; one user reply must create exactly one fixture
  delivery. Test strings are logged only by this test fixture.
- Explicit ACTION_SEND shares to the companion: text, HTTPS URL, PNG, a 2 MiB
  binary stream and an intentionally slow binary stream for cancellation.
- A continuously changing Choreographer-driven frame probe for real frame-rate
  and session input checks. Tap changes its frame counter by 1,000.

The binary fixture repeats a 65,536-byte chunk whose byte at offset `i` is
`i % 251`, 32 times. Generate the same bytes on the Mac and compare SHA-256 after
receiving. The content provider grants only read access to the exact shared URI;
pipe writers close on cancellation. The generated image is a genuine 128×128
PNG, not a file extension standing in for an image.

Tests must separately establish Android notification posting permission, the
companion notification-listener grant, companion global opt-in and the selected
Mac's package allowlist. Seeing a permission button or notification row does not
prove a reply or transfer. Record receiver identity and terminal receipts while
excluding pairing secrets, credentials and unrelated user data from evidence.
