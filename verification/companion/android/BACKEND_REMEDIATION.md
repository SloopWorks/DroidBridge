# Backend remediation checkpoint

Actual API37 execution before the final UX adapter getters: backend-remediation-api37.txt records9 aggregate Android HTTP/security tests,0 failures,5.994s. Tests add encrypted durable phone command/terminal receipt restart, accepted→applied transition, cross-trust ACK denial, scoped peer heartbeat/session/export state, and transfer chunk restart/resume/cancel to the initial six cases.

The later source adds per-trust receipt-bearing export revisions, encrypted received-text UI APIs, cached catalog revision getter, network/unknown battery facts and bounded response-write deadlines. Latest compilation/JVM tests are in backend-remediation-build.log. These later changes require installed runtime revalidation; previous9-test output does not prove them.

The locally signed APK build and certificate are recorded separately in release-build.log/release-certificate.txt/release-artifact.json. A distinct private local signing identity is retained outside Git with600 permissions; it is neither a debug key nor Play App Signing. Debug→release transition requires uninstall/re-pair on the owned AVD only. No physical device was operated.

Remaining release gates include actual notification producer/reply/access-revocation fixtures, slow provider/HTTP/control-load evidence, final installed APK+Mac e2e actions, source/evidence security review, and final APK/source checksum alignment. Root owns coordinated final integration and acceptance.

## Frozen integration candidate

Root accepted the source freeze for integration, not release acceptance.

- APK: `.build/companion-release/DroidBridgeCompanion.apk`
- SHA256: `9900aa674cc84dc955d74c732028d3292cc07b222fe9c12d385fd9a9b7522850`
- Size:2,809,076bytes
- MainActivity SHA256: `7ca54e49a9bd0ff3b23225a7790e0092dc008e23952600455de1469322b9fcc0`
- Signing cert SHA256: `eb482305a29dfa3c7056f2a8eb6162eff9c123e2de6f85601284ca8967cd98c4`
- Full main-source manifest: `release-source-manifest.json`
- Release build:17seconds, signature verified; persistent private key/config both600.
- Installed release validation remains pending; Mac agent owns5582 and may perform
  the explicitly authorized debug uninstall/release install/fresh pairing.
- Android runtime ownership is released. No further device mutation is admitted
  to this Android agent until a new allocation. Physical Pixel/5554 untouched.

The mobile UX agent separately reports six actual API35 public-UI tests against
its exact recorded debug APK: three normal, three320dp/200%font; source hash above
is the frozen UI included in this release. Those UI passes do not prove installed
release signing/update/pairing behavior or the full Mac program.
