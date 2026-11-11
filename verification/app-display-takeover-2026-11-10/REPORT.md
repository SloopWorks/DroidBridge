# Android task moved out of the Mac window — November 10, 2026

Reproduced with installed build 23 and fixed in the local ad-hoc signed build 24. The existing installation and its running sessions were left in place. [Artifact fingerprint](artifact.json).

## Reproduction and cause

On `DroidBridge_API35` (`emulator-5580`), open `dev.droidbridge.testapp7` from DroidBridge, then run:

```sh
adb -s emulator-5580 shell am start -W --display 0 \
  -a android.intent.action.MAIN -c android.intent.category.LAUNCHER \
  -n dev.droidbridge.testapp7/.MainActivity
```

Android reused the existing task and moved it to display 0. The Mac window and stream survived and still reported Running, although the app had left their virtual display. The same command without `--display 0` left the task on the virtual display in this fixture. This is consistent with [Android's activity launch policy](https://source.android.com/docs/core/display/multi_display/activity-launch). See [the baseline output](baseline.log), [commands](baseline/reproduce.py), and per-backend activity snapshots.

## Fix

Both backends track the task on their own display. They require two matching observations of the same task on another display, with no instance of the app remaining on the owned display. A separate instance on the phone, an unreadable probe, and static video do not trigger it. On a confirmed move, DroidBridge ends its empty stream and presents **Move to Mac**. It leaves the task on the phone until the user chooses the action, which opens the app on a new virtual display without force-stopping the package. Native keeps the same Mac window.

## Executed checks

| Check | Result |
| --- | --- |
| Installed build 23, native and fallback | Tasks 1475 and 1478 moved to display 0 while the respective Mac streams still reported Running. |
| Build 24, native | Actual button click returned task 1481 from display 0 to display 5; decoded app video returned in Mac window 17232. [Result](native/result.json). |
| Build 24, fallback | Actual button clicks returned tasks 1486 and 1491 to displays 7 and 9, respectively. The second run remained active for 20 seconds after return. Computer control captured the resumed Player with the test app drawing on display 9. [Result](scrcpy-visual/result.json). |
| No automatic move | Both backends left the task on display 0 and ADB stayed connected through the observation window. An untargeted launch did not trigger the action. |
| Swift tests | `swift test`: 368 tests, four skips, zero failures. After tightening initial sampling and the quit guard, `swift test --filter 'AppDisplayWatchTests\|ConnectionRecoveryTests\|NativeStartupExitTests'`: nine passed. |
| Packaged artifact | `scripts/package.sh` succeeded with scrcpy 5.0.1; `codesign --verify --deep --strict` passed. The shipping wrapper factory produced unique disposable bundles from the external package, which were then executed for the tests. |
| Cleanup | No session forwards, scrcpy servers, or virtual displays remained on the test AVD. Disposable wrappers were unregistered and removed and only `emulator-5580` was stopped. Shared ADB PID 34809 was preserved. [Cleanup](cleanup.json). |

The final package command was `scripts/package.sh` with `DROIDBRIDGE_BUILD_NUMBER=24`, `DROIDBRIDGE_SIGNING_MODE=adhoc`, `DROIDBRIDGE_COMPANION_APK` pointing to the existing local release APK, `ADB_PATH` pointing to `.build/adb-runtime/adb`, and `DROIDBRIDGE_OUTPUT_DIR` set to `~/Library/Application Support/DroidBridge/ReviewBuilds/app-display-takeover-24`. The first package attempt stopped because a source file changed during compilation; [the next run](package.log) succeeded. The runtime driver was `python3 scripts/verify-app-display-move.py <disposable-wrapper.app> --backend <native|scrcpy> --output <evidence-dir>`; the final fallback run added `--observe-seconds 20`. Exact app launch commands and dumps are retained beside each result.

The verified behavior is for an actual task move, not every possible cause of blank video. Android can recreate app state on other devices or apps. The owner's physical Pixel, Developer ID signing, and notarization were not exercised.
