# DroidBridge beta privacy

Updated November 3, 2026. This notice describes the current release source. A
future trial, licensing or payment service needs an updated notice before use.

DroidBridge runs Android applications on your Android device and displays their
video on your Mac. Video and input travel over your authorized ADB connection.
The optional Android companion communicates directly with paired Macs using
authenticated, pinned TLS. DroidBridge does not operate a cloud relay for these
connections.

## Data on your devices

The Mac stores settings, device/application identifiers, generated Mac wrappers,
session recovery records, companion trust and received items locally. Pairing
credentials use the Mac Keychain. Diagnostic logs can contain device identifiers,
application names, paths and connection errors. Review logs before sharing them.
Saved files remain at the destination you choose.

The Android companion stores its pairing identity, trusted Macs, settings,
transfer state and saved library on your phone. Sharing clipboard text, files or
links requires an explicit action. Notification forwarding requires Android's
notification access permission and configured forwarding settings. Camera access
on the Mac is for the QR pairing action you invoke. ADB debugging authorization
is a separate Android permission.

## External services

Release lookup and download controls contact GitHub. GitHub receives ordinary
request information such as your IP address. Opening a link contacts its site.
The public Android release excludes the internal development diagnostic tools.
The current release has no DroidBridge account, payment or online trial service.

## Your controls

You can stop sessions, disable optional companion features, forget pairings and
revoke Android permissions. Forget both ends of a pairing when retiring it.
Revoking companion trust does not revoke Android USB or wireless debugging
authorization. See [BUILD.md](BUILD.md#uninstall) for removal of the Mac's owned
background services, wrappers and stored data. Uninstall the companion using
Android App info. User-saved files outside the app's storage remain.

Use [SUPPORT.md](SUPPORT.md) for help. Public GitHub issues are public: do not post
pairing codes, QR images, credentials, personal content or unreviewed logs.
