# Companion interaction and state specification

Status: implementation contract from independent mobile/desktop UX review,
2026-10-30. This specifies required behavior; it is not a claim of installed
end-to-end acceptance. Capability IDs refer to `ROADMAP.md`. Protocol and
security bounds remain authoritative in `BOUNDARY_CONTRACT.md`.

## Shared interaction rules

The phone and Mac each show the selected peer name, its current availability,
and the age of the last successful update. An installation/trust identity is
the recipient authority. A USB serial, Wi-Fi address, editable Mac name or
previously selected row is not sufficient evidence of identity. If two trusts
have the same display name, show a short non-secret identity suffix in the
receiver chooser. Keep device and receiver selection stable during polling.

Service running, ADB authorized, companion paired, and peer reachable are
different facts. Never compress them into one green "Connected" state. A useful
phone Home summary is "Connection service on · No Mac paired", "Waiting for
Alex’s Mac", or "Connected to Alex’s Mac · updated just now". The Mac summary
can say "Pixel connected over USB · Companion not paired" while Android apps
continue to work. Show diagnostics such as loopback/protocol details in setup
help or Diagnostics, rather than as the primary Home explanation.

All user actions produce immediate local feedback without waiting for the next
poll. The feedback distinguishes these states:

| State | Meaning | Visible treatment / next action |
| --- | --- | --- |
| Ready | Feature admitted for the selected trust/device | Enabled action with receiver named nearby |
| Queued | Request retained locally; peer has not accepted it | "Waiting for Alex’s Mac…" and expiry/cancel if supported |
| Accepted | Correct peer accepted the immutable request | "Opening Calendar on Alex’s Mac…"; no success checkmark yet |
| Applied | Actual owner reports the requested effect | "Calendar opened on Alex’s Mac" or "Phone audio selected" |
| Rejected | Terminal refusal with a stable reason | Short explanation and a relevant correction; keep affected content |
| Unknown | Acceptance/completion response was lost | "Outcome not confirmed. Checking…"; resolve original request ID |
| Expired | No new execution may begin | "Request expired. Try again"; a deliberate new action gets a new ID |
| Cancelled | Cancellation fences further publication | "Cancelled"; partial owned staging removed, no completed claim |

Receipt retries reuse the same request ID. A Retry control after an unknown
outcome first resolves that receipt; it must not issue a second launch, reply or
file. Display at most a bounded recent operation list. Status announcements use
a polite accessibility live region; they do not steal focus, reset scroll or
repeatedly announce unchanged polling results. Toasts supplement persistent
state and never serve as the only record of an error or completion.

If the current peer becomes unavailable, retain current content with a clear
stale badge/time. Disable new actions requiring that peer and offer Retry,
Choose Mac, or connection help. Do not silently change recipients, replace
unknown values with zero, open a new trust, enable a sharing permission, or
switch to a different network protocol.

## C01 — USB setup

Phone Home starts with one primary action, **Start connection service**, and a
secondary **Connection setup** link. Explain the service as "Keep DroidBridge
available to your trusted Mac". A separate small explanation states that
Android debugging authorization enables the existing app/video connection.

The setup checklist has three individually observable steps:

1. **Connect the phone**: use a data-capable USB cable. Mac shows absent versus
   detected transport; phone does not infer that a cable supplies ADB.
2. **Authorize Android debugging**: direct the user to Android's own prompt,
   describe its broad access, and show unauthorized versus authorized. "Open
   Developer options" is a convenience, with an actionable fallback if the
   Settings activity is unavailable or developer options are disabled.
3. **Pair DroidBridge**: offer the companion pairing flow below. Mark this
   separate from Android authorization, with **Continue without companion** on
   Mac so existing app windows remain available.

Starting the service requests posting permission only with a short explanation
of the connection notification. Denial has an explicit observed state; it does
not imply that pairing or notification mirroring was denied. Stop service is
secondary while connected and warns that companion commands/transfers stop;
existing Android video follows its actual independent lifecycle.

## C02 — Wireless debugging and reconnect

Mac **Connect over Wi-Fi** explains that this is Android's secure wireless
debugging connection, not ordinary companion pairing. Present sequential
sections **1. Pair Android debugging** and **2. Connect**. Pairing address/port
and connection address/port are distinct labeled fields; do not rely on
placeholder text. Use a secure six-digit pairing-code field, clear it after
submission/close, and show **Paired; now enter the connection address** only
after actual success. Pair success does not imply a usable connection.

Validate fields locally before starting I/O. Pending/cancel state keeps the
window responsive, gives the operation name and has a bounded timeout. Errors
suggest checking the current Android screen, network reachability, or changing
expired ports. A refresh may update transport availability, but it does not
replace a field the user is editing. After connect, show verified phone identity
and observed transport; companion pairing remains a separate state.

On reconnect, retain last-known catalog/preferences and show a visible gap.
Existing streams stay on their actual transport. Explain when a window must be
reopened; do not label migration gapless. Capped automatic retries expose a
manual Retry. Avoid a modal alert on every reconnect attempt.

## C03 / C15 — Pair, select, revoke and replace a trusted Mac

Phone **Pair a new Mac** first requires the service. Show a QR code and a
copyable **Pairing link**, an expiry countdown, and the instruction **On your
Mac, open Phone → Companion → Pair Phone**. The plain secret is an advanced
manual alternative, not a six-digit wireless-debugging code. Closing/cancelling
the pairing sheet invalidates it if that is the implemented behavior; otherwise
state clearly how long it remains valid. Never imply Done revokes a still-live
pairing window. Do not persist the pairing QR in ordinary diagnostics.

Mac offers **Scan with Camera**, **Import QR Image**, and **Pairing link or
secret**. Camera permission is requested only after its action, and denial
retains both alternatives. After import, show **Waiting for approval on Pixel**
with the Mac name and comparison code. Phone confirmation shows the same name
and code, explicitly naming initial access and the optional features that stay
off. Approve and Deny are distinct, reachable actions. Timeout, denial, wrong
phone identity and unsupported version have different instructions. An approved
receipt and successfully stored credential precede the final Paired state.

Home has a persistent **Using: Alex’s Mac** chooser, including **Not selected**
when ambiguous. Selection controls future actions and is not confused with trust
revocation. All send/launch sheets repeat this recipient before confirmation.
Trusted Macs lists a selected marker, current reachability/last seen, and the
separate per-trust permissions. Defaults are explicit; notification sharing is
off for each new trust. A second Mac never inherits the first Mac's opt-ins.

**Forget Alex’s Mac** is destructive but does not silently affect other Macs.
Confirm that future requests stop and received files already saved externally
are not remotely erased. Phone-local revocation is immediate. Mac-side remote
revocation while offline reports **Access removed on this Mac; phone revocation
pending** if that is what happened. Reinstallation/rekey has **Phone identity
changed — pair again**, never silent replacement of an old trust.

## C04 / C05 — App catalog and Spotlight selection

Phone Apps begins with search, selected receiver, last updated state, and a
concise summary **23 selected · 20 available on Mac · 3 pending**. Make the
policy scope explicit: if export selection applies to every trusted Mac, say
**Spotlight choices apply to your trusted Macs**; if per trust, name that Mac.
Do not let a receiver switch silently change an unlabelled policy.

Use compact reusable rows: 48 dp app icon (placeholder reserves its space),
app label, optional small package only when distinguishing duplicate labels,
favorite control, export switch/checkbox, and **Open** action. Selected states
have text/accessibility values, not color alone. Search filters a locally
available snapshot immediately, before waiting for icons. Pagination or a
virtualized list must avoid rebuilding thousands of cards on the UI thread.

Changing a checkbox shows **Saved on phone · Waiting for Mac** immediately;
**Available in Spotlight** requires actual Mac publication/index admission.
An Apply/Sync action has selected and completed counts, progress, cancel and
partial-failure details. Cancellation preserves accepted wrappers/choices,
states the unfinished count and offers Continue. Deselecting explains removal
from Spotlight without deleting the Android app or silently stopping its session.

On Mac Apps, cached rows render with a stale badge while refreshing. Icon loads
do not shift row geometry or block search/launch. An unavailable phone has
**Unavailable — reconnect phone** with disabled launch admission; don't imply
the OS has instantly removed an already cached Spotlight result. Verify both
index visibility and launch refusal separately.

## C06 / C07 — Open, favorites and sessions

**Open on Alex’s Mac** requires a chosen trusted receiver and current control
readiness. Favorites are optional quick access, retained by package identity;
an uninstalled favorite is shown unavailable or explicitly removed, not rebound
to another app with the same label. Opening immediately creates a local pending
row, followed by accepted/applied/rejected/unknown as above. A queued event is
not **App opened**. Repeated taps while the same request is pending resolve the
same action rather than accidentally creating multiple windows.

Sessions show app icon/name, selected Mac, current phase, backend only in details,
and last update. The empty states distinguish **No apps running** from **Mac
has not reported sessions yet**. A stale snapshot cannot prove all windows
closed. Stop targets the exact live session owner, displays Stopping until
confirmed, and updates the same row. **Stop all on Alex’s Mac** names its scope
and asks confirmation when sessions are active. A partial failure lists which
sessions remain instead of saying all stopped. Independent wrapper sessions
remain in the dashboard after the main launcher closes.

## C08 — Audio and screen controls

Show the actual selected route using a radio group or one selected segmented
control: **Mac**, **Phone**, **Mac + Phone**. Explain once that audio is
device-wide, including other phone apps; capture restrictions may prevent
Mac output. Separate desired route from actual output state. **Mac selected ·
Audio unavailable** is valid and has Retry Audio and Use Phone. A request receipt
is insufficient proof of audible output. Physical listening remains explicit
where automated evidence proves samples but not sound from speakers.

Screen controls use unambiguous desired/action labels: **Turn phone display
off** / **Turn phone display on**, with a note that Mac app windows can continue.
Never call this locking or unlocking the phone. Show Unsupported or Unavailable
when actual authority/readiness cannot perform it. Hide Android navigation is
a separate setting with its real support/compatibility boundary.

## C09 — Health, compatibility and diagnostics

Home offers a concise actionable failure, with **Details** for device transport,
ADB authorization, companion trust/service/protocol, video/audio and permission
facts. Unknown battery/thermal/network is **Unknown** with observation time.
Never display zero battery, Normal thermal, or Connected based on missing data.

Diagnostics export previews the categories included and omissions. The user
chooses an export destination/share action and can cancel. The result names
whether it contains only scoped counters and version/error facts; no screenshots,
clipboard, notification bodies, files, credentials, hardware IDs or SSIDs by
default. A generic JSON dump is a detail view, not the primary failure recovery
experience. Show an error if generation fails rather than exporting an empty
report as success.

## C10 — Share files, images, text and links

An Android share intent opens a review sheet naming the selected recipient and
all accepted items with type and size (or **Size unknown — checking**). Show the
two-file/50 MiB limit before staging. Clarify any rejected extra items; never
silently send the accepted subset. Clipboard/text/url length validation gives
an inline reason and preserves the edit. URLs remain received links until the
user explicitly opens them.

The review action is **Send to Alex’s Mac**. Then show persistent per-item states
**Preparing → Waiting for Mac → Sending 4.2 of 12 MB → Verifying → Received on
Mac**, with cancel available while pending/in flight. Unknown-length preparation
uses indeterminate progress and observed bytes, not an invented percentage.
Preparing to private phone storage is not completed delivery. Display a warning
if the phone or receiver must remain available. Interrupted transfer exposes
Resume only when supported by an exact receipt; otherwise Retry explains a new
attempt. Cancelled/expired staging is removed and cannot later appear as sent.

Mac Inbox names sender/time/type/size and separates received/staged/failed items.
Only verified completion enables Save, Copy or Open. Save uses a destination
panel and safe default filename, asking about duplicates. Received files do not
execute, extract or open automatically. Clear Inbox explains it clears only owned
inbox copies, not externally saved files. Both sides have persistent terminal
status and a route to pending transfers without leaving the current edit.

## C11 — Explicit clipboard

Phone **Paste clipboard** and Mac **Send Clipboard** read only after that
specific action. Show a short local preview/byte limit and selected receiver;
never include clipboard in background status polling. Android foreground-only
restrictions are explained with an **Open DroidBridge on phone** action when
needed. Receipt creates **Text received from Alex’s Mac** with explicit Copy.
It never replaces the receiving clipboard automatically. Invalid/oversized text
has visible feedback; send success is based on the receipt, not local enqueue.
Received text has expiry/Clear and routine diagnostics never contain its body.

## C12 — Optional notifications and replies

Before opening Android notification-access settings, explain the breadth of the
OS grant and DroidBridge's narrower defaults. Keep OS access, global sharing and
per-Mac sharing visible as three independent observed controls; a checked app
switch does not imply the OS grant. Pairing itself enables none of them. The
Mac likewise requests local notification permission only after enabling alerts;
denial retains the in-app notification list.

Default to no sensitive/hidden/ongoing notification content and no Mac lock-screen
body preview. Filters name the selected trust and app, and show excluded states.
Only current RemoteInput actions have a Reply field. Pending reply disables
duplicate submission and preserves draft on rejection. A removed/replaced
notification says **This notification changed. Refresh before replying**.
Dismissal reports actual removal; unavailable/unsupported is not success.
Revoking access clears new admission and reports what retained content remains.

## C13 — Performance profiles

Use one selected profile with concrete copy: **Balanced — recommended**,
**Responsive — higher frame rate and resource use**, **Battery — reduced video
and background work**. Show selection and last applied result separately. State
**Video changes apply to newly opened windows; existing windows keep their
settings** wherever that is the actual implementation. Offer an explicit reopen
action only if supported; do not restart active app sessions silently.

Show observed battery/charging/thermal/network with freshness. Profile changes
must not imply they alter Android's global battery saver, network settings or
permissions. Unknown sensors remain unknown. Bulk work may slow under Battery;
control actions still acknowledge immediately with their true pending state.

## C14 / C15 — Get Mac app and update compatibility

Phone **Get DroidBridge for Mac** provides a real reachable official HTTPS
release, release version, supported Mac architecture/minimum system, artifact
size/checksum, and instructions to open the download on the Mac. Offer **Copy
download link** as well as opening a browser on the phone. A releases index with
no artifact is not a working delivery path. A phone cannot install or approve
software on the Mac.

If local installer delivery is implemented, name it **Send installer to an
already connected Mac**, state that it cannot bootstrap a Mac with no receiver,
and display artifact origin/version/architecture/signing status before transfer.
Use the same progress, cancel, integrity and explicit-open rules as files. A
checksum proves matching bytes, not authenticity of an untrusted source. Existing
ad-hoc packages must not claim Developer ID signing or notarization.

Version mismatch distinguishes **Update Mac app**, **Update phone companion**,
and **Feature not supported by this version**. Existing video remains usable
when companion compatibility fails. Update preserves accepted choices/trust
when safe; rekey/reinstall requires visible new pairing. Never silently admit a
new protocol major or use a download prompt as implicit consent to install.

## Layout, accessibility and testable acceptance

Phone navigation remains Home / Apps / Sharing / Settings, with the active tab
visually and programmatically selected. Use at least 48 dp touch targets and
semantic heading/button/checkbox state; reserve icons' dimensions. Long labels
wrap without fixed-height clipping. At 320 dp width and 200% font scale, every
action remains reachable by scrolling, including pairing confirmation, transfer
cancel and the final nav item. Pairing dialogs and editor screens must support
IME/insets without obscuring actions. Do not rebuild the whole screen every
500 ms: update only changed state, preserving scroll, keyboard, text entry and
accessibility focus. Restore draft/tab/selection after rotation/process recreation
within privacy and expiry limits; never retain a live pairing secret as a draft.

Mac windows use resizable scrollable content with explicit minimum sizes;
status/error lines wrap and full text remains reachable. Provide visible labels
besides placeholders, normal tab traversal, Escape cancellation where safe,
Return for the clear primary action, accessibility labels/values on progress and
radio groups, and selection preservation under polling. A status update must
not move the window to the foreground or interrupt another Android app window.

The release review needs actual installed screenshots and interaction receipts
for disconnected/unpaired/pending/paired/stale/error states, two trusted Macs
with receiver switching, large/narrow text, keyboard traversal, Android service
permission denial, QR/manual fallback, real share/progress/cancel, explicit
clipboard in both directions, notification denial/reply/revocation, profiles on
new versus existing sessions, installer guidance and update mismatch. Source
tests prove guards; they cannot prove a usable rendered layout. Physical camera,
Mac focus and Pixel-specific security prompts remain separately identified when
not observable in the development environment.
