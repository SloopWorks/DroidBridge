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

Do not mark this guide passed until performed on the actual Pixel 10 Pro. Emulator success cannot establish USB behavior, device codec limits, thermal performance, DRM compatibility, or Pixel-specific task policy.
