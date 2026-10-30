# Known issues and acceptance boundaries

This file describes actual limitations, not substitutes for the verification report.

- Companion native Mac alerts, when authorized, contain only the Android package
  and a generic invitation to open DroidBridge. Notification Center can retain
  this alert history after Android removes or replaces a notification; the
  companion's in-app list is the current authority. Old alerts provide no reply
  or dismissal action. Clear Inbox clears inbox metadata, not Notification Center
  history. Actual allowed-state banner delivery remains an open installed gate
  while this test Mac reports notification permission denied.

- The packaged runtime is Apple Silicon/macOS 26. Source-only builds may support older macOS with compatible runtime dependencies.
- Android 13/API33 or newer is required to enforce hidden software keyboards on secondary virtual displays. Earlier Android versions and unreadable API levels are refused. Apps may enforce task affinity, single-instance behavior, orientation, secure capture, or phone-only layouts. DRM/secure content is intentionally not bypassed.
- Android package labels are discovered dynamically. Created Mac apps and launcher rows extract the resolved launcher activity/alias icon, including adaptive/vector resources. Unavailable row icons have a diagnostic tooltip; wrapper creation reports extraction failure. Optional wallpaper-themed monochrome tint is not reproduced. A label or valid icon does not imply an app permits secondary-display use.
- The scrcpy fallback owns external SDL windows. Its window input and resize come from upstream scrcpy. DroidBridge's native windows share one process and one Cmd+Tab identity. Separate generated wrapper process/bundle identities and Spotlight indexing were verified. Direct Dock UI and Cmd+Tab switcher automation were blocked/unverified; no claim of their observed behavior is made.
- Closing the fallback's external player is observed as a backend exit, so its wrapper retains the diagnostic launcher. Use that launcher's Close control or Quit to end the wrapper. Closing a native wrapper window ends its session and exits the wrapper normally.
- Audio routing is device-wide, with one owner shared across wrappers; per-app volume/isolation and Mac microphone forwarding are not implemented. Mac + Phone capture can remain silent when an app opts out. Output initialized means the host device opened, not proof of audible app sound. Failure leaves video running and offers Retry / Phone. Physical speaker audibility, protected/call audio, OEM policy and Bluetooth route transitions require device-specific verification.
- Mac-to-Android clipboard paste is supported by the native control protocol. Full bidirectional clipboard synchronization, IME composition, and drag-and-drop file transfer require additional work unless explicitly verified in the report.
- Session restoration creates a new display and launches the app again; Android owns persistent application state. Closing a display destroys tasks on that display according to scrcpy's default policy.
- The owner reports DroidBridge working with a Pixel 10 Pro, with a ChatGPT wrapper exception under investigation. Physical Pixel acceptance is the owner’s manual stage; automated verification does not operate it. ChatGPT-specific task/video behavior and Android 17 icon extraction remain unverified locally; thermal limits and protected media are also outside the emulator evidence.
- The artifact is ad-hoc signed and has not been notarized. Public distribution also needs corresponding-source/license compliance review for bundled runtimes.
- Bulk onboarding covers launchable applications returned by the device, rather than every background/service package. Running wrappers are skipped safely; extraction, capacity and per-app failures appear in Onboarding Details and can be retried. No Android apps are launched by onboarding itself. Previously completed wrappers are retained when cancellation or a later app fails.
- Managed Spotlight availability follows bounded background polling and macOS indexing, so search results can briefly lag device connection changes. Launch admission independently refuses unavailable/disabled managed apps. Feature-off preserves managed history. Unmanaged wrappers remain independent until explicitly adopted by onboarding; running or ambiguous manual wrappers are preserved and reported.

See `verification/REPORT.md` for exact results, blocked checks, and independent review findings. GUI screenshot/automation restrictions must be stated there; a decoded frame is evidence of streaming, not a substitute for a macOS desktop screenshot.

Automatic reconnection waits for full Android readiness. Three failed launches pause automatic retry for that outage; close and launch the app to start a fresh intent. Explicit Restore keeps unavailable saved descriptors pending and requires another Restore action once the device is ready.

- Phone screen control is opt-in per device and requires verified Android15+ shell support. Closing windows deliberately does not wake the phone. Explicit ON requests retry after transport/lock errors while that host stays open; quitting the host cancels its pending work. Native wrapper menus expose the controls; for SDL fallback windows use the main DroidBridge launcher/menu. Hardware panel/lock behavior on the physical Pixel remains for owner verification.

Wrapper loading uses a local screen manufactured from the Android launcher icon; Android controls its own in-app splash afterward. Fallback size tracking relies on public WindowServer metadata and local optical-frame calibration; if metadata is unavailable, the previous known geometry is retained. Changing macOS style/monitor scale during a running fallback session has not been exercised. No screen recording or accessibility permission is requested for this metadata path.

Initial native blank-frame detection uses an 8×8 thumbnail and a small brightness threshold; very dark or sparse legitimate UI can also look blank. After 5 seconds, an explanation and **Show Android Screen** button let you reveal the actual stream and interact. This is a presentation heuristic, not evidence that an app blocks capture; it never bypasses Android capture policy.


The companion0.2 program requires updating/quitting older copied hosts before
pairing or switching USB/Wi-Fi. Pre-companion wrappers do not publish dashboard
sessions or hold canonical alias leases. Their absence from the new dashboard
is not evidence that they stopped, and companion Forget/Revoke does not revoke
Android debugging. See the upgrade boundary in COMPATIBILITY.md.

The companion distinguishes an expired request from confirmed absence of an
effect. Shared text can already be saved in the Mac inbox, or an export choice
committed, before the phone receives its admission/completion receipt. If that
receipt is lost or arrives after the phone's deadline, inspect the Mac inbox or
saved app selection before starting a new deliberate request. Expired/unknown
does not prove nothing happened; there is no automatic effect replay.
