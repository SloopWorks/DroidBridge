# Mac delivery and offline notices candidate

Status: Android implementation verified on owned API35; full C14 delivery is
**not accepted** until the exact public versioned installer is downloadable and
its checksum/signing/platform fields match the installed release artifact.

- Signed release0.2.0/versionCode3, APK SHA-256
  `1eaa35f03e47a2f119d8ea699a7cd7fa314ca08cc3a541d779c98dbc8b777c27`.
  Exact source/artifact hashes: `notices-api35-artifact.json`; signer verification:
  `notices-release-certificates.txt`.
- `notices-api35-instrumentation.txt`: **19 actual installed tests pass**,
  including TLS/server security, phone UI, strict delivery metadata and offline
  license viewer. This is not a Mac interoperability claim.
- `notices-api35-large-text.txt`: **four actual UI/license tests pass** at320dp
  width /200% text. `notices-api35-restored.txt` verifies font1.0 and density420
  restored, with no override. Physical Pixel/user emulator were untouched.
- `delivery-api35-ui/`: the earlier signed delivery candidate made an explicit
  HTTPS lookup of the unpublished official version. Actual Settings showed the
  unavailable explanation; both download/copy controls remained disabled. It did
  not download or execute an installer. This proves the unavailable path only.
- Three current Core metadata tests pass (`../release-metadata-tests.log`),
  including exact version/platform/URL/signing/hash policy, duplicate escaped
  keys, nested values, malformed UTF-8 and byte abuse.

The first notice extraction caught a filename-case mismatch on case-insensitive
APFS: the existing license file is named `Apache-2.0.txt`. APK ZIP paths are case
sensitive. The viewer/packager now use that exact name; successful extraction and
installed license-view tests followed. Failed extraction was not counted as a
passing packaging check. The frozen Mac QA build2 APK was never overwritten.

The initial API35 code3 installation replaced an owned debug-signed fixture
because its signer differed; this is explicitly not an update-continuity pass.
The notices candidate subsequently updated that API35 installation with the same
release signer. API37 signed version1→2 continuity is separate prior TLS evidence.

Release lookup is user initiated and contains no phone identifiers, trust or
content. It uses HTTPS/system trust with bounded approved-host redirects, bytes
and deadlines. Metadata binds the fixed versioned GitHub DMG and release URLs;
no arbitrary URL is executable. Copy/open actions are explicit. Android cannot
install or approve Mac software. No ad-hoc build is described as notarized.

The APK retains Apache2.0 and upstream ZXing/Kotlin notices plus IntelliJ
annotations attribution, available offline in Settings. The exact release
runtime dependency report is `release-runtime-dependencies.txt`. Mac packaging
extracts notices from the bundled APK, and package verification compares them
byte-for-byte. Source URLs and exact notice hashes are in the APK's SOURCES.json.
