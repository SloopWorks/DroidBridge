# Unified DroidBridge desktop design

Design review: 2026-11-04. Scope: the Mac launcher and Mac Companion management experience. Android apps continue to execute on Android and open in independent native app windows or the existing scrcpy fallback. Generated Mac wrappers retain independent application identities and lifetimes.

This is a source-informed design and acceptance specification, not a claim of complete visual or accessibility acceptance. Native UI inspection and emulator execution are recorded separately by the coordinating implementation/QA task. Existing workspace changes were preserved. This review edited only this document. The source findings describe the initial two-window baseline; implementation and fixture checkpoints appear below and supersede those findings only to the extent their evidence supports.

## Decision

Provide one main management window, one selected-device context, one application catalog and one sessions surface. Use a native navigation sidebar for Apps, Sessions, Handoff, Notifications and Devices. Devices contains connection/trust and device-specific Audio, Screen and Performance sections; place general defaults in a separate Settings window available with Command-Comma. Keep diagnostics and release information accessible from Help rather than as primary tasks.

The task names and exact grouping below are design recommendations. Apple does not prescribe these five destinations. The required outcome is that users do not have to switch between two management windows to operate the same device, application or session.

## Source review and duplication

Reviewed `AGENTS.md`, `ARCHITECTURE.md`, `Sources/DroidBridge/Launcher.swift`, `LauncherUI.swift`, `CompanionWindow.swift`, `CompanionLauncherIntegration.swift`, `CompanionDesktopAdapter.swift` and `main.swift`.

| Existing surface | Existing behavior | Unified location and disposition |
| --- | --- | --- |
| Launcher device popup; Companion phone popup; Companion setup ADB popup | Three independently selected contexts; Companion phone UUID and ADB serial have different authority | One selected-device context, with explicit transport/trust states. Setup can choose a transport within a sheet; it cannot silently change the active target |
| Launcher Applications; Companion Apps | Separate search/table/icon/selection presentations; launch vs broker Open on Mac; Companion favorites and Spotlight policy | One Apps table with launch, favorite and Spotlight eligibility; one selection and search |
| Launcher Sessions; Companion Sessions | Local BridgeSession controls vs cross-process broker wrapper dashboard | One Sessions list, deduplicated by exact session/owner identity; preserve owner-specific command routing |
| Launcher rendering sidebar; Companion Performance | New-window backend, decoration/reconnect defaults vs phone profile | General defaults in Settings; device-specific performance in Devices > Performance; explain new-window scope |
| Launcher AUDIO and phone-screen checkbox | Device-wide route and physical-screen intent | Devices > Audio / Screen, with compact current-state summary in the shared header and existing keyboard/menu access |
| Launcher Spotlight group; Companion export checkboxes | Global enablement, explicit bulk onboarding, per-phone/per-app selection and wrapper-materialization outcomes | Global enablement in Settings; Add Device Apps and per-app eligibility in Apps; one visible operation progress/result |
| Companion Connection | Install/open Android companion, connect, pair, wireless ADB setup, retry/disconnect, forget, pending completion, trusted Macs, host registration | Devices > Connection, with progressive setup and separately scoped destructive actions |
| Companion Handoff | Explicit text/link/clipboard/file send, inbox, retry confirmation and reveal saved file | Handoff destination; preserve every operation and pinned recipient |
| Companion Notifications | Optional mirroring, permission check, app allowlist, advanced package input, in-app items, reply/dismiss | Notifications destination; configure permissions/filters in a subordinate options area |
| Launcher Diagnostics; Companion Diagnostics | Session logs and local capability/connection observations/export | Help > Diagnostics, with clear Session and Connection report scopes |
| Companion Get Mac App | Official release lookup, validated installer/link and release guidance | Help > Releases and Downloads; preserve manual refresh, metadata, download and copy-link actions |
| Existing Settings menu | `showLauncherSettings()` raises launcher, scrolls to backend, focuses it and forces device/app refresh | Dedicated Settings window; opening it must not trigger device discovery, catalog mutation or phone actions |

`CompanionCatalogSync` already shares catalog work; two visible app lists are presentation duplication, not evidence that every network read is duplicated. Do not replace that synchronizer with a second client. `CompanionDesktopAdapter` is the broker boundary and continues to own IPC, receipts and host registration.

## Main window

Use an AppKit split view with a resizable/collapsible sidebar and standard titlebar/toolbar. Retain system window controls, focus rings, selection treatment, fonts and semantic colors. Start near 1040 by 720 points; treat this as a design target to validate, not an Apple requirement. Verify every destination down to the implementation's declared minimum size. Sidebar rows need stable selection and accessibility roles; a horizontal row of eight equal-width buttons is unnecessary in this structure.

The shared header shows the selected device name and two independent status facts: Android debugging readiness and Companion connection/trust. Example: `Pixel · Android ready · Companion not paired`. A single device chooser includes authorized USB/emulator entries and known offline paired phones. Distinguish `Authorization required`, `Starting Android`, `Offline`, `Pairing pending` and `Companion unavailable`; do not collapse these into one green Connected indicator.

The header also exposes Refresh and a Devices shortcut. Use the title of the current destination as the window title and put device identity in an adjacent subtitle or context control. This avoids repeating the app name as the sole window title. Keep critical errors and pending setup actions in the visible content near the affected control; the footer can show a brief status summary and cannot be the only place to recover.

Default to Apps when a usable device exists. With no usable device, show the same navigation and an Apps empty state with Connect Device, which routes to Devices. Keep unavailable destinations visible with an explanation and appropriate setup action. Pairing must not become a prerequisite for existing authorized ADB app launches.

### Apps

- One searchable list contains app icon/name, optional package detail, favorite state, Spotlight selection and an honest wrapper status. Search supports labels and packages; retain selection and keyboard focus across unchanged polling.
- The primary action is Open App, available through selection, double-click, Return in search/table and the menu. Merge Companion Open on Mac into this command path; do not display a competing second launch button or execute both paths.
- Secondary actions are Create / Update Mac App, Add Device Apps, favorite, and Retry Wrapper when applicable. The single-app portable wrapper action and managed Spotlight eligibility remain distinct behaviors with clear labels.
- Spotlight selection is saved intent. Show Pending, Ready, Disabled Globally, Failed or Available After Close as supported by actual receipts. A checked box alone does not prove a wrapper exists or can launch.
- Put bulk progress, Cancel and Details beside the operation. Completed wrappers persist when the batch is cancelled. Turning off global Spotlight availability preserves history and continues to deny stale wrapper admission.
- ADB-only catalog rows can launch with current readiness. Companion-only export/favorite controls appear only with their required identity/capability; show an explanatory disabled state when unavailable. Do not invent successful policy writes for unpaired phones.

### Sessions

Show all known app windows for the selected device, including independent wrappers. Each row has app, device, state and owner/backend details, followed by Show Window, Close Window, and error recovery when supported. Restore Previous Sessions remains explicit. Session logs remain available as a secondary command.

Merge a local session and its broker registration only when the exact session identifier and owner process-start/generation identity match. Matching by package would incorrectly merge two valid windows of the same app. Unknown or stale remote registrations must not be turned into new launch or close commands. If wrapper focus is unsupported, disable Show Window with an explanation; do not fabricate window ownership.

Use one visible close term while preserving backend semantics. Closing an Android virtual-display session can destroy that display's tasks; forgetting Companion trust is a different action. Failed startup retains its reason plus Retry and the supported alternate backend. No management navigation changes close Android app windows.

### Handoff

Separate Send and Received content within one destination, with incoming items and current transfer progress visible. Preserve Send Text, Send Web Link, Send Clipboard, Send File, Cancel Transfer, Refresh Inbox, Clear Inbox, Retry File Confirmation and Reveal Saved File. Received content offers explicit Copy, Save or Open Link actions and is never automatically opened.

The compose target is an explicit captured recipient. Display `To: <device>` beside the send controls. If the selected device changes during composition/transfer, retain the original target visibly or require explicit retargeting; never silently send content to the newly selected device. Keep saved destination available for Finder reveal independently of a pending completion acknowledgment. Transfer limits and actionable failures belong beside the transfer; checksum algorithm and protocol detail can be in Details.

### Notifications

Show current in-app phone notifications and supported explicit reply/dismiss actions. Put Configure Notifications within this task: mirror toggle, Android access status, Mac permission status, per-app allowlist and advanced package input. Prefer the app picker for ordinary use. Make the meaning of an empty selection explicit because it currently permits all notifications allowed by Android and phone privacy policy.

Pairing, Android notification access, app filters and macOS delivery permission are separate gates. A denied Mac alert permission still permits the supported in-app list. Requests for OS permission follow explicit user intent. Bind pending edits and permission callbacks to the current phone/trust and window lifetime. Selecting a different device cannot publish the prior device's edits to it.

### Devices

Group device management into Connection, Audio, Screen and Performance, keeping the selected phone visible. Connection presents two setup steps rather than one wall of permissions text:

1. Android debugging: authorize USB or set up authenticated Wireless Debugging. Show transport and readiness. Offer Install / Update Android Companion and Open Android Companion when an authorized transport is ready.
2. Companion trust: connect the phone service, scan/import/paste its complete pairing link, compare code, approve on the phone, and finish locally. Show pending expiry and Finish Approved Pairing when applicable.

Offer Connect/Retry only as appropriate to state, rather than simultaneous synonyms. Expose Disconnect Companion and Forget Pairing separately. Disconnect explains that app windows continue. Forget names the exact phone, explains the local/phone trust distinction and retained wrappers/settings, and requires the existing destructive confirmation. Trusted Macs and revoke remain available for the selected paired phone. Show Mac Launch Registration status with explicit Retry Registration when needed.

Wireless setup and pairing are short-lived sheets or task windows, not alternate main dashboards. Their callbacks must bind the original target and survive neither cancellation nor changed trust. Credentials never become a visible account token field.


### Offline paired devices and transport selection

The shared chooser must combine ADB-discovered transports and saved Companion devices without pretending the two inventories have identical identity or readiness. Keep known paired phones selectable while offline so users can review local trust state, saved intent and failure information. Offline selection cannot imply a live catalog, a current notification projection or permission to execute a command. Make disabled launch/send controls explain that the phone must reconnect.

An unpaired authorized ADB transport remains selectable and launchable without Companion. When a verified phone has USB and wireless aliases, show one canonical phone with the selected live transport in Devices; do not allow a cosmetic chooser change to bypass the existing canonical lease held by running sessions. Display why an alias switch is unavailable until exact owned cleanup finishes. A stale serial match or friendly name cannot merge identities.

Tradeoff: a combined chooser needs more status text than separate lists, but avoids forcing users to reconcile two independently selected targets. A live-ADB-only chooser is simpler yet hides offline trust management; it is acceptable only if Devices also offers an explicit known-paired-phone list that retains the same shared context and cannot silently retarget actions. An offline broker phone with no authorized transport can still expose supported local Forget actions; live trust-list reads, remote revoke, profile application and handoff require their actual capabilities.

## Configuration and Settings

Keep frequent device operations contextual, and persistent global defaults separate. Devices is the persistent destination for device-scoped options. A compact header shortcut can route directly to its Audio, Screen or Performance section without duplicating editable controls. The identity of the affected phone must remain visible throughout.

| Scope | Controls | Effect and wording |
| --- | --- | --- |
| Settings > General | Reconnect interrupted sessions automatically | Preserve existing intent semantics; no silent migration to a different persistence scope |
| Settings > App Windows | Native AppKit / scrcpy fallback; Show Android system decorations | New app windows only; explain Android software keyboard remains hidden |
| Settings > Spotlight | Enable device apps in Spotlight; availability/helper information | Global enablement; bulk Add Device Apps remains in Apps |
| Devices > Audio | Mac, Phone, Mac + Phone; status; Retry Audio; Use Phone | Device-wide, including apps outside DroidBridge; Mac route silences phone playback; capture limitations remain truthful |
| Devices > Screen | Keep phone screen off during Mac sessions; Turn Screen Off; Turn Screen On | Selected physical display, persistent opt-in intent; closing the last app does not automatically wake the phone |
| Devices > Performance | Balanced 30 fps, Responsive up to 60 fps, Battery 15 fps; apply; observed battery/thermal/network | Companion profile affects new app windows and bounded status/asset work; no promise of achieved frame rate or changed live windows |
| Notifications > Configure | Mirror toggle, permissions, allowed apps | Phone/trust-specific task controls rather than a second global preferences copy |
| Devices > Trusted Macs | Trust review, revoke, Forget Local Pairing | Local access control, separate from Android debugging authorization |

A compact three-pane Settings window is sufficient. Use a stable noncustomizable pane toolbar, remember its last pane, title the selected pane, and disable minimize/zoom as Apple's Settings guidance recommends. Keep exact values backed by the existing preferences/owner APIs; a UI redesign must not create parallel defaults files. Where current preference persistence is session-local, retain that scope unless an intentional migration is implemented and verified.

Do not add a custom appearance selector, global keyboard accommodation, telemetry switch or network setting unless a real product capability requires it. Respect system appearance and accessibility settings. Debug-only telemetry consent is development configuration and must not imply a release collector exists.

## Account and product information

Do not add Account, Sign In, License, Subscription or an empty profile page. The reviewed desktop has local pairing/trust and host registration, with no account or licensing flow. Pairing a Mac is not signing into a cloud account. Label the existing domain Trusted Macs / Paired Devices and store credentials in the existing broker/Keychain boundary.

About shows installed version/build and verified runtime/support information. Help contains Getting Started, Diagnostics, Releases and Downloads, Privacy, Licenses and Support using existing resources. Releases and Downloads preserves the validated version, architecture, minimum OS, checksum, official page, refresh, Download Installer and Copy Download Link. Missing/invalid release metadata keeps download disabled. Neither certificate installation nor a successful download proves notarization or installation acceptance.

If an account backend is added later, introduce Account only with actual identity, sign-out, deletion/recovery and privacy semantics. Do not reserve a nonfunctional destination now.

## Menus and keyboard behavior

Keep normal App, Edit, View, app-specific, Window and Help ordering. Add View commands for main destinations and show/hide sidebar. App > Settings uses Command-Comma; Window > DroidBridge (or Show Main Window) reopens the one management window. Remove Companion as an alternate top-level management window command; a compatibility selector can navigate to Devices.

Expose primary and secondary task commands through contextual app menus with shared validation: open, create/update wrapper, bulk setup, restore, focus/close session, share, refresh, device screen/audio and diagnostics. Retain existing Cmd+F scoping so Android app text/search shortcuts are not intercepted. A menu equivalent and an on-screen control may share an action; this is expected macOS accessibility, not unwanted product duplication.

Close, Minimize, Zoom and full-screen commands should follow AppKit conventions. Closing the main management window keeps already-running Android app windows and independent wrapper processes intact according to existing lifetime contracts; Quit awaits exact owned cleanup. Wrapper menus must not instantiate a launcher that is supposed to remain hidden merely to open shared Settings.

## Apple guidance: findings versus preferences

Official sources were browsed on 2026-11-04. Apple pages expose a linked Markdown version; the web reader could not decode that content type, so the Markdown was also read directly using system `curl` with TLS verification enabled. These sources establish recommendations, not a certification or exhaustive conformance test.

| Finding | Evidence and classification | Design response |
| --- | --- | --- |
| Settings command opens the main launcher rather than a settings window | Source-confirmed departure from Apple's explicit macOS Settings-window convention; `main.swift` routes to `showLauncherSettings()` | Real Settings window, Cmd+, and no forced discovery |
| No View menu; About lacks its own separator group | Source-confirmed departures from explicit menu-bar recommendations in `main.swift` | Add View and restore standard menu grouping |
| Many important app commands have no menu equivalent | Source-confirmed discoverability/accessibility departure: current Apps menu offers only Find App while launch/wrapper/bulk/handoff commands live in content | Shared validated command model exposed in menus |
| Main window titled only DroidBridge; secondary management window titled DroidBridge Companion | Source-confirmed mismatch with toolbar guidance preferring content/location titles | Destination title plus device context |
| Launcher sidebar primarily contains rendering/audio/Spotlight controls; Companion uses eight navigation buttons | IA preference/risk, not a blanket HIG prohibition | Task sidebar and scoped settings reduce scanning and duplicated selection |
| Detailed protocol/runtime wording in ordinary setup | Product language concern, not a provable HIG violation by itself | Progressive help/details; retain consent-critical distinctions |
| Fixed widths/heights and small secondary labels | Potential resizing/legibility issue requiring executed observation | Verify minimum sizes, scaling and Full Keyboard Access; do not declare clipping from source alone |
| Custom NSView cards/NSVisualEffectView/sidebar colors | Neither proves compliance nor proves violation | Check real focus/selection/contrast in light, dark, increased contrast and reduced transparency |
| No Account section | Appropriate to current capability; HIG does not require an account | Keep trust management visible and omit invented account UI |

Sources and their application:

- [Apple HIG: Settings](https://developer.apple.com/design/human-interface-guidelines/settings): separate macOS Settings window, standard shortcut, stable panes and task-specific options in context. This informs configuration scope and Settings behavior.
- [Apple HIG: Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars): shallow hierarchy, concise groups, standard hide/show behavior and resizing. This informs task navigation; it does not mandate DroidBridge's categories.
- [Apple HIG: Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars): prioritize main tasks, avoid crowding, provide useful content titles, and expose toolbar commands in menus. This informs the shared device header and command placement.
- [Apple HIG: The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar): standard ordering, stable command availability, keyboard equivalents, View/Window menus and discoverable app-specific commands. This informs menu completeness.
- [Apple HIG: Windows](https://developer.apple.com/design/human-interface-guidelines/windows): use system windows, adapt to resizing and open additional windows when the task benefits. Separate Android app windows remain justified; duplicated management dashboards do not add equivalent task value.
- [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) and [Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards): audit navigation, legibility and keyboard support. Source structure alone cannot establish successful assistive-technology behavior.
- [Apple: Adding a settings interface to your app](https://developer.apple.com/documentation/foundation/adding-a-settings-interface-to-your-app): implementation guidance also describes macOS settings in a separate menu-accessible window.

## Integration constraints

1. Introduce a presentation-level navigation/device model without weakening Core/Streaming ownership. Verified phone installation UUID is canonical only after authentication; an unpaired ADB device remains serial-scoped. Resolve aliases using authenticated adapter facts, never matching friendly names.
2. Reuse controller-owned controls/selectors or extract reusable child controllers. Do not embed an NSWindow's content while leaving its old visible management shell and separate selection logic active.
3. One shared app snapshot feeds search, favorites, launch readiness, notification app picker and Spotlight status. Keep `CompanionCatalogSync` visibility demands accurate for the embedded surface so hidden destinations stop catalog work as designed.
4. Consolidate `CompanionWindowController` show/close, inbox polling, notification presentation and shutdown lifecycle around actual content visibility. A child view embedded in a visible main window cannot rely on an abandoned `window.isVisible` check. Background command execution and current notification behavior must not accidentally stop just because a destination is not selected.
5. Route actions through existing owner APIs and receipt logic. Present accepted/applied/rejected/unknown distinctly; do not make a second UI path reissue an uncertain command. Fence target, trust, selection and task generations around awaits.
6. Preserve late-callback fences, exact forward/process/display cleanup, launch readiness and I/O off MainActor. UI composition cannot perform blocking ADB or catalog admission.
7. Preserve wrapper startup independence, native decoded-video requirement, new-window configuration semantics and Android API boundaries. No shared ADB-server kill, emulator restart or mutation of the user's `emulator-5554` is part of this redesign.

## Executable acceptance criteria

Items below require their own recorded executable evidence. The fixture checkpoint below supplies limited presentation/routing evidence, not a blanket pass for this list. Compilation and assertions alone do not pass visual/functional acceptance.

1. Launch the packaged app from a copy outside the build directory. Exactly one main management window appears; old Companion entry points route within it. Record version, path, command/output and screenshots under `verification/`.
2. On dedicated `DroidBridge_API35` at port 5580, launch the deterministic app from the unified catalog and show changing decoded Android video in its own native NSView. Exercise input/resize/close and exact cleanup. Leave `emulator-5554` untouched.
3. Demonstrate one selected device across Apps, Sessions, Handoff, Notifications, Devices. Exercise offline, unauthorized, booting, paired, unpaired and expired/pending pairing states. Never infer identity from a matching label.
4. Demonstrate one catalog with launch, favorites, per-app Spotlight selection, portable wrapper creation and explicit bulk setup. Record pending/failure/materialization results truthfully and verify unchanged polling retains selection/focus.
5. Launch a separate wrapper, observe it once in Sessions, and close only its exact session through the existing owner route. Two sessions of the same package remain separate. Management navigation and closing the main window preserve independent sessions.
6. Verify native/fallback settings, decorations, reconnect, global Spotlight enablement and device profile retain existing semantics across the applicable process/relaunch boundaries. Opening Settings performs no new phone operation. Cmd+, opens one persistent settings window; close/reopen restores the last pane.
7. Exercise audio route/retry and screen Off/On using established emulator evidence limits. Do not infer physical audibility or physical-phone power success. Pixel 10 Pro acceptance remains deferred to its owner.
8. Pair through the actual installed broker/phone flow; exercise disconnect, pending completion, trust review and forget/re-pair. Confirm trust revocation cannot broaden ADB authority or revive stale callbacks.
9. Send text, URL, clipboard and file; receive/copy/save/open explicitly; cancel and retry confirmations; reveal the saved file. Change device context during an in-flight operation and verify the recipient remains the captured one.
10. Exercise notification opt-in, denied Mac permission, filter edits, trust/device switch and supported reply/dismiss. Confirm no cross-phone disclosure or stale action.
11. Verify diagnostics/report export and validated release download/link states remain reachable. Do not claim release signing/notarization based on UI labels.
12. Inspect every destination and Settings at declared minimum size and larger sizes, light/dark appearance, Increase Contrast and Reduce Transparency. Exercise keyboard-only navigation, visible focus, command validation, VoiceOver names/values/selected state and meaningful disabled explanations. Record any untested configuration rather than asserting HIG conformance.

## Implementation and fixture checkpoint, 2026-11-04

The coordinating implementation has replaced the management shell with Apps, Sessions, Handoff, Notifications and Devices navigation; embedded the Companion task pages; added separate Settings; and retained device-specific Audio, Screen, Performance and bulk wrapper management. Early source review found unattached bulk/status controls, route reentrancy, missing export retry, lost favorite ordering and inconsistent session scope. These were sent to the coordinator, who reports fixes. That report is implementation progress, not independent installed-flow acceptance.

Read [fixture results](../verification/unified-desktop/fixture/results.json) and inspected 22 representative local captures spanning every main destination, the declared 920×640 minimum, 1160×780, both Aqua appearances, and all Settings panes. The fixture reports `passed: true`, one workspace host, one Settings window, retained focus/drafts, and captured receipt-routing checks for selected-phone handoff, exact-session stop, device profile, notification trust, diagnostics and delivery metadata. Its anonymous NSXPC peer is a fixture, not an Android device. The fixture explicitly excludes physical input, Android video, OS notifications, Spotlight, signing and installer acceptance.

Visual observations from that initial capture set and targeted review of the refreshed fixture after fixes:

| Observation | Evidence and disposition |
| --- | --- |
| Apps layout at minimum size | Visible list, search, selected-app actions and footer fit in both light and dark captures; no obvious content overlap in those views. This does not establish keyboard or VoiceOver operability |
| Contradictory setup prompt | Initial authenticated-connected captures showed the instruction to choose/authorize/connect/pair. Refreshed minimum-size Handoff, Notifications and Sessions captures no longer show it; this fixture-level issue is resolved |
| Empty local Sessions allocation | Initial minimum-size capture pushed the independent wrapper's Refresh/Stop below the viewport. Refreshed Aqua 920×640 Sessions visibly includes both Refresh Sessions and the exact fixture wrapper's Stop row after shrinking the empty local area; this fixture-level issue is resolved |
| Handoff editor affordance | Initial editor blended into the background. Refreshed Dark Aqua 920×640 capture shows an explicit Text or web link heading and visible editor boundary; this fixture-level issue is resolved |
| Scrollable lower task content | Performance, trust, notification-filter and incoming-item controls can lie below the initial viewport. This alone is not clipping; scrolling and keyboard reachability must be demonstrated |
| Sidebar and Settings bitmap omissions | Sidebar material appears blank white in fixture captures, and Settings fixture captures omit backgrounds/button text. Actual native Apps and all three Settings screenshots below render these elements normally, resolving these omissions as fixture-capture limitations for the inspected default-light configurations |

The refreshed fixture results remain `passed: true` with 32 layout cases (results SHA-256 `9395f4a89f3e6af59385890486c1f384ac613e6b4267b9ea3064b6191d277031`). These bitmap captures omit the main toolbar/titlebar as well, so they cannot verify device-picker discoverability, sidebar selection, Settings pane navigation or actual macOS window controls. No measured contrast, Increase Contrast, Reduce Transparency, VoiceOver or Full Keyboard Access pass is inferred from them. Installed native UI evidence and actual emulator integration remain separate gates; Pixel 10 Pro verification remains deferred to its owner.

### Actual native Apps screenshot

Independently inspected [native Apps screenshot](../verification/desktop-unification/native-apps.png), captured by the coordinator through computer control from the installed app in the current default light system appearance. All five sidebar destinations and Settings are visible and legible; Apps has a clear selected treatment. The native toolbar visibly contains the sidebar toggle, selected Android device, Refresh and Device Settings controls. The global header distinguishes Android readiness from the not-paired Companion state. Search has a visible focus ring, and the app table plus launch/wrapper actions fit without overlap in this captured window. This resolves the blank-sidebar omission in the fixture images and supplies actual visual evidence for this Apps/sidebar/toolbar configuration.

The coordinator also reports native accessibility-tree entries for the five sidebar rows, Settings and Android device chooser. This design review did not independently operate that accessibility tree or certify keyboard/VoiceOver behavior. One screenshot does not establish dark-mode rendering, every destination or the full installed integration flow. The additional evidence below expands the accepted scope without treating a screenshot as proof of every interaction.

### Additional actual native review

Independently inspected the coordinator's actual screenshots of [General](../verification/desktop-unification/native-settings-general.png), [Integration](../verification/desktop-unification/native-settings-integration.png), [About](../verification/desktop-unification/native-settings-about.png), [Handoff](../verification/desktop-unification/native-handoff.png), [Android input](../verification/desktop-unification/native-input.png) and [minimum-size Sessions](../verification/desktop-unification/native-sessions-minimum.png).

All three Settings panes render legible text and controls, show the active pane, and use a pane-specific title. The About pane identifies version 0.2.0 build 20 and explains local trust without an empty Account destination. Handoff shows the editor heading/boundary, explicit send actions, received-file Save and saved-file Reveal controls. Its visible transfer result says size/hash verification and phone confirmation completed without automatically opening the content. The minimum Sessions screenshot visibly preserves two separate same-app native sessions, both with Focus/Log/Close, and shows the nested scroller reaching Refresh Sessions. No new overlap or clipped-label defect was found in these captured default-light configurations. Items below a scroll viewport remain subject to actual scrolling, rather than being treated as layout failures.

The Android input screenshot contains decoded test-app content for Display 10, ticks 98, Clicks 1 and entered text `unifiedreview`. This is consistent with the coordinator's independently operated native-input test; the screenshot alone does not establish time-varying frames or input causality.

Coordinator-reported actual computer-control checks include Command-Comma and restored About pane; Command-1/2/F and Return launch; pointer counter increment and typed text on Display 10; Android-window shortcut scoping; exact test-session close; Command-Control-S sidebar toggle; closing the management window while retaining two native Android windows; Command-L reopening Sessions with both retained; and minimum-size drag clamping plus nested-scroll reachability. The coordinator also reports a manually continued 2,097,152-byte received file saved with matching hash, phone completion confirmation and Finder selection. These are reported executed checks, separate from this design review's screenshot inspection.

The original installed automation result remains false: the observer reported navigation success while the main window was not key. Manual computer-control continuation succeeded for the checks above; do not rewrite the original scripted result as a passing unattended run. No product failure was observed from that harness stop. Native dark appearance, measured contrast, Increase Contrast, Reduce Transparency and comprehensive VoiceOver/Full Keyboard Access remain outside this checkpoint. No universal HIG conformance, physical Pixel verification, signing or notarization acceptance is claimed.
