# Device app onboarding and display controls

## User behavior

The default-enabled bulk-wrapper flag exposes an explicit onboarding button. No mass icon extraction or wrapper generation happens at startup. The button captures one authorized, ready device and its launchable application catalog, then creates independently launchable Mac applications with Android-rendered icons. Progress, cancellation and per-app failures remain visible. Completed applications survive cancellation; another run resumes safely. Existing matching DroidBridge wrappers are migrated only after their ownership and device identity are verified; unrelated and running applications are preserved.

Managed apps are published under `~/Applications/DroidBridge Apps/Devices/<device hash>`. Device identity is part of their bundle identity, so two devices cannot overwrite each other's wrappers. Each copied wrapper remains a real signed application with its own process and Android icon. Spotlight and Cmd+Tab behavior require observed evidence, separately from bundle metadata.

When a device is unavailable, managed bundles move into the private `ManagedApps.noindex` store and are unregistered. A stale Spotlight result is also protected by a launch admission check. Unauthorized, offline, failed and not-yet-booted devices are unavailable. Reconnection restores bundles and registration. Turning the feature off stops new bulk admission and hides managed apps without deleting accepted history.

## Ownership and concurrency

`ManagedAppCatalog` is a Foundation-only durable catalog. Short cross-process file locks fence reservations, committed generations, availability transitions and registration receipts. Lock acquisition has a finite deadline and honors cancellation. Wrapper construction, signing, Android queries and Launch Services processes happen outside the catalog lock. A newer generation supersedes stale registration actions. Completion rechecks the desired effect in both directions, retaining compensation for delayed register or unregister effects. Duplicate effects consistent with current policy are idempotent.

The durable cohort policy denies launches immediately, including rows not yet visited by a bounded 64-record transition wave. Bundle moves and action acknowledgements are journaled and batched. A read cache is valid only under the same lock with an exact file inode/size/modification/change-time fence; another process's atomic replacement invalidates it. Only exact validated owned paths may move, and full root ancestry is checked before mutation. Complete previous generations remain recoverable in the private store.

The GUI coordinator owns a captured cohort, at most two workers, cancellation and progress. It never silently retargets a cohort when the device picker changes. Android icon extraction retains its existing bounded requests and exact remote cleanup receipts. Per-app extraction or capacity failures are reported rather than producing empty or generic successful wrappers.

The wrapper factory uses copy-on-write cloning where supported, preserving independent signed bundles while avoiding one full physical runtime allocation per app. It does not share writable hard-linked code or introduce external runtime symlinks. A non-cloning fallback must check capacity and report refusal. Signing and strict verification complete before publication. Running applications cannot be replaced.

## Availability helper

First explicit onboarding installs an owned per-user LaunchAgent and a stable local helper/runtime. The helper uses the same Core catalog and shared preferences as the GUI and wrappers. It performs bounded, finite ADB readiness probes with retry/backoff and reconciles visibility while the main application is closed. It never kills the shared ADB server or another application's processes. Registration actions run outside the catalog lock and are acknowledged under the corresponding generation fence. Feature-off mode does no Android polling. No network service receives app catalogs, video or input.

Uninstall instructions must remove the exact agent label/plist and helper support directory. Helper generations bind both binary and ADB digests. Up to eight immutable generations are retained; reaching the cap refuses a further installation rather than deleting a possibly mapped executable. Reinstall using the documented scoped uninstall when that limit is reached. Logs rotate at 1 MiB with one retained previous file. Ad-hoc signing remains the distribution boundary; no Developer ID or notarization claim is made.

## Android display setting

The shared setting controls system decorations on newly created virtual displays. It defaults to showing decorations for compatibility; old persisted session configurations decode to that value. Backend A uses scrcpy 5.0.1's supported `--no-vd-system-decorations` flag when hiding decorations. Backend B sends the matching pinned server option. This is local to the session's virtual display and does not change phone developer settings or global System UI.

The option concerns Android's display decorations and launcher surface. Application-drawn navigation, action bars, keyboard and protected content remain Android/application behavior. Both values, both backends, real frame updates, input, resize and cleanup must be tested on the dedicated emulator before claiming support.

## Verification gates

Required evidence includes catalog crash/race/ownership tests, bounded work and cancellation tests, real Android catalog/icon creation, online/offline/reconnected Spotlight metadata queries, stale-launch rejection, helper operation after GUI quit, strict signatures, clone/capacity measurements, installed-bundle launch, and independent expert review. Locked-desktop GUI interactions and physical Pixel checks must remain explicitly unverified unless actually executed. Evidence belongs under `verification/onboarding/` and `verification/desktop-mode/`.
