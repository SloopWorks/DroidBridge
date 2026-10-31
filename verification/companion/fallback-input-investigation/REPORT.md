# Installed fallback input investigation (QA8)

Scope: unchanged installed QA8 Mac application, production pinned scrcpy5.0.1, bundled SDL3.4.18, API37 emulator-5582. Companion APK11 is unchanged. No physical device, shared ADB server, or OS permission was modified.

## Reproduction

Two concurrent production fallback sessions (Alpha display48, Beta49) were launched using the graphical launcher. Alpha accepted two CUA button clicks before EditText typing. After typing the synthetic fixture text `r8`, the same freshly captured visible button coordinates no longer changed its counter. A subsequent held click did not increment it either. Current Android hierarchy kept the button at `[24,258][696,330]`; there was no layout/IME-pan explanation. The virtual-display IME stayed hidden.

A disposable original permission-free APK, `dev.droidbridge.inputprobe`, was installed as a separate package. Alpha/Beta and frozen companion APKs were not replaced. Probe display50 used the exact same production fallback flags, including `--no-mouse-hover`. It logs bounded MotionEvent metadata only; no keyboard codes/text or clipboard values are logged.

- First CUA screenshot-coordinate click `(700,650)`: Activity DOWN `(350,293)`, correct button hit; taps0→1.
- EditText click `(420,407)`: DOWN `(210,171)`; synthetic keyboard input worked.
- Immediate CUA button click after keys: no new Activity touch dispatch; taps stayed1.
- Subsequent held CUA click at the same visible position: DOWN `(0,218)`, `handled=false`, taps stayed1. The x/y values logged after dispatch can be modified by child dispatch; DOWN coordinates and independently captured counter/hierarchy are the relevant evidence.

The exact owned NSWindow remained561×874 logical points at global467,45. CUA screenshot was1122×1748 pixels. No assumption that a successful fresh-session click proves focused-session input was used.

## Source explanation to verify

The actual bundled `SDL_GetVersion()` returned3004018 (3.4.18). Host macOS26.2 build25C56.

[SDL3.4.18 Cocoa input source](https://github.com/libsdl-org/SDL/blob/release-3.4.18/src/video/cocoa/SDL_cocoawindow.m) contains two relevant behaviors:

1. `Cocoa_SendMouseButtonClicks` uses cached SDL mouse coordinates for the keyboard-focused window; the NSEvent location is used directly only for a nonfocused target.
2. On macOS26+, `mouseMoved:` replaces NSEvent coordinates with `SDL_GetGlobalMouseState()` minus the window position, as a workaround for incorrect native movement locations.

A process-targeted synthetic event that does not update the real global cursor can therefore produce a correct background/initial click followed by stale focused click coordinates. The actual global cursor was outside the Player window when read after the failing CUA sequence. This is a source-supported automation hypothesis, requiring an independent normal input verification before claiming a product result. No product patch is justified by these CUA failures alone.

## Independent system-event check

Three bounded public API attempts were executed: global HID move/down/up, global move with PID-targeted buttons, and the latter with explicit public CGWindowID fields. Existing PostEvent and ListenEvent preflight checks were true. Each confirmed the exact Probe PID as frontmost and global cursor817,370 (current window origin467,45 plus350,325). **None produced a new Probe Activity touch or incremented its counter.** There is no success claim for normal production mouse input from these attempts. The exact event source files and recorded stdout metadata are retained.

A later actual hierarchy still showed taps1. Its key-down count had increased from2 to8 without additional deliberate key calls in this investigation; no conclusion is drawn about that unexpected observation. Root confirmed its full suite did not issue GUI or5582 keyboard actions, and Mac's concurrent granted GUI-only fixture did not use ADB. This is another reason not to treat the automation sequence as physical-input acceptance.

Decision: preserve the Android11 release and production streaming source unchanged. The source-supported SDL/CUA interaction remains a strong hypothesis, with normal system-event routing **unproven** in this harness. Independent installed QA and eventually physical input are required; no speculative SDL flag or privileged Android override was added.

## Evidence

- `diagnostic-manifest.json`: source/APK hashes.
- `sdl-version.json`: actual bundled SDL version.
- `alpha-after-keys.xml`, `probe-before-global-input.xml`: current actual Android hierarchy.
- `probe-events.txt`: bounded original fixture MotionEvents.
- `probe-after-keys.png`: unmodified current CUA capture.
- `window-facts-initial.json`, input/window dumps: bounded owned-session diagnostics.

Cleanup completed using the graphical Close control followed by uninstalling only `dev.droidbridge.inputprobe`. Exact owned `/sdcard/droidbridge-input-probe.xml` and `...-alpha.xml` were removed. Actual display IDs returned to[0]; forward list contained only baseline emulator-5582 tcp46000→tcp37841. All Player/audio sessions ended. The QA8 main3941, broker89717, existing phone trust and service remained; launcher fallback/decorations and Mac audio preference remained, search was restored toinputbeta. No dev/WiFi/font/density state was changed. Exclusive GUI/device ownership was explicitly returned to the macOS agent and acknowledged.
