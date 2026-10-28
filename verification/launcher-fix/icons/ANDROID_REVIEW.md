# Android expert implementation and review

Executed 2026-10-28 against dedicated `DroidBridge_API35` emulator `emulator-5580`, Android 15 / API 35, and newly created isolated `DroidBridge_API37` on `emulator-5582`, Android 17 / API 37. No physical Pixel was attached. Existing emulator-5554 was untouched.

## Launcher icon design

The helper is a DEX JAR, not an installed Android application. It runs through the already-authorized ADB shell using `app_process`, reads Android PackageManager metadata and paints a launcher drawable onto a 512 × 512 ARGB Bitmap. It sends no content to any remote service. Framework bootstrap uses reflected ActivityThread.systemMain/getSystemContext because app_process has no Application Context; this Android internal bootstrap is isolated to the helper, follows scrcpy's system-context approach, and passed Android 15 and Android 17 emulator validation. Physical Pixel remains a separate stage. Drawable resolution/rendering uses public Android APIs.

Icon selection queries MAIN/CATEGORY_LAUNCHER first. Among multiple launcher entries, it prefers the package launch intent component when eligible, otherwise sorts by component identity for a stable choice, and falls back to Leanback only when no standard launcher exists. This deliberately avoids PackageManager.getLaunchIntentForPackage's CATEGORY_INFO preference: an INFO activity can carry a different icon from the phone launcher. ResolveInfo.loadIcon preserves launch activity and activity-alias icon overrides. Android renders adaptive, vector and bitmap resources, including resources from split APKs. This avoids incomplete host-side APK resource parsing. The result reflects the package launcher icon and device's adaptive mask; optional Android launcher's monochrome themed wallpaper tint is not reproduced.

The Swift provider validates package and serial before ADB, uses only argument arrays and generated remote paths, bounds command output/time and PNG byte/dimension limits, checks image dimensions before decoding, and awaits exact temporary JAR/PNG cleanup after success, cancellation or errors. Failure remains visible; no silent DroidBridge-icon substitution.

## Executable evidence

Commands:

```sh
scripts/build-icon-helper.sh
android/icon-helper/fixture/build.sh
DROIDBRIDGE_TEST_SERIAL=emulator-5580 DROIDBRIDGE_TEST_ICONS=1 swift test --filter AndroidIconProviderTests
```

`tests.log` (API 35) and `api37-tests.log` (API 37): each 3 tests, 0 failures, including actual Settings and fixture icons, unavailable-package failure, cleanup, hostile input rejection and malformed/dimension limits.

`settings.png`: actual Settings AdaptiveIconDrawable rendered by Android (91,577 bytes).

`alias.png`: actual fixture launcher-alias adaptive icon with vector foreground (4,188 bytes). The application's own vector icon and a separate CATEGORY_INFO alias are blue; the launcher-alias icon is purple/yellow. The test confirms the INFO alias resolves independently. The live test decodes and asserts the yellow center pixel, proving the activity alias icon was used rather than the application icon. Visually inspected the PNG and confirmed purple rounded adaptive mask with yellow plus.

Manual helper output:

```
DROIDBRIDGE_ICON_OK com.android.settings.Settings android.graphics.drawable.AdaptiveIconDrawable
DROIDBRIDGE_ICON_OK dev.droidbridge.iconfixture.LauncherAlias android.graphics.drawable.AdaptiveIconDrawable
```

A post-test `find /data/local/tmp -maxdepth 1 -name 'droidbridge-icon-*'` returned no files. No root or installed production helper was required; only the explicit test fixture APK was installed on the dedicated emulator.

## ChatGPT launch review

The supplied `adb: error: listener ... not found` is emitted while removing an already-missing forward during shutdown, after virtual display and package launch. It is a cleanup diagnostic, not evidence that Android denied ChatGPT launch. The preceding log proves server/device recognition, encoder selection, display creation and launch request, but does not prove task placement or video delivery.

Pinned scrcpy adds NEW_TASK and launchDisplayId to the resolved package launch intent. Android singleTask/task affinity, app-controlled activity transitions, secure surfaces, app crashes and device-specific secondary-display policy can affect the result. The user's ChatGPT APK/manifest and Pixel were unavailable, so no ChatGPT-specific restriction is established. Do not default to force-stop: it would terminate the user's phone-side ChatGPT task and lose state without proving the issue. The shared native startup/lifecycle fix and retained diagnostics must be tested independently of that hypothesis.

Primary references:

- https://developer.android.com/reference/android/content/pm/ResolveInfo#loadIcon(android.content.pm.PackageManager)
- https://developer.android.com/reference/android/graphics/drawable/AdaptiveIconDrawable
- https://developer.android.com/reference/android/content/pm/PackageManager#getLaunchIntentForPackage(java.lang.String)
- https://developer.android.com/develop/ui/compose/layouts/adaptive/support-multi-window-mode
- Local pinned upstream `Vendor/scrcpy/server/src/main/java/com/genymobile/scrcpy/device/Device.java` and `Workarounds.java` (5.0.1).

## Remaining platform coverage

API 35 and API 37 (Android 17) emulator extraction passed using the same helper. Physical Pixel icon and ChatGPT launch remain untested locally; the shell Context bootstrap is an explicit compatibility boundary now exercised on both Android releases. Root agent owns installed wrapper/ICNS/Launch Services tests and final acceptance evidence. Cmd+Tab interaction requires an unlocked macOS desktop; process/bundle identities alone must not be described as an observed switcher action.

## macOS icon conversion cross-review

Inspected the new MacAppWrapper.swift and main.swift. The 512px square Android PNG retains alpha through RGBA CGContext scaling; the 16, 32, 128, 256 and 512 point iconset at 1×/2× provides standard ICNS representations. The 1024px representation is an upscale of the 512px Android render, not extra source detail. CFBundleIconFile points at AndroidApp.icns and the wrapper sets NSApp.applicationIconImage from it. Unique bundle IDs and regular activation policy provide independent application identity; real Cmd+Tab automation remains distinct from this code review. Root and macOS expert coordinate predecode bounds hardening and installed-wrapper evidence. No additional icon conversion blocker found.
