# Independent macOS hidden-keyboard review

## Candidate and scope

**Status: approved for the exact final candidate below, including both backends
on API 35/37 and actual managed-wrapper propagation.**

Reviewed final installed DroidBridge **0.1.7 build 12**, copied from the release DMG:

`13ea19c4226f25a132beab2e3ead81d87391ea2c3a46377afc50e374e8cd0c75`

The installed executable hash and Info.plist version/build were independently
checked. `codesign --verify --deep --strict` succeeds, and all 47 bound
production/documentation inputs match their frozen manifest hashes.
Signing is ad hoc; no Developer ID or notarization claim is made.

This agent performed source, artifact, report and image inspection only. No
device, preference, clipboard or session operation was performed by this review.

## Mac input and window wiring

**Production Mac input path accepted.** `NativeWindow.swift` and the control
protocol encoder are unchanged by this fix. Focused live video still maps mouse
coordinates through its shared aspect-fit transform, receives text through
`keyDown`, and sends mapped raw key-down/key-up events. Pre-video/error-state
input remains fenced. Copy/cut/select-all and both the Cmd+V handler and public
`paste:` action keep their existing Android control paths. Clipboard paste uses
the clipboard-set message with its paste bit, independently of whether Android
shows a software keyboard.

Both production spawn paths now use display-scoped HIDE policy independently of
the system-decoration option. The new API-33 minimum/unknown-SDK refusal occurs
before app resolution, server staging, display creation or client launch. A
failed refusal continues through the established retained-error/retry UI rather
than silently exiting a wrapper. No global Android IME setting is written by
this policy change.

## Executable evidence inspected

The exact final installed native candidate passes four reports:

- `qa/final-api35-on/result.json`, `qa/final-api35-off/result.json`,
  `qa/final-api37-on/result.json` and `qa/final-api37-off/result.json` cover both
  Android versions and both decoration choices. Each covers phone panel ON,
  panel OFF and resized-panel-OFF, with display-bound text, fresh raw Backspace,
  actual Mac Cmd+V handler delivery and 24 explicit hidden-IME state samples.
- All four runs restore every pasteboard flavor and unchanged global Android
  settings, with exact display/forward/reverse baselines restored. The total is
  96 observed hidden-IME snapshots across these native cases.

Each report binds the final executable hash. An earlier reviewed
`qa/api35-hide-paste/panel-on-editing.png` visibly shows
`HiddenImepanelonPastepanelon` in the Android editor with no software keyboard.
The earlier LOCAL-policy positive control reproduces a visible Android IME and
is correctly distinguished from these final HIDE runs.

The argument tests exercise both real spawn code paths with fake capture tools,
including restored configuration and both decoration settings. They establish
policy invariants and SDK refusal, not live input/video. Native loading/failure
regressions are separately retained under `regression/`.

## Instrumentation boundary

Native test instrumentation invokes public AppKit view mouse/key methods and
target/actions inside the unmodified installed executable. It does not replace
the Android transport, decoder or input encoding. It tests the Cmd+V handler and
actual Android receipt, not physical keyboard delivery through macOS focus on
the locked desktop. Fallback fixtures support public Cocoa events and public SDL
event-queue injection in the real client, explicitly labeling the selected path.
Final accepted fallback API-35/37 input uses the public SDL queue on the client main
thread; no decoder or Android wire protocol is replaced. The Cocoa fixture also
synthesizes its public key-window notification when the locked desktop suppresses
activation. These are client-path evidence, not
proof of physical OS activation, Cmd+Tab or a human's Spotlight interaction.

The native clipboard fixture snapshots every available pasteboard flavor in
memory, never logs payloads, and restores only while its change-count fence still
owns the pasteboard. The fallback fixture now also checks its pasteboard change
count before restoring and refuses to overwrite a newer external copy. A
test-only quit-receipt ordering gap was reported: cleanup-only restoration should
occur before its outcome is recorded. Production clipboard behavior is unchanged.
Repeated Android state samples support observed absence
in the tested phases; they do not prove continuous absence on every OEM/device.

## Existing Mac applications

The main application and each wrapper carry separate copies of the executable
and Runtime. Replacing only the main app does not mutate an already running or
manual copied wrapper.

`ManagedAppNameRepair` compares accepted records' `sourceVersion` and `sourceBuild`
with the installed host, so 0.1.7/12 becomes an update candidate. Its existing
bounded maintenance pass copies the new executable and Runtime, preserves saved
launch configuration and Android icons, re-signs/verifies the complete staged
bundle, and commits through the managed publication journal. Running wrappers
are deferred until they quit.

`upgrade/result.json` now establishes actual installed-main maintenance of all
16 accepted emulator wrappers from 0.1.6/11 to 0.1.7/12 without editing the
catalog to simulate success. The accepted Test wrapper was independently
strict-signature checked; its actual executable SHA matches the upgrade and
wrapper-run reports:
`4f4c0afa32c1f80c9a87485c4df9d65a53e97640b735babf773e30b0342b89c0`.
All 32 file-backed Mach-O sections are byte-identical to the final installed
host's executable; the whole-file signing identity differs for its separate
wrapper bundle identifier. `upgrade/managed-wrapper/result.json` passes native
panel-ON/OFF/resized-OFF text, raw Backspace and paste with another 24 observed
hidden-IME samples, all-flavor pasteboard restoration, unchanged global settings
and exact resources restored. This agent inspected those results and binaries;
it did not run the migration or alter device/preferences state.

Manual wrappers require **Create / Update Mac App…** explicitly, with the old
wrapper quit first. The factory preserves its launch identity/backend, retains
the previous bundle generation and copies the final host runtime. Existing
sessions and copied old executables must be restarted/updated before this fix
can affect them.

## Verdict

No blocking production macOS input, paste, view-lifecycle or wrapper-update-path
regression was found. Final Mac source/artifact review, the four final native
reports, final API-35/37 fallback evidence and actual managed upgrade are accepted.
No remaining blocking Mac integration issue was found for this candidate. Physical Pixel,
unlocked-desktop foreground focus, complex-language input and untested OEM
policy behavior remain outside the proven scope.

## API-35 fallback follow-up

Actual fallback integration exposed an Android InputDispatcher abort and changed
system_server PID; the original candidate cannot be considered a successful
fallback release on that evidence. The controlled run
`fallback/api35-no-hover-control/result.json` uses the same historical host plus
only a diagnostic `--no-mouse-hover` addition, and records passing decoration /
panel / resize / text / raw-key / paste cases with a stable system_server PID.
Its `acceptance=false` designation is correct: a proxy-modified argument list
does not establish final production defaults.

The production correction passes the already validated SDK value into
`startExternal` and adds `--no-mouse-hover` only for API 35. The native backend
does not forward mouse hover and is unchanged; API 33, 34, 36 and 37 fallback
behavior is unchanged. Actual spawn-path unit coverage checks that version
matrix. The narrow change preserves click, drag, scroll and keyboard paths.
This mitigation agrees with the author-reported workaround in the primary
[scrcpy issue 5477](https://github.com/Genymobile/scrcpy/issues/5477), which records
an Android-15 system-server input-dispatch crash and disabling hover as its
workaround. The final `fallback/final-api35/result.json` now has
`acceptance=true`: production arguments include the mitigation without a
diagnostic override, the Player executable hash remains unchanged, and the test
proxy adds recording only. Both decoration choices cover panel ON/OFF and
resized OFF with text, raw key and paste delivery, 24 observed hidden-IME
snapshots total and changed recorded-frame hashes. System-server PID 9550 remains
stable, global Android settings are unchanged, preferences/session intent are
restored, and exact display/ADB resources return to baseline. This final result
replaces the proxy-modified control as API-35 fallback acceptance evidence.

`fallback/final-api37/result.json` independently completes the other fallback
platform: acceptance=true, no diagnostic hover override, production hover
retained, unchanged installed host/Player hashes and stable system-server PID 682.
Both decoration cases cover panel ON/OFF and resized OFF with received text,
raw key and clipboard paste, another 24 hidden-IME samples, changing recorded
frames and exact cleanup/settings/preferences/intent restoration. In total the
final native and fallback reports cover eight backend/platform/decoration cases
with 144 observed hidden-IME snapshots. This does not extend the claim to
physical OS focus or continuous absence between snapshots.
