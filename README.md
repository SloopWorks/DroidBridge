# DroidBridge

DroidBridge runs Android applications on Android while presenting them in separate macOS windows. The launcher discovers authorized USB ADB devices and running emulators, enumerates launchable apps, and offers two session backends:

- **Native**: scrcpy 5.0.1 server, H.264 transport, VideoToolbox decoding, and AppKit windows with per-session input.
- **scrcpy**: the upstream scrcpy client manages each app's virtual display and interactive window.

Use the packaged application in `dist/` after building. See [BUILD.md](BUILD.md) for reproducible build and installation steps, [TESTING.md](TESTING.md) for executed checks, and [verification/REPORT.md](verification/REPORT.md) for evidence and outstanding acceptance items. Physical Pixel verification is described in [PIXEL_VERIFICATION.md](PIXEL_VERIFICATION.md).

Device content stays on the Mac and Android device. No account, cloud service, root, or Android system modification is required. USB debugging grants broad device access: authorize only Macs you trust. Apps that prohibit capture, secondary displays, or additional tasks may not work; see [COMPATIBILITY.md](COMPATIBILITY.md).

The 0.2 development candidate includes an optional Android companion for pairing,
phone controls, explicit sharing and app integration. It is implemented and under
final installed verification; it is not yet a public accepted release. Current
artifact and test status is in [the companion ledger](verification/companion/RELEASE_CANDIDATE.json)
and [program status](verification/companion/PROGRAM_STATUS.md). Outstanding
Spotlight, native-banner, fallback automation, performance and public-download
checks remain listed in [KNOWN_ISSUES.md](KNOWN_ISSUES.md).

## Use

Open DroidBridge and choose a connected device in the sidebar. The **Rendering** section offers **Native AppKit** or **scrcpy fallback**. Search by app name or package, select an app, and click **Launch App** (or double-click it). Launch another app the same way. Close a native window or use the session's Close button to release its display. Use **Restore Previous Sessions** after relaunch; the reconnect checkbox controls restoration after an interrupted connection. **Create / Update Mac App…** creates a separate launchable wrapper under `~/Applications/DroidBridge Apps` for Finder, Dock, and Spotlight indexing.

Created Mac apps use the launcher activity's icon rendered by Android, including adaptive and vector icons. Each wrapper is a separate Mac application with its own name, icon and process. Run **Create / Update Mac App…** again to update an existing matching wrapper after installing a new DroidBridge version; quit that wrapper first. Updates preserve its launch settings and keep the previous bundle under `~/Applications/DroidBridge Apps/.DroidBridge Backups`. The main launcher's app list loads Android icons asynchronously; unavailable icons have a diagnostic tooltip.

Spotlight and Dock wrapper launches immediately show an app-branded loading window using the saved Android icon. The window restores its previous size and position and reports connection progress, then becomes the live native app window when decoded content is visible. Initial solid-black Android frames retain the loading screen; prolonged blank video gets an explanation and a **Show Android Screen** control. Wrappers launch their saved package directly without waiting for the full Android app list. Closing during loading cancels the launch; offline or denied launches retain an explanation. The fallback keeps the loading window until its client reports a video texture, and remembers its window bounds through public macOS metadata when available.

Unexpected session exits keep the wrapper's diagnostics visible instead of silently quitting. Use its retry or fallback controls to start a fresh session. Explicitly closing the session still releases its resources and ends the wrapper.

**Enable device apps in Spotlight** is on by default. Click **Add All Device Apps to Spotlight** to prepare the selected device's apps. The operation runs with bounded background work and progress; use **Cancel** to stop admission, then click Add Device Apps again to resume. **Onboarding Details** retains individual errors; apps whose Android icons cannot be extracted are reported for retry. Managed apps are available only while their device is authorized and ready. A per-user availability helper maintains their visibility even after the launcher closes; offline apps move to a private `.noindex` store, and stale results cannot start an Android session. See [APP_ONBOARDING_DESIGN.md](APP_ONBOARDING_DESIGN.md) for ownership, migration and availability behavior.

Existing managed Mac apps are repaired automatically after installing this update and opening DroidBridge. A compatibility pass updates their copied code at the original paths before a second pass removes the visible hash suffixes. Android icons, backend choices and launch settings are retained; no phone connection is needed for this maintenance. Quit running wrappers to let their updates finish. Later releases also refresh accepted wrappers’ copied runtime from the new host using these saved assets. Unique apps use `App Name.app`; only name collisions on the same device receive a readable package suffix.

**Keep phone screen off during Mac sessions** is an opt-in setting saved separately for each device (Android 15+). Select the device, enable the checkbox, and open an Android app. Use **Phone → Turn Phone Screen Off / On** for immediate control; native wrappers expose the same menu. For an SDL fallback window, use DroidBridge’s main launcher/menu. The Mac windows keep receiving video and input while only the physical Android display is off. Closing a Mac app does not turn the phone screen back on; use the explicit On action. Android 17 uses its supported display-reset/wake commands, detected at runtime. This does not unlock the phone, bypass a PIN or remove secure-content restrictions.

**Show Android system decorations** applies to new sessions on either backend. Turn it off to remove Android's virtual-display navigation/launcher surfaces when using Mac app switching. App-drawn controls remain controlled by the app. The setting does not change the phone screen or global Android settings.

Android's on-screen keyboard is hidden in Mac app windows on both backends. Type with the Mac keyboard; this also works while the phone screen is off. DroidBridge requires Android 13 or newer because the pinned runtime needs trusted virtual displays to enforce this policy. After installing an update, open the main DroidBridge app and let managed Mac apps finish updating; quit running wrappers first. For independently created unmanaged wrappers, use **Create / Update Mac App…** again to replace their copied runtime.

**Audio** in the launcher selects **Mac**, **Phone**, or **Mac + Phone**, saved per device in a separate audio settings file that older wrappers cannot overwrite. Mac is the default when an app runs. Audio is **device-wide**, shared across both rendering backends and independent Mac wrappers; it is not isolated to the selected Android app. Mac routing silences normal Android playback; Mac + Phone captures only playback Android apps permit. Phone uses the normal Android output (including attached headphones).

Audio status distinguishes connection, initialized Mac output and failure. Initialized does not guarantee a particular app is producing audible sound. Check Mac Sound output/volume and app playback; use **Retry Audio** or **Use Phone** if capture/output fails. Audio failure does not close video windows. Native wrappers expose the same choices in the **Audio** menu; SDL fallback users can use the main launcher/menu. No microphone capture or automatic switch to a different capture source occurs.

It includes its runtime tools, dedicated pinned audio client and icon helper, so the installed application does not require Homebrew or an Android SDK installation. Video diagnostics are local under `~/Library/Logs/DroidBridge`; bounded audio failure logs are under `~/Library/Application Support/DroidBridge/AudioRoutes.noindex`. See [WRAPPER_DESIGN.md](WRAPPER_DESIGN.md) for the implementation and verification boundaries.

The [0.1.1 verification report](verification/launcher-fix/REPORT.md) covers the wrapper fixes, Android icons and independent review. The focused [Pixel wrapper retest](verification/launcher-fix/PIXEL_RETEST.md) explains the one-time update for existing copied wrappers and the additional window/stop diagnostics.

The [0.1.2 onboarding verification report](verification/onboarding/REPORT.md) records bulk creation, Spotlight availability, helper recovery, performance and independent review. [Android display evidence](verification/desktop-mode/ANDROID_REVIEW.md) covers the system-decoration option on Android 15 and 17.

After a device reboot, discovery and restoration wait for Android boot completion and package services. Interrupted sessions are checked on later four-second polls. Automatic restoration permits three failed launches per outage, with at least eight seconds after each failed attempt; the session remains visible if retries pause. Closing it cancels retry. Turn the reconnect checkbox off to hold interrupted sessions without admitting new ones.

The launcher keeps apps and running sessions together in a two-pane Mac workspace. Search by app name or package, then double-click or press Return in the app list/search field. The selected-app strip contains **Launch App** and **Create / Update Mac App…**. Device, rendering, screen and Spotlight settings live in the independently scrolling sidebar; session cards have their own scroll area with Focus, Close and recovery actions. **Apps → Find App…** (⌘F) searches while the launcher is active; **Window → Launcher** (⌘L) returns from an Android window, and **Settings…** (⌘,) reveals rendering settings. Empty, unauthorized, booting and failed-discovery states offer specific next steps. No app count is shown until a ready device’s catalog has loaded.

## Optional Android companion

Streaming works through authorized ADB without companion pairing. To add the
companion, open **Phone → Companion…**, select the authorized phone, click
**Install / Update Android Companion**, then **Open Android Companion**. On the
phone explicitly start the connection service. Its foreground notification makes
that service visible; stopping it disconnects companion features without
implicitly stopping independent ADB video sessions.

On the phone choose **Pair a new Mac**. In **Pair Phone…** scan/import the QR or
paste the **complete pairing link**, compare the displayed Mac name and code,
and approve on the phone before the two-minute window expires. The link includes
the phone's TLS identity; a bare code or old pinless link cannot pair. Camera
access is optional: image import and full-link entry are alternatives. Treat the
QR/link as a secret and do not include it in screenshots or reports.

The companion window provides:

- **Apps:** names/icons, search, favorites, Open on Mac and per-app Spotlight
  export choices. Visible catalog surfaces consume phone change hints and merge
  bounded deltas; Refresh remains a recovery action. Start bulk wrapper creation
  with **Add All Device Apps to Spotlight** in the main launcher. Selection saved
  with a wrapper still pending is reported separately; use explicit Retry when
  offered. Wrapper creation does not prove Spotlight has indexed it.
- **Sessions:** live registered main/wrapper sessions, targeted Stop/Stop All,
  phone-side Open on Mac, device-wide audio and phone-screen controls. Open the
  installed main app once so the broker can register its location for phone
  launches after the main GUI quits. Updated wrappers participate independently.
- **Handoff:** deliberate text/link/file/image sharing, verified transfers and
  explicit clipboard send/copy in both directions. Phone clipboard reads require
  foreground user action. Received files need explicit Save/Open; nothing runs
  automatically. Cancel stops a transfer; inspect an uncertain result before retry.
- **Notifications:** optional Android notification access, per-Mac opt-in and app
  filters, current in-app notifications, dismissal and supported replies. Enable
  only the apps you want. An empty filter permits all otherwise allowed apps.
  Sensitive/unsupported notifications are excluded or have no Reply action.
  Denied Mac notification permission leaves the in-app list available.
- **Performance / Diagnostics:** battery, thermal and network observations,
  explicit redacted export, and Battery (15 fps) / Balanced (30 fps) / Responsive (60 fps) frame-rate
  ceilings for **new** app windows. Existing streams keep their settings; actual
  rate depends on content, phone and host. No battery-saving guarantee is made.
- **Get Mac App:** explicit official release metadata lookup and download link,
  including version/platform, size, SHA-256 and signing status. An unpublished
  version stays unavailable. The phone cannot install or approve software on Mac.

For Wi-Fi, use the Mac wireless setup controls with Android **Wireless debugging
→ Pair device with pairing code**, then Connect using its current debugging
endpoint. This is Android's authenticated debugging transport; companion QR trust
is a separate step. Drain current USB sessions before changing aliases. A
reconnection can have a visible gap and never promises seamless stream migration.

## Trust, updates and privacy

Quit old main apps, wrappers and audio hosts before upgrading. Open the new main
app and let managed wrappers update; recreate/update manual wrappers explicitly.
Old copied hosts do not participate in the new dashboard/USB–Wi-Fi ownership
protocol. See [COMPATIBILITY.md](COMPATIBILITY.md).

The candidate is **ad-hoc signed, not Developer ID signed or notarized**. An
ad-hoc helper update can lose access to its old Keychain record; DroidBridge fails
promptly instead of repeatedly prompting. Use **Forget Pairing on This Mac**,
remove the old Mac in the phone's Trusted Macs, and pair with a fresh complete
link. Saved export/profile intent is retained separately. Reinstalling the
Android app replaces its identity and requires new trust; a same-signed update
preserves its data. Preserve the Android signing identity when building updates.

Companion traffic uses certificate-pinned TLS over an exact-owned loopback ADB
forward. There is no raw LAN listener, account, hidden cloud relay, background
clipboard collection, video or PCM in this channel. Explicit Get Mac App lookup
contacts the official public GitHub release service without device/trust/content
payload. Pairing does not grant Android debugging, and Forget/Revoke does not
revoke it. To remove all access, close sessions and revoke USB/wireless debugging
separately. User-saved files and already delivered content are not erased remotely.

An expired/unknown request is not proof nothing happened: inspect the inbox,
selection or session before starting a new deliberate request. The app preserves
receipts and does not automatically replay uncertain effects. For installation,
removal and local data locations see [BUILD.md](BUILD.md); for a concise full
physical-phone check see [PIXEL_VERIFICATION.md](PIXEL_VERIFICATION.md).
