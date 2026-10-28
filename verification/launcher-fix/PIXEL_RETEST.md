# Pixel ChatGPT wrapper retest

The installed host application is DroidBridge 0.1.1. Existing Mac wrappers contain
their own executable, so installing a newer DroidBridge does not change an old
ChatGPT wrapper until it is updated.

1. Quit the existing ChatGPT wrapper. Connect and authorize the Pixel normally.
2. Open DroidBridge, select the Pixel and ChatGPT, then choose **Create / Update
   Mac App…**. This refreshes the matching wrapper in place, preserving its device
   and backend settings and retaining its previous generation as a backup.
3. Launch that ChatGPT Mac app. Confirm the Android ChatGPT icon appears and its
   native window comes forward when video starts. Minimize it, then reopen the
   app from Finder/Dock and confirm the same session returns.
4. Switch to another Mac application and back with Cmd+Tab; confirm the ChatGPT
   name/icon and interactive Android content. This direct switcher test could
   not be executed on the locked development desktop.
5. Close the session window and confirm its display/process is released. Relaunch
   once more. A backend failure should now retain a visible diagnostic launcher
   with Retry, Try scrcpy/Try Native, Log and Close.

If a window still does not appear, open the wrapper's **Window → Launcher** menu
or reopen the wrapper to reveal its controls. Collect both matching
`~/Library/Logs/DroidBridge/session-<UUID>.log` and `.log.jsonl` files. The new
structured log records `native_window_presented`, `launcher_hidden`,
`session_close` and `session_stop_requested`, with the window visibility and
caller-specific reason. Redact the physical device serial before posting logs
publicly. The original log proved video decoding; these additional facts are
needed to distinguish foreground presentation from close/quit/device discovery.
Use the **first** `session_stop_requested` reason as the stop cause: AppKit can
close windows afterward during application quit, producing a later `window_close`
receipt that does not itself establish an intentional click on the close button.
