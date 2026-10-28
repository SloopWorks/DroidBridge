# macOS GUI verification observations

2026-10-27, CUA native macOS automation, host macOS 26.2 arm64.

- Draft packaged app `dist/DroidBridge.app` launched via Launch Services.
- ADB device list populated automatically and 28 launchable apps appeared for Android 17 emulator-5554. This was an existing emulator; the test opened only a separate Settings virtual display and closed it afterward.
- Search field typed `Settings`; app table filtered to com.android.settings.
- Launch App opened actual native AppKit Settings window; screenshot showed live Android Settings UI, not a placeholder.
- Native pointer click at screenshot [240,250] opened Android Settings search. Native typed text `Bluetooth` twice appeared as `BluetoothBluetooth` in actual Android search UI, proving pointer+keyboard reached stream.
- macOS close control closed Settings window, returned launcher to zero sessions.
- Quit via Cmd+Q succeeded.
- Copied bundle using `ditto` to ~/Applications/DroidBridge.app; codesign --verify --deep --strict passed. Bundled scrcpy --version printed 5.0.1; bundled adb version printed37.0.0. Installed copy launched successfully and discovered apps.

These observations do not establish concurrent GUI sessions, resizing, automatic reconnection, wrappers, or fallback GUI until the later tests below are recorded. Screenshots were returned visibly by CUA; separate on-disk evidence is being captured.

## Installed copy, isolated API35 emulator

- Selected emulator-5580 in the graphical device picker, searched `DroidBridge`, selected dev.droidbridge.testapp, clicked Launch App.
- Live AppKit video displayed display2 and changing tick counts. Native mouse clicked counter from0 to1. Native keyboard typed `native-first` into the Android text field. Saved actual CUA screenshot `native-gui-first.png` (text screenshot timing captured the initial visible prefix while input frames were arriving).
- Minimized first session with its standard macOS minimize button. Launcher still listed its state `native · running`.
- Selected dev.droidbridge.testapp2 and launched a second native AppKit window. It displayed display6, counter0, blank text independent of the first session. Clicked twice and typed `second`. Saved `native-gui-second.png` with counter2 and `second` visible.
- Minimized second session; launcher showed two active native sessions with independent Focus/Close controls.
- Focus restored a minimized session window. A concurrent integration test then moved that package's task to another display, so this run cannot establish preserved content after refocusing. The dedicated executable integration/QA run owns that assertion.
- Cmd+Q shut down the installed copy and released both GUI sessions for exclusive backend tests.

Native screenshot evidence was saved directly from CUA returned PNG bytes via node:fs/promises. It is actual window content. No placeholder, mock, or reconstruction was substituted.

## Final DMG and fallback Player

- Mounted `dist/DroidBridge-0.1.0-arm64.dmg` read-only at `/tmp/DroidBridge-install-test`; copied contained `.app` to `~/Applications/DroidBridge.app`; unmounted image; deep/strict codesign passed. Main executable hash exactly matches signed `dist/DroidBridge.app`. See `verification/release/install-final.txt`.
- Final package contains a separate nested Player.app (bundle ID app.droidbridge.player) used for fallback SDL windows. Its Contents/lib symlink resolves to Runtime/lib; bundled scrcpy5.0.1 executed successfully.
- Final installed app selected emulator5580, fallback backend, dev.droidbridge.testapp via GUI. CUA bound actual Player window, showing display32.
- Actual Player mouse click incremented Android counter0→1, text entry produced `fallback-one` on display32. `fallback-gui-first.png` and `fallback-gui-input.log` contain screenshot + Android receipts.
- Launched dev.droidbridge.testapp2 while first session remained active. Both were listed `scrcpy · running`; second live window showed display33 and blank/counter0 state independent of first. Closed the first window and remaining display33 kept running.
- Invoked standard Zoom on second Player window; actual Android virtual-display dimensions changed720x1080→1496x906. Android recreated the test activity, resetting its transient counter/text.
- Second fallback input was attempted but **not verified**: CUA subsequently explicitly reported the host was locked and automatic unlock failed. No second-input Android receipt was found; do not mark that input attempt passed. First fallback input and both native input sessions have executable receipts.
- The host lock also prevented final GUI retesting of the wrapper auto-quit fix and direct Dock/Cmd+Tab UI observation. QA can still run programmatic native-window and installed lifecycle tests.

## Wrapper identities

- Generated Settings.app and Clock.app using actual Create Mac App GUI, launched both independently. Live windows saved `wrapper-settings.png` and `wrapper-clock.png`.
- NSWorkspace enumerated distinct running PIDs and bundle IDs for host, Settings and Clock (`wrapper-identities.txt`). Spotlight `mdfind` and `mdls` found Settings wrapper under its own bundle ID (`wrapper-spotlight.txt`).
- Direct Cmd+Tab/Dock switcher UI was not established by automation and remains unverified; separate identity was established.
- Found and fixed a real wrapper auto-quit hang: invoking NSApp.terminate from a main-dispatch callback deadlocked the subsequent terminateLater MainActor continuation inside AppKit's nested termination loop. The wrapper now schedules its termination selector through the run loop. Earlier hung test wrappers were terminated by exact PID after their owned forward/display resources were already cleaned. The final fix is compiled and packaged; its GUI retest was blocked by host lock.

## Final release remediation and installation

- Final startup selection now honors `--serial` or generated wrapper `launch.json` before querying any apps. A missing explicit device produces no automatic query against another connected device. DeviceSelectionTests3/3 passed.
- Strict signing audit rejected the earlier generated wrappers' external Runtime symlinks. Final wrapper creation copies its own pinned Runtime plus license notices and THIRD_PARTY.md. This removes the host-path dependency and produces self-contained bundles. The old dependency note above describes the rejected earlier draft only.
- Mounted the rebuilt final DMG read-only and installed it again. Final installed and signed distribution main executable SHA256 both `bf8a81e09e9b449506ddf932670b56f43be56ff06028e8e1992503945fd8a867`.
- Restored the two test-created Settings/Clock wrappers with final executable and copied runtime. Both passed `codesign --verify --deep --strict`; exact receipts are `verification/release/wrapper-refresh.txt`.
- Released exclusive emulator access to independent QA for final source suite, actual installed binary lifecycle, and programmatic wrapper-window-close tests. No further source changes are planned.
