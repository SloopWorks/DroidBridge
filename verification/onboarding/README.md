# Onboarding and availability evidence

## Final installed build 6

Installed from the rebuilt DMG at `~/Applications/DroidBridge.app`, version 0.1.2, build 6. Main executable SHA256: `4e2d3ca0666ba43c4199bac1dc9c40a17951b8cd1f23e863c4c12f707731be26`.

- `cohort.log` and `cohort-final-console.log`: all 16 launchable apps on the actual API 35 emulator were upgraded with real Android icons and no errors in 20.52 seconds. Publication was complete when checked. Repeating onboarding skipped all 16 current wrappers in 1.59 seconds. Cancellation stopped admission after 5 of 16 apps, drained admitted work, and another run resumed to 16 current wrappers. Every accepted record was verified against installed build 6.
- `final-agent.json` and `helper-final-console.log`: the copied helper hid all 16 wrappers after disabling the feature in 16.5 seconds. Its disabled cycle reported no ADB probes. SIGTERM finished in 0.006 seconds; launchd restarted the helper with a different PID and parent PID 1. Re-enabling restored all 16 wrappers in 1.65 seconds. The original flag was restored.
- `availability-final.jsonl`: corresponding bounded helper cycle log. The helper executable is byte-identical in builds 5 and 6 (SHA256 `f6b529516819ee843b3547ba668ef2fb018cd07a3749ea2a66fdabb1d86742fd`), so its build 5 lifecycle evidence applies to the exact build 6 helper. Final helper generation: `eaaae983466201f04372c18afbed6f90`.
- `unit-build5.log`: ten focused tests passed, including a real catalog with three queued unregisters and a foreign replacement at the middle path. Both healthy effects were durably acknowledged; the foreign directory was neither dispatched nor removed.
- `cancel-readiness.log`: the shipping launcher, with a delayed readiness response, did not admit onboarding or install an agent after cancellation.
- `launch-race-decorations.log`: the shipping launcher preserved a saved decoration setting when the shared setting differed, and retained disconnected intent after a late cancelled startup.
- `installed-build6-hashes.txt` and `helper-final-resource.txt`: executable identities and helper process observations.

The default preferences, catalog, helper, and emulator 5580 were explicitly handed to independent QA after these tests. No GUI or Android session process from the harness remained. The intended per-user availability agent continued running.

`intent-replacement.log` verifies the final launcher's transaction boundary: explicit Close during delayed readiness cannot resurrect an old intent, task cancellation preserves disconnected intent and retry budget, and cancelled Restore remains durably pending with its original decoration setting. Independent QA's strengthened managed gate tests also cover denied reconnect, Retry, and Restore.

## Earlier candidates

`cohort-baseline.log` records build 3 creating all 16 wrappers with real icons in 22.66 seconds, then skipping all 16 in 0.85 seconds. `feature-disabled.txt`, `disconnected.txt`, and `reconnected.txt` record all 16 wrappers hidden and restored after feature changes and an actual emulator shutdown/restart. Accepted records remained intact. `launch-agent-running.txt` and `helper-survived-parent.txt` show the launchd job surviving the onboarding process and emulator restart.

`cohort-build4.log` records the intermediate build 4 upgrade: 20.41 seconds, zero errors, remaining publication 2.17 seconds, and repeat onboarding in 1.69 seconds. Build 4 was superseded by build 5 to fix independent review's poisoned registration precheck failure.

`build4-agent-test-harness-busy.*` records a failed test harness run. Its status CLI treated the catalog's finite busy refusal as an unhandled Swift error. The application and helper did not crash. The test CLI now reports a retryable busy result; polling retains its original finite deadline. The original shared setting was restored in `finally`.

The existing emulator 5554 and physical Pixel were not touched. Device content is absent from these logs.

`cohort-build5.log` preserves the build 5 update baseline (21.26 seconds, publication 0.70 seconds, repeat 1.48 seconds). Build 6 contains the subsequently reviewed launcher intent-preservation fix.
