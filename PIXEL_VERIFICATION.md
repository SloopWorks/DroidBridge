# Pixel 10 Pro physical acceptance

Use the final release/build and checksums identified in the companion ledger.
This is the owner's hardware check, not an emulator pass. Keep results separate
from automated evidence. Use disposable content and two apps such as Settings
and a browser; secure/incognito/DRM pages can intentionally be blank.

1. **Install/update Mac.** Verify the installer checksum/signing status, copy
   DroidBridge to Applications and follow normal macOS Open/Privacy & Security
   approval if needed. Current candidates are ad-hoc signed and not notarized.
   Quit old main apps, wrappers and audio hosts first. Open the new main app once
   and finish managed-wrapper maintenance; update manual wrappers explicitly.
2. **Authorize USB.** On Pixel Settings → About phone tap Build number seven
   times; enable System → Developer options → USB debugging. Use a data cable,
   unlock and approve this Mac's RSA prompt. Root is unnecessary. In DroidBridge
   select the Pixel; unauthorized/booting/offline must not permit app launches.
3. **Two real app windows, both backends.** Select Native AppKit and launch two
   different apps. Move/minimize/restore/focus/resize each; click, drag, scroll,
   type and paste distinct disposable text. Input must affect only the focused
   app. No Android software keyboard should appear. Close and repeat with scrcpy
   fallback, including pointer actions after typing. Check diagnostics if a
   wrapper shows loading/blank video; do not treat a window as proof of frames.
4. **Phone-screen independence.** Use another app on the phone while both Mac
   sessions run. Turn **Keep phone screen off during Mac sessions** on or use
   **Phone → Turn Phone Screen Off**; verify physical panel off while Mac frames,
   input and resize continue. Closing windows should leave it off. Explicit On
   restores/wakes the panel without bypassing PIN/lock. Repeat fallback through
   the main controls. Try **Show Android system decorations** off/on with new
   sessions; phone global navigation must remain unchanged.
5. **Install and pair companion.** Open **Phone → Companion…**, select Pixel,
   choose **Install / Update Android Companion**, then **Open Android Companion**.
   Start the phone connection service explicitly. Choose **Pair a new Mac** on
   the phone; scan/import its QR or paste the complete link into **Pair Phone…**.
   Compare named Mac/code and approve before expiry. Do not publish the QR/link.
   Camera permission is optional with import/manual alternatives.
6. **Catalog and Mac apps.** Check names/icons, search and persistent favorites.
   Install/update/remove a disposable app while the main/Companion catalog is
   visible; it should update automatically without Refresh. Choose a few exports
   and click **Add All Device Apps to Spotlight** for explicit onboarding. Check
   progress/cancel/resume and clean names/Android icons. Search/launch two actual
   Spotlight results and verify separate Dock/Cmd+Tab identities. Disconnect:
   managed apps should become unavailable after reconciliation; stale results
   must refuse new launch. Reconnect and check return. Record any indexing delay.
7. **Phone controls/main closed.** Open the installed main app once for host
   registration, then quit its GUI while wrappers run. On phone select this Mac:
   Open on Mac, dashboard, targeted Stop and Stop All must act on exact sessions.
   Test Mac/Phone/Mac+Phone audio with known media and real speakers/headphones;
   it is device-wide. Use Retry/Phone on failure. Test screen Off/On here too.
8. **Deliberate handoff.** Share disposable text, URL, image and file from Android
   to the named Mac. Save/Open only explicitly and compare contents/hash where
   practical. Send a file back and save through Android's picker. Test cancel/
   resume/retry and disconnected receiver. Explicitly copy/send clipboard each
   direction while companion is foreground; idle/background activity must not
   collect it. Inspect state before retrying an expired/unknown result.
9. **Optional notifications.** Explicitly grant Android notification access,
   enable this Mac and select a disposable app filter (empty means all allowed
   apps). Test a public notification's update, supported reply and dismissal;
   verify one reply delivery and refusal of stale actions. Private/unsupported
   notifications must not disclose content. Revoke and verify new content stops.
   Mac Denied permission should retain in-app actions; native banners require
   normal OS authorization and are a separate result.
10. **Profiles and recovery.** Apply Battery/Balanced/Responsive and open new
    sessions; existing sessions retain settings. Inspect health readings without
    assuming unknown means zero. Unplug/reconnect USB, stop/restart only companion,
    quit/relaunch Mac, then reboot Pixel. Expect visible interruption, readiness
    checks, saved trust and bounded restoration rather than duplicate sessions.
    For Wi-Fi use Android Wireless debugging pairing-code and Mac Pair/Connect
    controls, then its current debugging endpoint. Drain USB sessions before
    alias switching; test endpoint change and outage/reconnect.
11. **Delivery/update/revoke.** In phone/Mac **Get Mac App**, refresh official
    metadata and compare version, architecture, size, SHA-256 and signing status.
    Open/copy the fixed download link; install/approve only on Mac. An unavailable
    public version is not a successful delivery. Same-signed companion updates
    should retain trust/settings. After an ad-hoc Mac Keychain refusal use local
    Forget, remove old phone trust and fresh pairing; export/profile intent should
    remain. Finally revoke/forget this Mac and verify companion access stops.
    Close sessions and revoke USB/wireless debugging separately to remove ADB
    access. Do not uninstall personal state merely to test a disposable cleanup.

For failures export Companion → Diagnostics → **Export Report…** and/or phone
Settings → **Export redacted diagnostics…**. Include Mac/Android release/build,
connection type, package/backend, time, actual/expected behavior and minimal steps.
Video logs are under `~/Library/Logs/DroidBridge`; review logs/screenshots before
sharing. Exclude device serials, QR/full links, credentials, private clipboard,
notification bodies and personal files. An initialized audio label is not proof
of listening; emulator evidence is not USB/Wi-Fi/thermal/hardware acceptance.
