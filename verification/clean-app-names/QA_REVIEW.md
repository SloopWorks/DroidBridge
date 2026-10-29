# Independent clean-name QA review

**Approved:** installed DroidBridge 0.1.3 build 7 for the clean-wrapper-name fix. This approval does not cover the subsequent screen-power feature.

Installed main executable SHA256: `e7544a05c60e4a4d6953a908e363536b1515188d79fbc6111ff637b1cb4116c9`.

The actual 16-wrapper cohort migrated automatically from genuine 0.1.2 build 6 bundles in 74.006 seconds without an attached test phone. Unique labels now use names such as `Settings.app`. The two apps sharing the Android label DroidBridge Test correctly produce `DroidBridge Test.app` and `DroidBridge Test (dev.droidbridge.testapp2).app`. Device/package bundle identities remain unchanged.

## Independent execution and inspection

- Added and executed 17 naming regressions in `Tests/DroidBridgeCoreTests/ManagedAppNamingQATests.swift`; all passed. Cases cover readable collisions, canonical Unicode/case equivalence, accent-distinct names, device namespaces, foreign paths, reservation release, live/dead legacy producers, absent and deleted-but-running apps, saved assets, offline migration and old-path effect races.
- Inspected the final full-suite result: 90 tests, 4 explicit integration skips, 0 failures (`unit-final.log`). The four skips are not presented as live test passes.
- Independently read original backups, phase1 backups and current bundles for every accepted record. Compared normalized unsigned executables against genuine old-release payload `66aaf1532b06aa791f3507a730a256e03c350cf58067871204d9e305a8782322` and the installed new payload `172cd0b22a5b8c316f4e82e9da025aa8e4d0f881f2f9ee1118d1ace8b68d2762`. All 16 original backups contain the old payload; all 16 phase1 backups and final bundles contain the new payload.
- Independently compared every original/final Android PNG byte hash, launch dictionary excluding the necessarily new `managed_generation`, name/backend and bundle ID. All match. Every final bundle passes `codesign --verify --deep --strict`; every final Info.plist declares build 7 and naming capability 2. Original generations remain in validated private backups.
- Inspected `phase1-catalog.json` and the migration samples: all old readers reached capability 2 while names remained hashed; clean names first appeared only afterwards. The runtime harness asserted that the old availability helper was replaced before the first clean name. The resulting helper reports 0.1.3.
- Inspected `launch-result.json`: all 16 exact managed identities resolve in Spotlight to clean paths, including the one legitimate package qualifier. Actual migrated `Settings.app` decoded a native frame and emitted a visible-window receipt. Normal quit restored the display/forward/reverse baseline.
- `git diff --check` passed.

These checks validate real installed migration and actual renamed-wrapper launch, in addition to Foundation catalog fixtures. They do not rely on compilation alone or on an agent's success assertion.

## Failure interpretation

`migration.log` retains an initial harness assertion that incorrectly required every filename to equal the Android label plus `.app`. It failed on the legitimate same-label collision. Migration had already completed; the separate final validator and this independent audit verify the actual output and preserved bytes. This is an instrumentation failure, not a failed application migration.

The earlier `unit.log` contains a synthetic-cohort fixture failure: filenames used Batch labels while the fixture's record/launch names still used Example. Those fixture names were made coherent with the new filename binding. Production ownership validation was not weakened; the final90-test run passes.

## Compatibility and limits

The two-stage upgrade is necessary because old 0.1.2 readers validate the whole catalog. The implementation upgrades the actual wrapper code before publishing clean filenames, preserves exact old-path lineage for late registration effects, and refuses foreign replacement bytes. Missing old bundles may retain accepted history without blocking healthy entries; deleted-but-running old readers still close the compatibility barrier.

Quit older DroidBridge main-app versions before using the updated host. An old concurrently running host can attempt to reinstall its old availability helper; simultaneous old/new writer operation is outside this verified upgrade workflow. Running old managed apps are deferred until they quit, rather than forcibly replaced.

The Mac desktop remains locked. The observed renamed native window is `visible=true` with `app_active=false` and `key=false`. Direct OS focus, Finder/Dock clicks and Cmd+Tab interaction remain unverified. Physical Pixel testing remains external. Strict ad-hoc signature verification is not Developer ID signing or notarization.
