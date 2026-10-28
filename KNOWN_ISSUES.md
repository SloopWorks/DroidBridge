# Known issues and acceptance boundaries

This file describes actual limitations, not substitutes for the verification report.

- The packaged runtime is Apple Silicon/macOS 26. Source-only builds may support older macOS with compatible runtime dependencies.
- Android must support secondary virtual displays (Android 10+ platform baseline; verified API 35). Apps may enforce task affinity, single-instance behavior, orientation, secure capture, or phone-only layouts. DRM/secure content is intentionally not bypassed.
- Android package labels are discovered dynamically. Created Mac apps and launcher rows extract the resolved launcher activity/alias icon, including adaptive/vector resources. Unavailable row icons have a diagnostic tooltip; wrapper creation reports extraction failure. Optional wallpaper-themed monochrome tint is not reproduced. A label or valid icon does not imply an app permits secondary-display use.
- The scrcpy fallback owns external SDL windows. Its window input and resize come from upstream scrcpy. DroidBridge's native windows share one process and one Cmd+Tab identity. Separate generated wrapper process/bundle identities and Spotlight indexing were verified. Direct Dock UI and Cmd+Tab switcher automation were blocked/unverified; no claim of their observed behavior is made.
- Closing the fallback's external player is observed as a backend exit, so its wrapper retains the diagnostic launcher. Use that launcher's Close control or Quit to end the wrapper. Closing a native wrapper window ends its session and exits the wrapper normally.
- Audio is disabled in this release. Live video and interactive input are the acceptance focus.
- Mac-to-Android clipboard paste is supported by the native control protocol. Full bidirectional clipboard synchronization, IME composition, and drag-and-drop file transfer require additional work unless explicitly verified in the report.
- Session restoration creates a new display and launches the app again; Android owns persistent application state. Closing a display destroys tasks on that display according to scrcpy's default policy.
- The owner reports DroidBridge working with a Pixel 10 Pro, with a ChatGPT wrapper exception under investigation. The development environment currently has no attached physical Pixel. ChatGPT-specific task/video behavior and Android 17 icon extraction remain unverified locally; thermal limits and protected media are also outside the emulator evidence.
- The artifact is ad-hoc signed and has not been notarized. Public distribution also needs corresponding-source/license compliance review for bundled runtimes.

See `verification/REPORT.md` for exact results, blocked checks, and independent review findings. GUI screenshot/automation restrictions must be stated there; a decoded frame is evidence of streaming, not a substitute for a macOS desktop screenshot.

Automatic reconnection waits for full Android readiness. Three failed launches pause automatic retry for that outage; close and launch the app to start a fresh intent. Explicit Restore keeps unavailable saved descriptors pending and requires another Restore action once the device is ready.
