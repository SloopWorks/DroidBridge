# Independent launcher redesign QA plan

Status: the design contract is now a persistent two-pane workspace: independently scrolling 240-point device/options/Spotlight sidebar, applications and sessions in the detail pane, global status footer. Default content size 1160×780; minimum content size 920×640. Existing controller controls/actions remain compatible. No redesign acceptance is claimed by this plan.

## Preserved workflows

| Surface | Executable check | Evidence requirement |
| --- | --- | --- |
| Navigation | Reach Applications, Sessions and sidebar device/options/Spotlight controls, including scrolling to lower sidebar cards | Independent pane scroll positions, selections and actions stay coherent; no duplicate views or actions |
| Device and app browsing | Authorized/unauthorized/no devices; empty and 1000-app catalogs; label/package search; device change | Correct table rows, selection and readiness text; no stale app launch after device switch |
| Application launch | Native and fallback selected through the real picker and Launch button; double-click/Return path | Exact package, serial and backend reach the live session; two independent sessions with actual frames |
| Running | Starting/running/disconnected/failed/stopped fixtures, many rows, long names/errors | Native Focus/Close, Retry and backend fallback remain available with correct exact session ownership |
| Spotlight | Incomplete catalog rejection; actual Add All; immediate Cancel; long progress/error summary; Details sheet | Target/actions connected, cancellation bounded, accepted history preserved, no hidden running operation |
| Settings | Reconnect, decorations, per-device phone intent, bulk availability | Actual control actions preserve shared preference semantics; new-launch changes never rewrite existing session pins |
| Recovery | Restore Previous Sessions; reopen; device reconnect; failed retry | Intent not lost when readiness/admission refuses; no duplicate launch; late completion cannot revive closed session |
| Diagnostics and manual Mac app | Open Diagnostics, Create/Update wrapper, per-session Log | Actual target/actions invoke existing implementations; failures stay visible and actionable |
| Wrapper | Launch preview, main-launcher suppression, terminal failure/reopen | New layout does not expose the management launcher during a successful wrapper launch |

## Adversarial layout and accessibility

Capture the two-pane workspace, including the scrolled sidebar bottom, in Aqua and Dark Aqua at the actual default size and declared minimum size. Repeat with 200-character labels, 2000-character progress text, 1000 apps and 40 sessions. Measure visible control frames against their visible scroll viewport, not merely a potentially overflowing ancestor. Controls in scrollable pages may require scrolling; each essential action must be reachable at minimum size. Inspect content extent, horizontal clipping, mutually overlapping unrelated controls and any unsatisfiable Auto Layout diagnostics.

Inspect rendered PNGs independently. AppKit cache images on this locked host have historically omitted standard control paint: a geometry report is then evidence only of layout, not a visual-readability pass. Label missing visual evidence explicitly.

Verify meaningful accessibility labels/identifiers for sidebar, search, device, backend and icon-only actions. Check next-key-view traversal and initial search focus. A hidden page must not retain the window's Return default action, capture search keystrokes or allow a hidden Launch action while a different page is being used. Scrolling and resizing either pane must preserve device, backend, query, table selection and in-flight session/onboarding state. The persistent layout removes section-navigation state from the acceptance surface.

## Execution layers and ownership

1. No-device AppKit harness compiles shipping UI sources and uses deterministic session/catalog fixtures. It never opens a real ADB connection or changes accepted managed catalog history. Exact prior session-intent/preferences bytes and permissions must be restored if any action requires touching them.
2. Installed public AppKit action instrumentation verifies actual target/action paths. Instrumentation is explicitly labeled; it does not prove a physical mouse click, Cmd+Tab or foreground focus on the locked desktop.
3. Coordinated real emulator checks require decoded frames, exact display-bound input receipts and cleanup baselines for both backends. The lead owns emulator use and packaging until an explicit handoff. The user's emulator 5554 remains untouched.
4. Final approval binds the installed executable, copied release artifact and production inputs by hashes. Default unit skips and separately executed hardware tests are reported distinctly. Historical failed runs remain available with their cause and remediation.

## Existing source risks to recheck

- Return is currently bound directly to Launch App. Once pages exist, a single hidden default button can accidentally launch the old selection from Settings/Spotlight.
- `filterApps()` currently reselects row zero after every filter update; sidebar switching must not call it merely to rebuild a page and erase selection.
- `updateSessions()` currently fixes the stack width to 850 points and rebuilds all rows. That width must not cause clipping in a narrower detail pane; many sessions require document-view height and scrolling to remain correct.
- Device-specific phone state is loaded through polling; new navigation must not leave a checkbox displaying another device's intent.
- Status/errors must remain visible from each section. A global status mutation in an invisible page is insufficient failure feedback.
- Existing timer/task ownership and tracked shutdown must remain unchanged by view reconstruction. No extra polling loop should arise per section selection.
