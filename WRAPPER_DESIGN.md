# Android application wrappers and icons

## Problem and evidence

A Pixel 10 Pro owner reported that the ChatGPT wrapper started a virtual display,
then disappeared. The supplied server log stops after application launch and
contains a failed attempt to remove an ADB forward. That cleanup message does
not establish the initiating failure: the original implementation has two
independent cleanup owners, and successful emulator sessions contain the same
message when the second owner removes an already absent forward.

The matching structured log later proved a decoded frame after two seconds and
103 seconds running before a single clean stop pair. The owner saw no window,
did not disconnect, and can launch ChatGPT from the main DroidBridge launcher.
The original wrapper only raises the native window before asynchronous startup;
it does not reactivate it at video readiness. A lost activation can thus hide a
working session behind other applications. The update raises and activates the
native wrapper at first decoded frame and focuses it when the app is reopened.
The exact historical foreground state and stop caller were not recorded, so that
physical failure cannot be reconstructed conclusively from the old logs.

The original wrapper also treats an unsolicited clean session exit as permission
to quit its Mac application. A clean child exit can therefore remove the only
visible diagnostic UI. Explicit window close and unexpected transport termination
must have different outcomes. A Pixel-specific task or codec defect must not be
inferred from the cleanup message. New presentation and stop-reason events make
future window hiding, explicit close, app quit and device loss distinguishable.

## Launch and failure policy

Each generated wrapper remains a separate regular AppKit application with a
package-specific bundle identifier and its own executable, runtime, launch
configuration and persistence store. It owns its own native session windows.
Only explicit user close/quit ends the wrapper automatically. Unexpected session
exit or launch failure retains visible diagnostics and offers a fresh retry or
the scrcpy fallback. Retries create a new fenced session rather than reviving a
terminal session. Cleanup targets exact owned resources and treats a verified
absent forward as complete.

## Android icon source

An original, small DEX helper runs with the existing authorized ADB shell identity.
It resolves the MAIN/LAUNCHER activity using Android's PackageManager and loads
that activity or alias's drawable (with a Leanback fallback for TV apps). Android renders the drawable to a 512-pixel PNG,
including adaptive and vector resources. No APK resource guessing, application
installation, root access or external network service is involved. Temporary JAR
and PNG paths are unique per operation, bounded and cleaned up after success or
failure. The installed Mac application contains the helper; the Android SDK is
needed to build it, not to use it.

## macOS icon and application identity

Wrapper creation obtains the PNG asynchronously and generates an ICNS containing
the sizes required by macOS. The bundle declares that icon, and the running
NSApplication uses it as its application icon. Finder, Dock and the application
switcher can therefore use the Android application's image rather than the
DroidBridge host's generic icon. A separate bundle identity and process are
necessary: changing the image of one window in the main launcher would still
leave all of its windows grouped under DroidBridge.

The fallback's copied Player bundle receives the same Android icon/name and a
package-specific child bundle identifier. Its host becomes an accessory while
the Player owns the live window, avoiding a duplicate switcher entry. A terminal
failure restores the host's regular application policy and diagnostics.

Launcher rows request icons lazily with two active extractions, a 64-request
queue and a 128-entry cache. Device changes prune stale queued work. Termination
cancels and awaits owned icon and wrapper-creation tasks so their scoped cleanup
finishes before the application exits.

Before pushing an icon helper, the provider atomically records its PID, serial
and random request identity. Finite recovery before device discovery skips live
owners and exact active producer commands, then removes only the two derived
temporary paths for abandoned requests on connected devices. Later device polls
retry retained requests after a producer finishes or the device reconnects.
The recovery pass has a total time budget and rotates its capped receipt batch.
Shutdown cancels and awaits this tracked refresh work. This also covers a crash
between staging and cleanup; it never removes a global filename prefix or another
live wrapper's work.

Creation stages and signs a complete bundle before publication. Updating an
existing matching DroidBridge wrapper preserves its launch settings and keeps a
recoverable backup; an unrelated application must never be overwritten. Missing
or invalid Android icon data is reported rather than silently presenting a
generic icon as a successful extraction.

## Verification boundaries

Tests must exercise the shipping provider and wrapper creator, compare Android
icon output with the generated bundle image, launch independently signed bundles,
observe distinct regular NSRunningApplication identities and icons, and verify
real Android video and cleanup. Failure tests must retain the wrapper after a
backend exit and verify explicit close still terminates it. Actual Dock or
Cmd+Tab interaction requires an unlocked Mac and must be distinguished from
programmatic application identity and icon checks. Physical ChatGPT behavior is
not certified by an emulator fixture.
