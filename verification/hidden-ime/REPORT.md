# Hidden Android software keyboard correction

Candidate: DroidBridge 0.1.7 build 12, based on `ff22987`.
Installed DMG executable SHA-256:
`13ea19c4226f25a132beab2e3ead81d87391ea2c3a46377afc50e374e8cd0c75`.
`release-inputs.json` binds 47 production/documentation inputs and both release
archive checksums. The application was installed outside the build tree at
`~/Applications/DroidBridge.app`. Signing is ad hoc; notarization is not claimed.

## Root cause and correction

Commit `3f1e55a` explicitly selected LOCAL IME placement to make Android 17
editing work while the phone panel was off. LOCAL intentionally places the
Android software keyboard on the virtual display rendered inside the Mac window.
This is independent of Android navigation/system decorations.

Both actual session backends now always request HIDE (`--display-ime-policy=hide`
and `display_ime_policy=hide`). It is not a preference that an old session or
wrapper configuration can override. The actual Android window/IME policy is
changed; frames are not cropped, masked or replaced. Physical display0 keyboard
settings are not altered. AppKit text/raw-key/paste and the upstream SDL input
paths remain available independently of Android's software IME.

Startup requires a readable Android API >=33 before resolving/staging/spawning.
Android 10/11 ignore HIDE and Android 12/12L lack the trusted display flag in the
pinned scrcpy server; admitting those devices would silently violate the policy.
The expert's source finding and primary references are in `ANDROID_REVIEW.md`.

A separate real fallback test discovered an Android 15 InputDispatcher abort
on hover/click across NavigationBar2, with a changed system_server PID and stable
kernel uptime. A controlled same-host run adding only `--no-mouse-hover` passed.
The production fallback now emits that flag only on API35, preserving clicks,
drags, scrolling and keys. API37 and other versions retain hover. The diagnostic
control is explicitly not final acceptance; final default runs are separate.

## Executable evidence

| Check | Result | Evidence |
|---|---|---|
| Old installed LOCAL bug reproduction | Pass as positive control: visible software keyboard | `qa/api35-local-positive/` |
| Final native Android15 decorations ON/OFF | Pass, 48 target-display state samples | `qa/final-api35-{on,off}/` |
| Final native Android17 decorations ON/OFF | Pass, 48 target-display state samples | `qa/final-api37-{on,off}/` |
| Final fallback Android15/17 decorations ON/OFF | Pass, 48 target-display samples; production arguments and stable system_server | `fallback/final-api{35,37}/` |
| Existing accepted wrapper update and launch | Pass, 16 wrappers upgraded by real main GUI maintenance; copied native wrapper passes 24 additional samples | `upgrade/result.json`, `upgrade/managed-wrapper/` |
| Full Swift suite | 127 executed, 4 opt-in tests skipped, zero failures | `unit.log` |
| SDK/backend/restoration/decorations argument invariants | Pass; actual supervised spawn capture with fake tools | `HiddenIMEArgumentTests`, `unit.log` |
| State-oracle regression controls | 19 pass, including visible LOCAL rejection and exact-display policy | `qa/parser-tests.log` |
| Installed signature/runtime dependencies | Pass, 23 Mach-O images inspected | `package.json`, `qa/release-hash-audit.json` |

The final native/fallback matrix contains eight cases and 144 passing target-display
IME snapshots. Both backends check phone panel ON, panel OFF and resized-panel-OFF.
Fallback runs additionally verify counter-click receipts and changing recorded
frames. The recording proxy adds only `--record`; API35 no-hover is emitted by
the production executable and is absent on API37. Both keep stable system_server
PIDs and empty crash buffers. Black Cocoa/Metal cached Player captures are not
accepted as visual evidence; actual decoded recording frames are used instead.

Every final native run checks phone panel ON, panel OFF and resized-panel-OFF.
Each phase has real exact-display text receipts, a newly observed raw Backspace
receipt, Cmd+V paste receipt, decoded screenshots and eight IME/window snapshots.
All five sampled global Android settings, Mac clipboard flavors, saved session
intent/preferences/geometry and exact display/forward/reverse resource baselines
were restored. Android17 may omit the IME InsetsSource entirely; the oracle
accepts that only with the exact target display policy2 (HIDE), a visible expected
app, and no visible/attached IME presentation. Missing/malformed/foreign-display
policy does not pass. The old LOCAL control actually shows the keyboard and is
rejected by this same oracle.

## Evidence boundaries

The desktop was locked. Native input uses public AppKit methods/actions in the
unchanged installed executable; fallback uses public SDL events in its unchanged
bundled Player. The fallback proxy may add recording only for final acceptance.
These exercise real host encoding, transport, Android input and frame content;
they do not prove physical macOS focus, Cmd+Tab or human keystrokes on an unlocked
desktop. Snapshots prove observed states, not a continuous universal guarantee.
Android13/14 admission is source-tested but has no new live emulator matrix.
Physical Pixel10Pro and vendor-specific policy behavior remain owner verification.
Application-drawn keypads are application content; Android IME composition and
suggestions are unavailable under HIDE. Arbitrary Unicode injection support is
unchanged. Earlier failed and intermediate runs are retained and are not silently
reclassified as final acceptance.

`a725fcaa…` results are the earlier candidate before the API35 fallback mitigation;
`release-inputs-interim-a725.json` and intermediate unit log identify that scope.
The original failed fallback fixtures, actual Android crash and diagnostic
no-hover control are distinguished in `fallback/README.md`. API37 native fixture
failures were corrected by observing two matching rendered post-resize dimensions
and editor bounds through local Vision OCR before clicking; no product change
was made to turn those fixture failures into passes.

## Updating copied Mac apps

Install the new main application and quit existing Android Mac apps. Opening the
main launcher updates accepted managed wrappers through its normal bounded,
journaled maintenance path. Manual wrappers require Create / Update Mac App…
once with the old wrapper quit. An already running old executable cannot gain
this policy merely by replacing the main bundle. Names, icons, identities and
saved launch configuration use the established wrapper update contract.

## Independent review

Android, macOS and independent QA reviews are retained in `ANDROID_REVIEW.md`,
`MACOS_REVIEW.md` and `qa/QA_REVIEW.md`. QA and Android independently replayed the
144 primary matrix snapshots and checked actual exact-display input receipts.
The lead additionally verified the real accepted wrapper upgrade and post-update
launch. Host process evidence is limited to the target serial’s actual scrcpy
server argv; unrelated process inventory is not retained.

## Final lead gates

- Final-source launch UX, retained wrapper failure/retry, and cancelled launch
  race regressions passed: `regression/final-*/` and associated console logs.
- Final cleanup verified each owned emulator had one display, no owned servers,
  forwards, reverse tunnels or native staged JARs, then stopped only5580/5582.
  User emulator5554 was retained (`cleanup.json`).
- Android, macOS and QA final reviews approve the recorded emulator scope.
  No remaining production blocker was found. Physical Pixel remains manual.
