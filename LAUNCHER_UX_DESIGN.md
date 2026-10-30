# DroidBridge launcher redesign

Status: implementation specification agreed with the lead engineer. This file
describes the launcher; it does not change session, transport or wrapper policy.

## Product hierarchy

The launcher's first job is opening an Android app. Device setup, Spotlight
preparation and session recovery remain available without competing with that
primary task. Use two persistent panes, rather than tabs that hide active work.

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ Standard macOS titlebar: DroidBridge                     window controls │
├───────────────────┬─────────────────────────────────────────────────────┤
│ DroidBridge       │ Applications                       app/device count │
│ Android → Mac     │ Search apps or package names                        │
│                   │ ┌─────────────────────────────────────────────────┐ │
│ DEVICE            │ │ icon  App name                  Package         │ │
│ Device picker     │ │ icon  App name                  Package         │ │
│ Connection status │ │ … native, scrollable application table         │ │
│ Refresh           │ └─────────────────────────────────────────────────┘ │
│                   │ Selected app name + package  [Launch App] [Mac App] │
│ RENDERING         │                                                     │
│ Backend picker    │ Sessions             Restore Previous / Diagnostics │
│ Display settings  │ ┌─────────────────────────────────────────────────┐ │
│ Phone setting     │ │ App · state                  device / backend  │ │
│                   │ │ Focus · Retry / Other backend · Log · Close     │ │
│ SPOTLIGHT         │ │ … separately scrollable session cards          │ │
│ Feature checkbox  │ └─────────────────────────────────────────────────┘ │
│ Add all / Cancel  │ Reconnect interrupted sessions automatically        │
│ Progress / Details│                                                     │
│                   │ Current status / actionable connection explanation  │
└───────────────────┴─────────────────────────────────────────────────────┘
```

The sketch abbreviates action text. Retain existing exact button labels and
selectors in production for documentation, accessibility and regression
compatibility. Do not remove capabilities to fit the sketch.

## Window and layout

- Default content size: **1160 × 780 points**. Minimum content size: **920 × 640**.
  Preserve the standard titlebar, traffic lights, resize, minimize and window
  menu. A unified AppKit header is appropriate; no custom window chrome.
- Sidebar: **240 points**, independently vertically scrollable. A divider
  separates it from the flexible main workspace. Sidebar material may use
  `NSVisualEffectView` with the public `.sidebar` material.
- Sidebar inner padding: 16 points. Main workspace padding: 20 points at default
  size, 16 points at minimum size. Prefer 8/12/16-point spacing consistently.
- Main workspace is one vertical layout. The app table receives surplus height;
  the session scroll area is bounded and remains reachable. At minimum height,
  target about 150–170 points for the app table and 90–110 for the session list,
  with a compact 50–65-point app selection strip. Avoid fixed large minimums that
  make the aggregate exceed the minimum window height.
- The sidebar must scroll rather than compress checkboxes, progress or cancel
  controls. Multiline checkbox labels require a deliberately wrapping cell and
  enough row height; do not rely on an ordinary single-line button's intrinsic
  size to wrap a 200-point sidebar automatically.
- Use native scroll views with correctly constrained document widths. Session
  documents track the viewport width. Remove the old fixed 850-point session
  document width. Vertical session cards separate identity/state from controls,
  so failure controls fit at the minimum width without horizontal scrolling.
- Retain semantic AppKit colors for light/dark appearance and increased contrast.
  Main surface is `windowBackgroundColor`; tables/cards can use
  `controlBackgroundColor`. Use subtle separators or native `NSBox` cards, not
  decorative gradients or large shadows.

## Copy and controls

**Sidebar identity:** a small DroidBridge icon, `DroidBridge` at 19–20-point
semibold, and optional secondary `Android apps on your Mac` at 11 points. This
replaces the large marketing headline over the app list.

**Device:** keep `devicePicker` and `Refresh` in a connection group. Label it
`Device`. Show the selected model and an abbreviated/selectable serial where
practical; the popup retains full model/serial/state. Distinguish authorized,
booting, offline and unauthorized states through text, not just a colored dot.
Refresh remains available with no device. Never visually select a different
device behind a saved wrapper's explicit identity.

**Rendering:** keep `backendPicker` with its existing `Native AppKit` and
`scrcpy fallback` choices, plus `decorationsPreference` and
`phoneScreenPreference`. A concise secondary hint may read `Applies to new
sessions` for backend/decorations. Preserve the phone screen's per-device scope
and existing explanatory tooltip; do not imply it unlocks a device or is a global
setting. Explicit Phone menu On/Off actions remain available.

**Spotlight:** retain `bulkPreference`, `onboardingButton`, `onboardingCancel`,
`onboardingProgress`, `onboardingStatus`, and Onboarding Details. Show progress
with its captured device/summary, not the currently browsed device if selection
changes mid-operation. Cancel remains visible during admission and creation.
Turning the feature off continues to stop admission and availability according
to the existing backend policy. Details retains per-app failures; a completed
operation with failures must not be styled as unconditional success.

**Main heading:** `Applications` at about 23-point semibold. A secondary count
shows filtered/total apps and the selected device, using the existing discovered
data. Never represent unavailable discovery as a count of zero installed apps.

**Search:** full workspace width; retain `Search apps or package names`, the
accessible label and live matching by both name/package. Preserve selection by
package where it remains in the filtered set; otherwise select the first result.
No results: `No matching apps` and a suggestion to change or clear the search.
Disconnected/unavailable discovery: an honest connection/setup message instead.
Do not show a no-results message while the app list is still loading.

**App rows:** approximately 40–44 points high, with the real Android icon at
28–32 points, app label, and secondary package. Retain a separate package column
where space permits. Package truncation uses the middle, name truncation the end;
the detail strip and tooltips retain full identities. Asynchronous icon work
remains bounded and must not fetch every app merely to draw a count or heading.

**Selection strip:** small icon + selected app name and package on the left;
`Launch App` as the accent/default action and `Create / Update Mac App…` as the
secondary action. Keep the strip stable when selection clears: `Select an app`
with both actions disabled. App launch requires the selected ready device's app
list; Mac app creation also reflects existing creation/maintenance exclusion.
The strip is always visible, not dependent on opening a separate inspector.

**Sessions:** persistent heading and count, `Restore Previous Sessions` and
`Open Diagnostics` actions. Rows show app name, human-readable state, device and
backend. Active states and failed/disconnected intent remain distinct. Keep
Focus, Close, Log, Retry and alternate-backend actions with their current policy.
Focus must either target the correct native/owned Player window or be disabled;
a retained hidden fallback handoff host is not a usable focus target. Error
reason appears in the row or an accessible tooltip with Log available. Empty
state: `No active sessions. Launch an app to open its own Mac window.` Retain the
reconnect checkbox near this section, not buried in unrelated Spotlight setup.

**Status footer:** always visible, selectable 11–12-point wrapping text. Use at
most two or three lines in the layout and keep the full message in a tooltip or
diagnostics. Keep errors readable at normal contrast. Do not infer error/success
semantics by matching words inside localized free-form messages. Changing
background status must not steal focus or replace selected content.

## Interaction and accessibility

- Keep existing double-click to launch, arrow-key table selection, Enter/default
  Launch action, tab traversal and standard Edit/Window/Phone menus.
- Add `⌘F` to focus search after revealing the launcher. `⌘R` can refresh when
  the launcher is the relevant window. Preserve `⌘L` for Window → Launcher.
  Do not intercept Android app shortcuts in streaming windows.
- Use actual buttons, labels, checkbox/popup controls and `NSTableView`, with
  meaningful accessibility labels and visible focus. Keep names/packages
  accessible without requiring hover.
- Readiness/selection disables actions rather than silently ignoring them; any
  invalidation after an async boundary remains protected by existing code.
- Device refresh, progress, icon completion and session updates must not reset
  keyboard selection, scroll position or first responder unnecessarily.
- The launcher redesign must preserve the wrapper fast path: a Spotlight wrapper
  opens only its branded loading/video window until the user explicitly requests
  the launcher. Background rebuilding or a status change must not flash it.

## Implementation contract

The lead owns production code. Add a `LauncherUI.swift` AppKit extension/helper
views and reuse existing controller property instances. Keep streaming, session
admission, persistence, wrapper factory and onboarding policy intact.

| Existing owner | Presentation responsibility |
| --- | --- |
| `devicePicker`, `backendPicker` | Reparent into sidebar; preserve indices and selectors |
| `table`, `search`, `filtered` | App workspace; preserve icon callbacks and discovery fences |
| `selectedDevice`, `selectedApp` | Read-only derivation for selected-app details/actions |
| `sessionList`, `sessions`, `sessionStates` | Width-constrained session cards, all current recovery actions |
| preference and onboarding controls | Reparent once; preserve existing actions and captured work |
| `status` | Persistent footer; existing error sources continue writing here |

Add a **pure presentation refresh** method, e.g. `updateLauncherPresentation()`.
It may derive labels, icons, counts, button states and empty states from current
controller state. It must not start ADB work, create wrappers, stage icons or
admit sessions. Call it at app selection, search/filter completion, device/app
discovery completion, session changes and onboarding/creation state changes.
Use existing async update boundaries; do not add a new UI polling process.

Existing tests that inspect action labels or shipping `Launcher.swift` sources
must compile the new extension and preserve the real action wiring. Native
streaming-window behavior remains outside this layout refactor.

## Acceptance evidence

Store captures and executable results under `verification/launcher-redesign/`.

1. Shipping AppKit sources at default and minimum sizes; no unsatisfiable
   constraints, clipped actions or horizontal scrolling required for session
   recovery. Test a long app name/package and many sessions.
2. No device, unauthorized device, booting device, no search results and selected
   ready app states; action enablement agrees with actual admission policy.
3. Real emulator discovery/search/launch of two apps; session focus/close and
   retry/log/alternate-backend controls remain reachable.
4. Spotlight onboarding progress/cancel/details, existing preferences and phone
   controls preserve their behavior and device scope.
5. Search keyboard focus, selection preservation and standard menu targets;
   AppKit accessibility labels and geometry may be verified on a locked desktop.
6. Package/install/run the actual new candidate; regress wrapper launch UX so the
   branded loading path still avoids a launcher flash.

Physical OS foreground focus, a human's Spotlight interaction and Pixel behavior
must be described separately when the Mac is locked or no physical Pixel is
connected. Do not claim these from AppKit view captures alone.
