# Pixel 10 Pro final physical-device check

Development and automated checks run on the Mac and dedicated emulator. The physical Pixel is the remaining manual hardware acceptance stage.

1. On the Pixel, open Settings → About phone and tap Build number seven times. In System → Developer options, enable USB debugging. Root and wireless debugging are unnecessary.
2. Connect a data-capable USB cable directly to the Mac. Unlock the Pixel and accept the USB debugging RSA prompt after checking that this is your Mac. Revoke old authorizations if the prompt does not appear. A charge-only cable cannot carry ADB.
3. Open the installed DroidBridge application. Refresh devices and select the Pixel; an unauthorized entry must not permit launches. If absent, use its diagnostics to capture ADB discovery output.
4. Select **Native**, search for Settings and launch it. Launch a second app such as Chrome. Confirm two independently movable/minimizable AppKit windows and live changing content. Opening one must not replace the other.
5. Click in each window, drag/scroll, type into a search/text field, test Back, and resize repeatedly. Verify input affects the focused session, including after minimizing/restoring or using Mission Control. Protected video may intentionally remain black.
6. Close both sessions and repeat using **scrcpy**. Verify its live video, mouse, keyboard, dynamic resize, and two-window behavior.
7. While sessions run, use an unrelated app on the phone screen. Confirm which apps remain independent. Android single-task or single-instance apps may move an existing task; record the package and exact behavior.
8. Unplug USB during active sessions. DroidBridge should remain responsive, report a disconnected session, and release local streaming resources. Reconnect, authorize if prompted, and use restoration/relaunch controls. Confirm new sessions work.
9. Quit/relaunch DroidBridge and check saved intent and restoration. Test generated Dock/Spotlight wrappers if available; note that multiple ordinary windows share DroidBridge's Cmd+Tab identity unless a wrapper provides a separate process.
10. If a check fails, save diagnostics from the application and logs in `~/Library/Logs/DroidBridge`. Include macOS/Android build, package, backend, time, cable/connection type, screenshot, and reproduction steps. Avoid sharing private screen content or device serials publicly.

For bulk onboarding, start the explicit device-app onboarding action and allow its progress to complete. Search several apps, including ChatGPT, in Spotlight; launch two and check their Android icons and separate switching identities. Quit the main DroidBridge window, disconnect the Pixel and allow the availability helper to reconcile. Managed apps should disappear from indexed Applications storage; a stale result must refuse to launch. Reconnect and confirm the apps return. Try cancellation/resume and feature-off/feature-on without losing completed app history. Existing unrelated Mac apps must be preserved.

For desktop windows, turn off Android system decorations, close prior sessions and launch new sessions with each backend. Check that the virtual display's system navigation/taskbar/launcher surfaces are absent, while app controls, Back, typing and resizing still work. Turn decorations back on and repeat with a new session. Verify the phone's own navigation and launcher settings were not changed. App-drawn bars and IME behavior are separate from system decorations.

Do not mark this guide passed until performed on the actual Pixel 10 Pro. Emulator success cannot establish USB behavior, device codec limits, thermal performance, DRM compatibility, or Pixel-specific task policy.

## Clean names and phone display control

After installing the update, quit the old main app and open the new DroidBridge once. Let existing Mac app maintenance finish; quit running wrappers when asked. Spotlight should show app names without hashes (only actual duplicate labels receive readable disambiguation). No phone connection is needed for this local repair.

With the authorized Pixel connected and unlocked, open two Mac Android-app windows. Select the Pixel and enable **Keep phone screen off during Mac sessions**, or choose **Phone → Turn Phone Screen Off**. Confirm the physical panel is off while each Mac window continues updating and accepting clicks, typing and resizing. Close one window, then the other: closing should leave the phone off. Choose **Phone → Turn Phone Screen On** to clear the saved setting and restore/wake the panel; verify that normal lock/PIN behavior remains intact. Repeat with the fallback backend using the main DroidBridge controls. Disconnect/reconnect and reopen a Mac app: the saved device choice should apply only to the Pixel. Collect diagnostics if a command cannot be confirmed; a power-control failure must not close working app sessions.

For launch UX, quit the old copied wrapper and let the updated main DroidBridge refresh it. Launch from Spotlight: the Android app icon/name and loading status should appear immediately without the main launcher. Resize, close and reopen; confirm the size is retained and the same window switches to live video. Try closing while loading and reconnecting an unavailable phone. For fallback, confirm loading hands over to the Player and its last size is restored.
