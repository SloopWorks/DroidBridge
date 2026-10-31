# Android TLS checkpoint — frozen integration candidate

This checkpoint is not full-program release acceptance. Root owns packaging and
remaining installed Mac/end-to-end gates; independent Security owns adversarial
listener evidence.

## Artifact

Locally signed Android0.2.0/versionCode2:
`.build/companion-release/DroidBridgeCompanion.apk`

- SHA256 `c304d5d3fc526ebdc7c4c4e16d7c92fb5e53175bfe8f913d3d131fcf097cff04`
- Size2,827,308bytes
- Android signing certificate SHA256 `eb482305a29dfa3c7056f2a8eb6162eff9c123e2de6f85601284ca8967cd98c4`
- Source/artifact binding: `tls-release-manifest.json`
- Build/signature evidence: `tls-release-build.log`, `tls-release-certificate.txt`

The Android signing identity and per-installation TLS identity are separate. The
private release signing material remains outside Git with600 permissions. TLS
private keys remain non-exportable AndroidKeyStore P256 keys.

## Executed evidence

| Gate | Evidence | Result |
|---|---|---|
| API35 proper-leaf TLS1.2/1.3, wrong pin, plaintext rejection, absolute handshake deadline, stable restart pin | tls-api35.txt, tls-api35-negotiation.json |2 tests pass,3.213s |
| Actual production Mac Core URLSession→API35 genuine TLS peer | tls-api35-mac-core.json |Pinned strict SSL hello pass |
| Signed API37 release backend+TLS suite | tls-release-final-api37.txt |13 tests pass,35.486s |
| API37 TLS versions/ciphers/public certificate | tls-api37-negotiation.json, tls-api37-leaf.der |TLS1.2 ECDHE-ECDSA AES128-GCM and TLS1.3 AES128-GCM |
| Actual versionCode1→2 same-signer install-r, distinct process | tls-upgrade-before-api37.txt, tls-upgrade-after-api37.txt, tls-upgrade-api37.json |UUID, DER-leaf pin and changed settings preserved; no uninstall/clear data |
| Actual public-UI service restart and production Core hello after changed-version update | tls-api37-mac-core.json |Pass |
| Ordinary malicious app same-port plaintext/wrong-valid-certificate capture | ../security/peer-attack-api35-current/ |Independent Security evidence; API37 owner running after handoff |

Public DER certificates independently decode to named P256, SHA256-ECDSA, critical
digitalSignature, critical CA=false, serverAuth EKU and IP SAN127.0.0.1. No pairing
secrets or credentials are included in these public certificate/negotiation files.

## Root causes and remediation

The first real Android handshake failed before HTTP. Conscrypt's signing callback
uses NONEwithECDSA over its precomputed transcript digest; the initial key's
SHA256-only authorization produced Android KeyStore INCOMPATIBLE_DIGEST(-13).
The key now authorizes NONE and SHA256 while remaining non-exportable. TLS ciphers,
peer pinning and signature verification were not relaxed. Failed diagnosis is
retained in tls-diagnosis-api35.txt. Only explicitly authorized experimental API35
installations were reset while fixing pre-release certificate generation; product
code never resets an accepted identity as retry.

A default Android KeyGen certificate lacks the explicit serverAuth profile required
by strict Apple SSL policy. The fixed-schema public DER builder uses JCA signing
with the AndroidKeyStore key and validates its signature/key/profile. Public DER
and initializing/ready metadata are atomically persisted with file plus directory
fsync before publication. Ready key/certificate/pin mismatch fails closed. No
production accept-all trust helper, plaintext fallback or silent rotation exists.

The first Mac probe did not start the service because the UI harness mishandled
leaf XML truthiness and uppercase CONTINUE. That service-off attempt is retained
as tls-api35-mac-core-service-not-started.json. Corrected public-UI admission and
genuine production Core TLS succeeded; the failed attempt is not a trust-policy
failure or acceptance evidence.

## Handoff and remaining gates

API35 was explicitly handed to Security, whose current-source four-case attacker
matrix passed. API37 exact signed candidate and public identity were handed to
Security next for its independent four-case matrix, then directly to the macOS
agent. Both services were stopped and owned forwards/temporary UI XML removed
before handoff. Fixture API37 settings clipboard=true/profile=battery were the
changed settings preserved by the update test; no trusted Mac remained after the
backend tests. No physical Pixel or unrelated emulator was operated.

Remaining: installed Mac QR/manual pairing and authenticated reconnection,
accepted-trust Keychain/package-update behavior, final release-source/copy checks,
independent security closure (including crash/unknown-effect and certificate
journal corruption cases), real notifications/replies/filter/revocation fixtures,
transfer/provider/load/perceived-speed gates, final distribution metadata and the
complete program review. Current TLS/unit counts do not prove those broader gates.
No further Android runtime mutation or rebuild is authorized to this agent until
a new allocation.
