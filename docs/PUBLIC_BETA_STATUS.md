# Public beta candidate status

November 3, 2026. This is a local preparation ledger, not publication approval.
The candidate has not been uploaded or notarized. Earlier product evidence is
retained separately; it does not automatically accept changed artifacts.

## Implemented and checked

- Developer ID packaging lane with explicit identity/team, hardened runtime,
  timestamping, separate signed ADB provenance, notarization/stapling and
  Gatekeeper checks. Missing credentials fail before packaging. Positive signing
  and notarization remain pending.
- Versioned signed-release metadata validation in the producer, Mac and Android
  consumers. Metadata is a report; the OS must verify the actual downloaded app.
- Release source commit captured before building and embedded before signing;
  changed-source, changed-revision and wrong-source-archive claims are refused.
- Public Android builds can exclude private development distribution tooling.
  Existing internal build behavior remains separately available.
- Android release versionCode 13, with its existing release signer retained.
- Privacy, support and security reporting documents bundled by the package recipe.

## Executed evidence

Evidence root: [verification/public-beta-2026-11-03](../verification/public-beta-2026-11-03/).

| Check | Result | Scope |
|---|---|---|
| Full Swift suite | 340 tests, 4 skipped, 0 failures | Source/unit regression |
| Signing/source refusal tests | 4 passed | Actual ad-hoc code refused as Developer ID; missing credential and modified/untracked source refusal |
| Distribution security suite | 7 passed | Manifest/source boundary regressions, including a real signed app with a conflicting source-commit claim |
| Android public release compile/unit build | Passed | Release excludes private distribution plugin |
| Android internal regression | Passed | Debug/test compilation with existing local internal dependencies |
| Installed release delivery tests | 4 passed on emulator-5580 | Signed APK parser and offline license viewer |
| Mac build 17 ad-hoc package | Passed | App, nested code, portable ADB, DMG and ZIP; no notarization claim |
| Installed Mac build 17 | Passed | Copied outside build directory; real approved pairing, pinned TLS catalog and native decoded Android content; physical input focus not verified |
| Android dependency resolution with fresh Gradle user home | Passed | Public release configuration downloaded/resolved without private distribution repository; existing project task outputs reused |
| Dependency source collection | 16 exact formula/version inputs verified | Source inputs staged; final source archive/review pending |
| Apple organization membership | Verified live, correct team | Account Holder inspected under organization account |
| Developer ID Application identity | Installed and matched; operational check unresolved | Public certificate moved to local ReleaseSigning folder, matching private key imported into login Keychain; certificate trust passes, but codesign probes time out with and without timestamping |

Installed build-17, fresh-cache Android and final signed-candidate results must be
read from their individual logs. Do not infer a pass from a running command.

## Still required before publication

1. Verify actual Developer ID signing with the installed identity; owner arranges
   an encrypted recovery copy. Configure notarization credentials without reusing
   the reported exposed key. Confirm that old key's revocation independently.
   Read-back identifies the missing `apple:` key partition. An owner-run targeted
   authorization command is prepared in the local ReleaseSigning folder; the
   attempted unattended update was stopped and confirmed unchanged.
2. Freeze and commit the reviewed source candidate, preserving concurrent work.
   Produce the exact signed/notarized app, DMG, ZIP, manifest and source archive.
3. Run the installed signed runtime and generated-wrapper trust/migration tests
   under default macOS security. Complete the advertised input/audio/helper
   upgrade behaviors with executable evidence. Physical Pixel checks remain
   owner work.
4. Review corresponding-source completeness and original-code distribution
   terms. Source collection alone does not establish redistribution compliance.
5. Approve beta terms, limitations, release notes and the exact upload cohort.
   After authorized publication, verify real unauthenticated downloads and a
   fresh installed copy with normal download provenance.

## Commercial boundary

The current code has no trial clock, paid activation, purchase flow or automatic
updater. The proposed 14-day trial, one-time paid license and pricing in the
product review are recommendations. They must not be advertised as available.
A technical beta and a broad paid launch have different readiness requirements;
shipping a beta must not silently create a promise of free lifetime access.

[Beta release notes](BETA_RELEASE_NOTES.md) are drafted for review, with unresolved
access terms, acceptance statements and limitations explicitly marked.

The [signing and upgrade plan](SIGNING_AND_UPGRADE_PLAN.md) retains the paid-state,
Sparkle and full acceptance work. Choose and approve beta access terms before
publication. No merchant account, cloud service subscription or production
resource was created during this preparation.
