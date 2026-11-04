# SloopWorks integration evidence — 2026-10-30

Implemented using actual SWIP0.1.12 + swip-debug0.1.1 and
DebugDrawer/core+SWIP adapter0.1.1 sources. `source-artifacts.json` binds the
source revisions/dirty state and exact staged artifact hashes. Private remote
Maven reads returned401; local source compatibility is not publication proof.

Passing evidence:

- `droidbridge-schema-check.log`: canonical SWIP registry/schema check.
- `droidbridge-swip-contract-tests.log`: three strict contract/privacy tests.
- `contract-missing-source-refusal.log`: generated snapshot check fails closed
  on unavailable canonical source instead of reporting a vacuous success.
- `droidbridge-stage-*.log`, `droidbridge-prepare-sloopworks.log`: actual library
  Android/root publication into an isolated ignored local Maven repository.
- `droidbridge-diagnostics-insets-build.log`: `.dev` app/test assembly.
- `diagnostics-device-test.log`: two actual emulator5580 tests pass, including
  typed SWIP event consent/purge and real-touch library Drawer/SWIP UI.
- `diagnostics-screen.png`, `diagnostics-swip-inspector.png`: visually inspected
  final real UI; debug bubble clears system navigation and inspector renders.
- `droidbridge-release-runtime.log`, `release-diagnostic-boundary.json`: no
  collector/inspector/dev source identity in release runtime/APK DEX. The latter
  binds the final product APK SHA
  `b6277fb903e99bb46e9bb93553de12cda6094f8d00b1abf4b700794a11254abd`.
- `droidbridge-deploy-inspect.json`: signed development APK package/signature,
  marker, independent build instance UUID and canonical provenance digest.

Operational refusal:

- `droidbridge-deploy-onboard.json`: trusted authenticated development server is
  healthy, but project droidbridge is absent and the saved publisher token
  cannot perform admin project creation. No published build/channel or device
  installation is claimed. No alternate unrelated project or token bypass used.

No physical Pixel or emulator5554 operation occurred. The normal release package
and its test APK were preserved; diagnostics used side-by-side `.dev` packages
and never started a loopback service. Provider authorities use resolved test IDs
so these packages can coexist.

External onward delivery is now verified by `share-onward-device-test.log`:
one opt-in installed test passes after touching the real Share onward control,
selecting the separate fixture in Android's system Sharesheet, and reading exact
137-byte PNG/SHA-256 in UID10159. A prior direct string-URI probe in that same
ordinary UID receives SecurityException without a URI grant. Final screenshots
were visually inspected (`share-onward-without-grant.png`,
`share-onward-sharesheet.png`, `share-onward-external-read.png`); JSON records the
byte identity, and `share-onward-artifact-bindings.json` binds the product, test,
and fixture APKs. The helper settles actual window focus and reads real OS bounds;
there are no guessed coordinates or provider/export relaxations.

The final readonly Deploy recheck is `deploy-doctor-final.json` (healthy trusted
dev server) plus `deploy-status-final.json` (project still absent, HTTP404).
No credentials, package registration, channel policy or enrollment was changed.

Fresh development candidate rebuilt from the final Android sources:
`dist/companion-improvements/DroidBridge-Companion-Development.apk`, SHA-256
`d73d3754dcd91b0c15715c0c2599bc9e9600e3bdcaf904929ad93163aa276f6e`.
`development-current-build.log` records 41 executed tasks; the source-input receipt
binds 51 current source/config files that remained unchanged through the build.
All 32 staged Sloopworks artifact hashes and source revisions matched their
receipt, and generated DroidBridge contracts matched the canonical source.
`development-final-inspect.json` validates the `.dev` development identity,
metadata, marker and canonical provenance; `development-final-signature.log`
independently verifies APK v2 signing. `development-final-artifact.json` records
the separate APK, build-instance, provenance and signer identities. The signer
is the existing per-developer Android Debug certificate; shared development
signer provisioning is not implied. Exact bundled notice checks also pass.

`development-final-test-build.log` records the development instrumentation build,
which regenerated Deploy metadata and superseded the prior `a1721e55...` APK.
`development-pre-instrumentation-artifact.json` retains that earlier identity.
The final copied APK and its separate development test APK were installed on
emulator5580. `development-final-diagnostics-test.log` passes both diagnostics
tests in 2.056 seconds. The final synthetic screenshots were visually inspected.
`development-final-runtime-cohort.json` verifies installed product/test hashes
match the copied final artifacts and release product `b6277fb9...` plus release
test `b1aee0e0...` remain unchanged. No release profile data operations occurred;
neither companion service ran, and the development process was stopped afterwards.

`development-current-doctor.json` remains healthy, while
`development-current-status.json` still refuses with project-not-found HTTP404.
No publication, credentials, project/channel policy or device enrollment changed.

Independent Save/Reveal closure: `finder-saved-file-selection.json` records a
read-only CUA observation of Finder's selected `received-fixture.bin` at the exact
owned system-save QA URL, with one item selected. A direct hash of only that
owned fixture confirms 2,097,152 bytes and the same SHA-256 as the successful
installed-flow result. No file was opened and no Finder/phone/emulator state was
changed by the independent reviewer.
