# DroidBridge beta privacy

Updated November 21, 2026. This notice describes the current release source. A
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

## Optional desktop usage statistics

The standard package has usage reporting disabled. A build with a configured
SloopWorks receiver offers an unchecked **Share usage totals with SloopWorks**
setting in Settings → Integration. An isolated verification build can send to
a receiver on the tester’s Mac. The main app and native Android app windows
share the same choice.

If you opt in, the Mac counts foreground sessions, whole foreground minutes,
and native sessions that presented video. It can send up to one summary per
UTC day. Counts are capped at 8 foreground sessions, 120 minutes and 8 native
sessions per summary. Reports contain those three numbers only. They omit
device, installation, user and session identifiers, Android app names, screen
contents, input and timestamps. A remote network receiver can see the connecting
IP address. No remote receiver is configured in the standard package.

A confirmed withdrawal stops future reporting. Settings shows a retry action
if it cannot confirm the saved choice or clear pending counts.
Counts that have already been combined into weekly totals cannot be located
by individual. The private local usage store retains the day of a send attempt
to enforce the daily limit.

## Your controls

You can stop sessions, disable optional companion features, forget pairings and
revoke Android permissions. Forget both ends of a pairing when retiring it.
Revoking companion trust does not revoke Android USB or wireless debugging
authorization. See [BUILD.md](BUILD.md#uninstall) for removal of the Mac's owned
background services, wrappers and stored data. Uninstall the companion using
Android App info. User-saved files outside the app's storage remain.

Use [SUPPORT.md](SUPPORT.md) for help. Public GitHub issues are public: do not post
pairing codes, QR images, credentials, personal content or unreviewed logs.
