# Independent macOS launcher review

Scope: AppKit desktop UX design and independent source/capture review. The lead
owns production implementation. No device commands or physical focus claims are
made by this review.

## Design implementation

The new `LauncherUI.swift` composition follows `LAUNCHER_UX_DESIGN.md`: a persistent
240-point, independently scrollable setup sidebar and a flexible Applications /
selected-app / Sessions workspace. It keeps existing controller controls and
actions, uses native controls and semantic colors, and removes the fixed
850-point session document width. Session cards separate title/state, device /
backend and recovery actions.

Independent visual inspection of refreshed Aqua default/minimum captures and the
Dark Aqua minimum scrolled capture confirms readable hierarchy, opaque semantic
backgrounds, wrapped sidebar labels and reachable recovery actions. The sidebar
scrolls to Spotlight setup instead of compressing its controls. The abbreviated
visible `Add Device Apps…` button is a reasonable narrow-sidebar adaptation;
its full Add All meaning remains in the accessibility label and tooltip.

The executable QA fixture contains 1000 apps and 40 retained sessions, exercises
four size/appearance combinations, checks existing target/action wiring and
independent scroll behavior, and reports passing. These fixtures establish
layout and presentation behavior; they do not establish real Android launch or
foreground keyboard delivery.

## Findings and remediation

1. **Resolved in source:** `canOnboardSelectedDevice` gates both the action and
   final presentation enablement by authorized/ready device, matching complete
   nonempty catalog, feature preference and admission exclusions. Progress and
   maintenance callbacks refresh presentation last.
2. **Resolved in source:** scoped `appsError`, `loadingAppsSerial` and generation
   tokens distinguish failed app discovery from loading and reject late device
   results. Error presentation retains an explicit Refresh route.
3. **Resolved in source:** Find App menu validation and action guards keep the
   shortcut in launcher/no-session context. Explicit search/settings navigation
   refreshes the app catalog immediately.
4. **Resolved in source:** a session-presentation fingerprint reuses unchanged
   cards on repeated polls, preserving focused controls and scroll position. The
   fingerprint includes state/error/retry and real focus availability, including
   owned fallback Player availability.
5. **Resolved in source:** all active/canceled selection tasks are retained by
   identity until completion and canceled/drained during shutdown. The latest
   task reference no longer loses its predecessors, and loading checks
   cancellation before admission and every publication boundary. The subprocess
   runner's existing bounded work is unchanged.

The session count now says `N sessions`, accurately including retained
failed/stopped intents. Package cells also align vertically with app labels.

**Source and visual design review accepted.** No remaining macOS source blocker
was found after these corrections. Final installed verification below remains
required before release approval.

## Installed evidence

The installed 0.1.6 build 11 main executable was independently checked:
`55fe5f6725dfe5bfbf0c3d9f77aaae93899aecbb54c34f79165e01b97e04811f`.
`codesign --verify --deep --strict` succeeds. All 47 production/documentation
hashes in `release-inputs.json` match the current inputs; packaged runtime
dependencies and isolated tools are recorded in `installed/package.json`.
Signing is ad hoc; this review makes no notarization claim.

`installed/gui/result.json` records executed public AppKit actions in that
unmodified installed binary with actual Android transport. Independent inspection
of the minimum launcher, two-session workspace and decoded probe PNGs confirms
the final composition renders correctly with real Android icons and content.
The result and underlying receipts establish:

- Authorized emulator discovery, 16 real launchable apps and no-match search
  correctly disabling launch.
- Two independent native windows. Android logs bind `LauncherFirst` and
  `LauncherSecond` text plus clicks to displays 15 and 16 respectively.
- A resized native stream at 960×656, a fresh display-15 click, and independent
  session close.
- Actual scrcpy selection/launch while another native session remains alive.
- Sidebar 16-app onboarding cancellation/resumption and the real details action;
  accepted catalog history remains intact.
- Actual Create Mac App target/action producing an independently signed wrapper
  with an Android icon.
- Graceful app exit with exact display/ADB forward/reverse baselines restored.

The shipping-source five-case wrapper loading regression is also passing under
`regression/launch-ux/results.json`: immediate branded preview, decoder/input
fence, intentional minimize, both close cancellation boundaries and prolonged
blank-video reveal/recovery.

## Final verdict

**Approved for the exact installed 0.1.6 build 11 candidate above.** No remaining
blocking macOS UX/source issue was found. The installed-wrapper regression under
`installed/wrapper-loading/result.json` now passes all five cases: three native
launches and two scrcpy launches, including real Launch Services invocation.
Branded loading windows appear in about 0.23–0.29 seconds, the launcher is never
observed visible, native window identities remain stable, the 420×560-point
content size survives native/fallback relaunches, and every case exits 0 with
resource baselines restored. Independent visual inspection of
`installed/wrapper-loading/5-native/live-stable.png` confirms real Android probe
content on display 29 with ticks 7. This binds wrapper regression acceptance to
0.1.6 rather than relying on historical 0.1.5 evidence.

Public AppKit action instrumentation and view captures do not establish physical
Spotlight interaction, OS foreground focus, keyboard event delivery through the
locked desktop, Cmd+Tab interaction or physical Pixel behavior. Those limitations
remain explicit; real emulator video/input and exact session/resource evidence
are separate from them.
