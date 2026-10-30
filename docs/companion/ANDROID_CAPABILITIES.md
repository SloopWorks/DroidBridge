# Android companion capabilities and authority

The companion is a normal Android 13+ application (`dev.droidbridge.companion`).
It complements the existing authorized ADB/scrcpy runtime; it cannot create trusted
virtual displays, inject arbitrary input, power the phone display or bypass secure
capture policy by virtue of being installed. AOSP restricts the app-streaming role
to privileged preinstalled applications: [AOSP app streaming](https://source.android.com/docs/core/permissions/app-streaming).

## Native implementation

`AndroidCompanion/` contains a Kotlin Android application, a visible connected-device
foreground service and a TLS 1.2/1.3 HTTP server bound exclusively to
`127.0.0.1:37841`. Its non-exportable Keystore P-256 key signs an installation-stable
server-auth certificate with digital-signature usage and a loopback IP SAN. The
Mac pins its exact DER fingerprint from the complete pairing link before sending
request bytes; another ordinary Android app owning the port cannot impersonate it.
USB and Android's paired wireless debugging use explicit ADB forwarding. There is
no plaintext LAN listener. The user starts/stops the service; it does not start at
boot. Android posting permission is requested separately from pairing. The service
declares connected-device prerequisites, including CHANGE_NETWORK_STATE; it does
not change network configuration. [Foreground service types](https://developer.android.com/develop/background-work/services/fgs/service-types)

The launcher catalog uses MAIN/LAUNCHER intent queries declared in the manifest,
without QUERY_ALL_PACKAGES. It groups aliases by package and renders each selected
launcher drawable to a 128-pixel PNG. This includes adaptive/vector icons and
excludes background-only packages. A package-change receiver refreshes the bounded
snapshot while the service runs. Work profiles, suspended/hidden applications and
OEM-specific launchers require separate physical-device checks. [Package visibility](https://developer.android.com/training/package-visibility/declaring)

The phone dashboard offers app export choices, Open on Mac, stop-session requests,
audio destination, and profiles. Those are authenticated requests to the Mac's
existing device/session authority, not local shell execution. The Mac supplies
session metadata; no screenshots or Android application text enter that snapshot.

The phone QR/manual link conveys an installation-stable AndroidKeyStore P256
server certificate fingerprint before the Mac sends any HTTP or credentials.
Plaintext, pinless trust and silent certificate replacement fail closed.
Pairing is explicit, expires after 120 seconds, and requires phone confirmation of
the named Mac. Random per-Mac credentials are encrypted using a non-exportable
Android Keystore AES-GCM key. Revocation applies on every new request and before
file publication. App backup is disabled. Pairing secrets, credentials and shared
content must never appear in logs or process arguments.

Text/clipboard sending is deliberate and foreground-only. Receiving text presents
a Copy action; receipt never silently replaces Android's clipboard. Android SEND
and SEND_MULTIPLE content URIs are opened only after confirmation, copied with
fixed buffers into private staging and exposed through opaque transfer UUIDs.
Incoming files stay private until the user chooses Save via Android's document UI.
Nothing is automatically opened, executed or extracted.

Notification sharing is separately opt-in and uses Android's user-granted
NotificationListenerService access. Replies use only a currently advertised
free-form RemoteInput action. There is no accessibility service, root request,
microphone, contacts, SMS, location or broad storage permission.

## Build and verification boundaries

Run `AndroidCompanion/build.sh assembleDebug assembleDebugAndroidTest testDebugUnitTest`.
The Gradle wrapper pins 8.14.3; AGP is 8.13.2, Kotlin 2.3.21, compile/target SDK35,
minimum SDK33, JDK17. Release signing accepts a persistent private local distribution identity created
by prepare-local-signing.py; it is separate from the debug key and must not be
presented as Play Store production signing. Runtime emulator evidence
is recorded by the coordinated verification owner, not inferred from compilation.
Physical Pixel checks remain the final owner acceptance stage.
