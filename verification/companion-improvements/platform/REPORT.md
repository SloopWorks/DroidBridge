# Android platform acceptance

Target: dedicated DroidBridge_API35, emulator-5580 only. Release app and test APK
were updated in place using the repository's persistent local signing identity;
no existing application data, trust, unrelated ADB authorization or emulator was
removed. Physical Pixel verification is not covered.

Implemented entry points: connection tile, operations tile, per-trust pinned app
shortcut, favorites/status widget, richer foreground notification, selected-text
sharing and foreground clipboard preview. See
[QUICK_ACCESS.md](../../../docs/companion/QUICK_ACCESS.md).

## Executed checks

- `:app:assembleRelease :app:assembleReleaseAndroidTest :app:testReleaseUnitTest`
  passed (`../platform-candidate-build.log`). `QuickAccessStateTest`: 2 tests,
  zero failures/errors/skips.
- Final installed `QuickAccessDeviceTest` plus settled `PlatformWidgetDeviceTest`:
  5 tests passed in 7.842 seconds (`final-quick-widget-tests.log`). Quick Access
  covers actual selected-text preview/consent, exact-trust receipt admission,
  unknown-outcome display without automatic successor, forged/revoked shortcut
  refusal, installed manifest protections, and a retained native confirmation
  callback after its Activity was destroyed. The destroyed review cannot submit
  an effect or reach its closed executor. The initial 3-test pass is retained in
  `quick-access-tests.log`.
- Final frozen-artifact `PlatformPinnedShortcutDeviceTest` with
  `interactive_platform=true`: 1 test passed in 21.579 seconds
  (`pinned-shortcut-final-test.log`). The actual Launcher3 Add to Home screen
  dialog was approved; the actual home icon was tapped; its opened Activity
  carried the exact trust/package; no remote effect was admitted. Final launcher
  screenshots: `pin-final-dialog.png` and `pin-final-launcher.png`. The opened
  Activity identity is asserted directly by the installed test; `pin-final-open.png`
  can contain its launch transition rather than a settled rendering. The settled
  same-handler view is shown in `widget-action-open.png`. The fixture trust was
  revoked and only the owned Bridge acceptance home item was removed using
  Launcher's actual Remove drop target (`pin-final-cleaned.xml`). The initial
  17.445-second pin cohort is retained in `pinned-shortcut-test.log`.
- Actual SystemUI tiles were added using `cmd statusbar add-tile`, and activated
  using `cmd statusbar click-tile`. SystemUI bound the real TileServices.
  Connection tap started a real foreground BridgeService (`services-enabled.txt`,
  including Android's tile-onclick foreground-start exemption), operations tap
  opened QuickAccessActivity (`operations-tile-open.png`), and the next connection
  tap stopped BridgeService (`services-disabled.txt`). The tile showed Waiting
  for Mac rather than claiming authentication from listener availability alone.
  Final icon screenshot: `tile-panel.png`. The tile set was restored exactly
  (`tiles-before.txt` equals `tiles-after.txt`).
- The real ongoing notification appeared in SystemUI with Quick actions,
  Transfers and Disconnect actions (`notification-panel.png/.xml`). Tapping the
  actual Transfers action opened Sharing (`notification-transfers-open.png/.xml`).
- A real test AppWidgetHost allocated/bound the production BridgeWidget provider
  through AppWidgetManager and received its RemoteViews. The final test rendered
  Settings on Mac for Widget acceptance Mac, injected a real touch at the
  observed OS node bounds, and verified the opened QuickAccessActivity carried
  the exact trust/package without submitting a command. Settled images were
  inspected: `widget-host.png` and `widget-action-open.png`. The owned bindings,
  temporary bind grant, fixture trust and favorite preference were restored.
- Real widget/notification platform tests passed 2 tests in 7.28 seconds
  (`strong-platform-final-tests.log`). The notification test staged 1 of 4 known
  bytes through the actual transfer ledger, verified the real foreground
  notification reported 250/1000 progress with private visibility and three
  activity actions, then touched the actual SystemUI Transfers action and
  verified Sharing opened. `transfer-progress-notification.png` shows the real
  25% bar and action. No constructed notification or widget stood in for the
  installed platform paths.
- Fresh-process `CompanionReceiptDeviceTest`: 3 tests passed in 33.184 seconds
  (`receipt-final-tests.log`), covering unknown preset step-count availability,
  unconfirmed audio output, real 30-second expiry and no automatic replay.
- Four selected real-TLS `CompanionSecurityTest` nodes plus
  `CompanionStagingDeadlineTest`: 5 tests passed in 62.84 seconds
  (`security-staging-final-tests.log`). These cover transfer hash/order/trust/path
  constraints, restart/resume/cancel, durable scoped terminal command receipts,
  exact-Mac peer/export scope, and the actual production 30-second stalled-read
  deadline and capacity recovery. `prepareUpgradeBaseline` was not run.

The real tile gesture/notification/host evidence was gathered with:

```sh
adb -s emulator-5580 shell cmd statusbar add-tile dev.droidbridge.companion/.ConnectionTileService
adb -s emulator-5580 shell cmd statusbar add-tile dev.droidbridge.companion/.OperationsTileService
adb -s emulator-5580 shell cmd statusbar expand-settings
adb -s emulator-5580 shell cmd statusbar click-tile dev.droidbridge.companion/.ConnectionTileService
adb -s emulator-5580 shell cmd statusbar click-tile dev.droidbridge.companion/.OperationsTileService
adb -s emulator-5580 shell appwidget grantbind --package dev.droidbridge.companion.test --user 0
adb -s emulator-5580 shell am start -n dev.droidbridge.companion.test/dev.droidbridge.companion.PlatformWidgetHostActivity --es target_package dev.droidbridge.companion
adb -s emulator-5580 shell appwidget revokebind --package dev.droidbridge.companion.test --user 0
adb -s emulator-5580 shell cmd statusbar remove-tile dev.droidbridge.companion/.ConnectionTileService
adb -s emulator-5580 shell cmd statusbar remove-tile dev.droidbridge.companion/.OperationsTileService
```

SystemUI interactions used observed accessibility bounds, with screenshots and
hierarchy dumps retained. No unrelated tile, widget or home item was removed.

## Cohorts and remaining limits

The final product APK is `b6277fb903e99bb46e9bb93553de12cda6094f8d00b1abf4b700794a11254abd`.
The final copied test APK is `b1aee0e064a7f73072278362470554d2ff748a1bed3e10bc5373cb678c4f0d23`.
Canonical artifacts and source hashes are recorded in
[`../artifact-manifest.json`](../artifact-manifest.json), synchronized with
`dist/companion-improvements/manifest.json`. The final source includes volatile
listener publication across service teardown and terminal/foreground review
fencing; no visual polish followed this correctness freeze.

The first combined proof attempts are retained in
`widget-notification-tests-first-failure.log` and
`final-platform-receipts-tests.log`. They exposed native accessibility text
search stopping at RemoteViews root namespaces and fixture admissions exceeding
the existing five-pairings-per-minute producer limit. The final harness walks
bounded actual OS child nodes, settles captures after real content appears, and
runs receipt admission in a fresh instrumentation process. No production limit,
permission or acceptance check was relaxed. The first widget screenshots caught
a launch transition; `widget-host.png` and `widget-action-open.png` now show the
settled final surface. `widget-failure.png` remains earlier rendered evidence of
the same product behavior, not a passing harness result.

The actual launcher pin check was repeated against the final frozen product and
test APKs after the lifecycle fixes. The interactive launcher check requires
`-e interactive_platform true` so the default suite does not silently alter a home
screen. All owned home items were removed afterward.

Independent ADB app-video survival after companion-off, authenticated Mac effects,
first-frame latency and physical Pixel checks require their own evidence. The
root integration run owns installed Mac/video checks. These Android platform
checks alone do not prove those external effects or release publication.
