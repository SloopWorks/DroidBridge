# DroidBridge 0.2.0 public beta — release draft

**Draft awaiting release acceptance and owner approval.** Do not publish this
text or its download links until they describe the exact accepted artifacts.
The build number and beta access terms must be filled in before publication.

DroidBridge brings apps running on your Android device into separate windows on
your Mac. Connect an authorized device, choose an app, and launch it using the
native AppKit renderer or the scrcpy fallback. Android continues to run the app
and enforce its permissions and capture restrictions.

The beta includes independent Mac app launchers with Android icons, explicit
session restoration, device-wide audio routing and an optional Android companion
for approved pairing, phone controls and deliberate text/file/link handoff.
It does not require a DroidBridge cloud account or relay your screen through a
DroidBridge server.

## Requirements and setup

- Apple Silicon Mac with macOS 26 or later.
- Android 13 or later, with debugging enabled and this Mac authorized. The
  optional companion is installed from DroidBridge and paired separately.
- Download the reviewed DMG from the official release, copy DroidBridge to
  Applications, then launch it. Do not recommend disabling Gatekeeper or removing
  quarantine to complete installation.

Only publish a Developer ID/notarization statement after the exact downloaded
artifact passes signature, stapling and Gatekeeper checks. Include the final
version/build and SHA-256 checksum beside the download.

## Before upgrading

Quit the main app, generated Android app launchers and audio hosts. Replace the
main application, open it once and let managed launcher maintenance finish.
Update manually created launchers with Create / Update Mac App. Keep your saved
files and settings; do not delete application support data as an update step.

Moving from an ad-hoc development build can require explicit Forget/re-pair if
the old Keychain trust is inaccessible. Report the verified migration behavior
for this candidate here before publication. Same-signer companion updates use
Android's normal update path; uninstalling or clearing data changes its identity.

## Beta limitations

Apps can refuse capture, playback capture or secondary displays. Protected
content can appear black. Text composition has Android input limitations. Audio
is device-wide; it is not isolated per Android app and does not forward your
microphone or calls. Hover-only tooltips are unavailable.

Physical Pixel, USB/Wi-Fi, sleep/wake, audio audibility and thermal checks remain
pending owner verification. Generated-launcher Spotlight/Dock behavior, native
notification banners and final fallback pointer interaction retain the specific
open checks in KNOWN_ISSUES.md. Do not turn emulator tests into claims that these
hardware or macOS integration checks passed.

There is currently no automatic updater, trial timer or paid activation flow.
Insert the approved beta access and future pricing wording here. Do not advertise
the proposed 14-day trial or paid license as available until implemented.

## Help and included materials

Report ordinary bugs through GitHub Issues with your platform, app version/build,
backend and reproduction steps. Review logs before sharing; never post a pairing
QR/link, credentials or personal device content. PRIVACY.md, SUPPORT.md and
SECURITY.md describe data handling and reporting. BUILD.md includes removal of
the app's owned background services and saved state.

The final release must include the matching corresponding-source archive,
third-party notices and checksums. A source download link alone does not close
the exact-source and license review gate.
