# Clean app names — 0.1.3 build 7

The visible SHA suffix was part of managed wrapper filenames. Spotlight imports
that filename, so changing only CFBundleDisplayName cannot fix the result.
Unique apps now use `App Name.app`; genuine same-device name collisions use a
readable package qualifier. Device/package bundle identities remain unchanged.

The installed main app automatically repaired all 16 genuine 0.1.2 build 6
wrappers in 74.006 seconds, without an attached phone. It first upgraded their
copied code at the original hashed paths, then changed names only after every
incompatible reader was gone. The original availability helper was replaced
before the first clean filename was published. Old main applications must be
quit before installing the update; concurrent old writers are unsupported.

## Executed evidence

| Check | Result | Evidence |
|---|---|---|
| Full unit suite | 90 tests, 4 explicit hardware skips, 0 failures | `unit-final.log` |
| Independent naming regressions | 17 passed: collisions, Unicode, reservations, foreign paths, old-reader barriers, missing/running rows, delayed LS effects | `../../Tests/DroidBridgeCoreTests/ManagedAppNamingQATests.swift` |
| Genuine old wrappers → new installed GUI | All 16 repaired; phase ordering observed | `before.json`, `phase1-catalog.json`, `after.json`, `migration.log`, `migration-result.json` |
| Exact copied executable, signatures, icons, launch options, IDs, original backups | All 16 independently checked against retained original generations and current installed executable | `migration-result.json` |
| Actual Spotlight metadata/index | All 16 current exact public URLs found globally, no SHA suffix in display names | `launch-result.json` |
| Real clean-name Settings wrapper | Decoded native frame and visible-window receipt; graceful exit 0; original display/forward/reverse baseline restored | `launch-result.json`, `launch.log`, session JSONL |
| Installed runtime audit | Strict signatures, 23 Mach-O dependency trees, isolated-PATH tools/helper | `package.json` |

The first migration harness completed the real migration but its final assertion
incorrectly demanded unique plain filenames for two test apps that genuinely
share the label `DroidBridge Test`. The original failure remains in
`migration.log`. A separate final validator checked the legitimate readable
disambiguator and all 16 retained original bundles, config/icon equality,
unsigned code payloads and strict signatures; its result is
`migration-result.json`. The reusable harness assertion was corrected.

The installed main executable SHA-256 is
`e7544a05c60e4a4d6953a908e363536b1515188d79fbc6111ff637b1cb4116c9`.
Installer checksums are in `SHA256SUMS`. This is an ad-hoc signed local artifact;
no Developer ID, notarization, physical Pixel or unlocked Cmd+Tab/focus result is
claimed. This report covers the name-fix candidate; the subsequent phone-screen
feature has its own version and verification evidence.
