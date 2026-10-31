# Known issues and acceptance boundaries

Implementation and acceptance are tracked separately in
[the companion ledger](verification/companion/RELEASE_CANDIDATE.json) and
[program status](verification/companion/PROGRAM_STATUS.md). The current 0.2
candidate is still undergoing final installed/release checks. Earlier pass/fail
records stay bound to their exact artifacts.

## Pending release evidence

- **Spotlight:** signed wrapper creation, Android icons, managed availability and
  stale-result launch refusal have executable evidence. Current test-host user
  Applications metadata/search UI is blocked or unverified; system-app and
  synthetic CoreSpotlight controls passed. Actual generated-wrapper Spotlight
  search/activation remains unproven. Separate bundle IDs or importer output do
  not prove it. Direct Dock/Cmd+Tab UI automation also remains unverified.
- **Notifications:** in-app actual reply/dismiss and permission-denied operation
  have installed evidence. This Mac reports native notification permission
  Denied, so allowed-state banner delivery is unverified. No OS permission reset
  or bypass is claimed. Generic package-only alerts can remain as Notification
  Center history after phone removal; the current in-app list is authoritative.
  Clear Inbox does not clear that OS history.
- **Fallback input automation:** the shipped scrcpy path suppresses buttonless
  hover. Real keyboard/video and earlier no-hover clicks have evidence, while
  later post-keyboard CUA pointer coordinates were inconclusive/failed. Final
  correctly targeted two-window click/drag/scroll proof remains pending; do not
  infer success from command-line flags or native-window input.
- **Performance:** previous quiet cold-preview/video cohorts failed the original
  targets. New local-window startup changes still require the coordinated quiet
  final cohort; no 100 ms preview guarantee is claimed. Profiles configure new
  stream ceilings, not guaranteed 60 fps or measured battery savings.
- **Distribution:** current candidate is ad-hoc signed, not Developer ID signed
  or notarized. Final corresponding-source/artifact review, public versioned
  download and downloaded-copy installation remain pending. An unavailable Get
  Mac App result is truthful failure, not successful delivery.
- Final Mac/APK changed-path, Unicode, recovery and uninstall receipts must be
  read from the current ledger. Real host sleep/wake is distinct from service
  restart/monotonic-clock tests. Physical Pixel/USB/Wi-Fi/thermal/audibility
  acceptance remains the owner's final hardware stage.

## Platform behavior

- Packaged binaries require Apple Silicon/macOS 26. Android 13/API 33+ is required
  to enforce hidden IME policy on trusted virtual displays. Older/unreadable API
  levels fail before staging. Apps control task affinity, single-instance rules,
  orientation, app-drawn keypads, capture security and secondary-display support.
  Protected/incognito/DRM content can be blank; DroidBridge does not bypass it.
- Main-process native windows share one Cmd+Tab identity; generated wrapper
  bundles have separate process/application identities and Android launcher icons.
  Unique names omit hashes; real label collisions get readable disambiguation.
  Monochrome wallpaper-themed icon tint is not reproduced.
- Fallback uses upstream external SDL windows; closing a Player is a backend
  exit, so its wrapper retains diagnostics. Use that diagnostic host's Close or
  Quit to end it. A normally closed native wrapper session exits its wrapper.
  Hover-only tooltips are unavailable on both backends.
- Text injection has Android key-map/complex-composition limits. Explicit
  clipboard paste/handoff is available; continuous bidirectional synchronization
  and native drag-and-drop file transfer are not promised. Use Companion Handoff
  for files. The Android software IME stays hidden in virtual-display sessions.
- Audio is device-wide, shared across wrappers/backends, with no per-app volume
  isolation, microphone or call-audio forwarding. Apps may refuse playback capture.
  Output initialized means the host opened output, not proof of audible media.
  Retry/Phone leaves video running; physical speakers/Bluetooth need hardware tests.
- Screen-off is opt-in per device and requires detected Android 15+ command support.
  Only the physical panel is targeted; lock/PIN policy still applies. Closing
  sessions leaves it off. Explicit On retries while its host lives; quitting that
  host cancels pending work. Use the main launcher for fallback screen/audio menus.
- Closing a virtual display can destroy its Android tasks. Restoration creates a
  new display/app launch, not a persisted video process. Reconnect waits for full
  Android readiness; three failed launches pause that outage until deliberate
  retry. Companion reconnect does not promise gapless stream migration.
- Bulk onboarding discovers launchable apps, not background/service packages.
  Running/unrelated/ambiguous wrappers are preserved and reported. Cancel stops
  new work without deleting completed history. Availability and macOS indexing
  can lag; independent launch admission still refuses unavailable/disabled apps.
- Local blank-video detection uses a tiny brightness sample, so dark legitimate
  UI may retain loading. After5seconds use **Show Android Screen**. This heuristic
  never identifies or bypasses secure content. Fallback geometry tracking uses
  public metadata; unavailable metadata preserves previous bounds.

## Companion trust and uncertain outcomes

Quit/update old main, wrapper and audio hosts before pairing or switching USB/
Wi-Fi aliases. Pre-0.2 hosts do not publish the new dashboard or hold canonical
alias leases. An absent dashboard row does not prove an old capture stopped.
See [COMPATIBILITY.md](COMPATIBILITY.md).

An ad-hoc broker update can make its old Keychain record inaccessible. The app
fails promptly; Forget locally, remove the old phone Trusted Mac and pair again.
Retained export/profile intent is separate. Reinstalling/clearing Android data
changes its identity. Companion Forget/Revoke does not revoke USB/wireless ADB
access, terminate all independent capture, or erase user-saved content.

The companion service stays off after Android reboots until you explicitly start
it. During startup, `server_authentication_failed` can also describe an unreachable
or not-yet-listening service; it does not by itself establish a changed pin or
lost trust. Start the phone service and allow reconnection before resetting any
pairing. The emulator restart test recovered the same trust without re-pairing.

Expired/unknown requests do not prove absence of an effect. Text may already be
in the inbox or selection intent already committed when an acknowledgment is
lost. Inspect current state before a new deliberate retry. Pending wrapper
materialization is distinguished from active publication; retry uses a new user
intent. Uncertain effects are never automatically replayed.
