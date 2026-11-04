# Android quick access

The Quick Settings actions tile, favorites widget, pinned app shortcuts,
foreground-service notification actions and selected-text sharing open
`QuickAccessActivity`. The connection tile toggles only the companion service
after unlock; its long press opens that foreground review surface. Android unlock
and explicit foreground review guard Mac effects. Caller-supplied extras never authorize an operation. No entry point
starts the service at boot or after process death (`START_NOT_STICKY`). Leaving
foreground dismisses an unsent action review; a late native confirmation callback
cannot submit after its Activity has paused or been destroyed. Service teardown
observes the exact worker-published listener before closing it.

The connection tile displays Off, Waiting for Mac or Connected. A running local
listener is not proof of a connected Mac: Connected requires the existing
15-second authenticated peer-state freshness gate. Tap toggles the companion
service after unlocking; the stop toast explains that independent app video
continues. Long press opens explicit foreground connection controls through
`ACTION_QS_TILE_PREFERENCES`; disconnect there asks for confirmation and explains
that independent ADB video/audio may continue. The actions tile opens favorites, per-Mac destination,
clipboard preview, audio destination, physical-display controls and exact-session
stop actions. Long operations and transfers remain in the full app.

`QuickAccess.pinApp(context, trustId, packageName, label)` requests a system-pinned
shortcut. Its stable ID hashes exact trust plus package; it never silently follows
a replacement Mac after revocation. It opens a foreground Open confirmation and
uses the existing immutable `phoneCommand` request/receipt channel. Unknown or
expired results tell users to inspect the Mac before repeating; no automatic
successor is submitted. `QuickAccess.pinWidget(context)` requests the system
widget picker flow. `QuickAccess.requestTile(context, operations)` opens Android's
system tile-add prompt. These APIs return/present availability, not installation
success; Android and the user control pinning.

The widget shows the last local snapshot with an update time and up to two
favorites from `companion-ui/favorites`. A live service refreshes it on changes;
Android periodic updates refresh an inactive service without starting it. A
widget can show historical state after abrupt process death; the timestamp is
intentional. Widget taps always open foreground review.

The ongoing notification shows connected/waiting status, window count and
confirmed transfer progress. Quick actions, Transfers and Disconnect open
activities directly (no notification trampoline). Transfer preparation uses an
indeterminate indicator rather than claiming a known total. Private visibility
hides details on a locked screen according to Android notification policy.

The exported `ACTION_PROCESS_TEXT` entry accepts plain selected text, previews
it and binds the final Send to an exact current trust. Clipboard contents are
read only after tapping Send clipboard in the unlocked foreground. Neither entry
collects clipboard history in the background.

MainActivity routing contract: explicit intents may set string extra `tab` to
Home, Apps, Sharing or Settings. QuickAccess intents use explicit component and
action; shortcut extras `trust_id` and `package_name` are untrusted inputs and
validated again before command admission.

Verification: `QuickAccessStateTest` covers truthful state distinctions;
`QuickAccessDeviceTest` exercises installed foreground consent, exact-trust receipt
admission and refusal of forged/revoked shortcut identities. Those local tests do
not prove a Mac executed an external effect; installed interoperability must also
be exercised against the broker and ADB transport.

Android references: [TileService](https://developer.android.com/reference/android/service/quicksettings/TileService),
[ShortcutManager](https://developer.android.com/reference/android/content/pm/ShortcutManager),
[AppWidgetProvider](https://developer.android.com/reference/android/appwidget/AppWidgetProvider).
