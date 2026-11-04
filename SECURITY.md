# Security reporting

Use GitHub's private vulnerability reporting option on the repository's Security
page if available. If it is unavailable, open an issue requesting a private
contact without including exploit details, personal data or credentials. Do not
post pairing QR images, full pairing links, private keys or device content.

Include the affected version/build, platform, reproduction steps and the scope
of access required in a private report. Beta support has no guaranteed response
time.

Companion pairing and Android debugging authorization are separate trust grants.
Revoke each independently when retiring a device or Mac. Do not expose ADB over
an untrusted network.

A checksum detects changed bytes; it does not establish publisher identity.
Developer ID and notarization claims apply only to the exact artifact whose
signature, Apple notarization ticket and Gatekeeper assessment were verified.
Ad-hoc development artifacts are not notarized releases.
