# Independent hidden software keyboard review

**Verdict: APPROVED for the tested Android 15/17 emulator scope. Both final installed backends PASS; no unresolved release blocker found in this review.** This review binds 0.1.7 build 12, installed main SHA-256 `13ea19c4226f25a132beab2e3ead81d87391ea2c3a46377afc50e374e8cd0c75`. Compilation or requested flags alone do not establish hidden IME behavior.

## Positive control

The unmodified installed 0.1.6 build 11 executable (`55fe5f6725dfe5bfbf0c3d9f77aaae93899aecbb54c34f79165e01b97e04811f`) creates a native display with LOCAL IME policy. The public AppKit action shim clicks the real Android editor and sends `HiddenImeText` through the shipping window/input/transport path.

`api35-local-positive/result.json` records reproduction on virtual display 2. All eight display snapshots report a visible IME InsetsSource with keyboard frame `[0,503][720,1080]`; current InputMethod state reports token display 2, hidden-by-policy false and input shown true. Display-bound text receipts and `editing.png` corroborate the observed keyboard. The oracle rejects all eight snapshots. Exact resource baselines and prior wrapper state are restored. This is a real negative control for the fix, not a mock.

## Fail-closed display oracle

`scripts/verify-hidden-ime-state.py` requires each exact nonzero display and its expected visible application window. It accepts explicit hidden IME insets, or the Android 17 legacy dump field `mShouldShowIme=2` (the field prints the numeric IME policy) when HIDE omits the IME source. Any present policy token must uniquely equal 2; missing, malformed, empty, conflicting or other policy tokens cannot authorize source absence. A visible inset always fails, including when policy says HIDE. An attached/ready/on-screen/visible IME WindowState on the target also fails. Physical display policy and other apps cannot authorize the tested display.

Nineteen parser tests pass in `parser-tests.log`, including the actual LOCAL bug dump, actual Android 17 HIDE/no-source dump, wrong/missing/duplicate display, package-suffix confusion, malformed policy, cross-display policy, and attached IME despite explicit HIDE. Synthetic parser fixtures are unit evidence only. The oracle explicitly disclaims proof of continuous invisibility and input delivery by itself.

## Exact final installed native results

| Actual installed test | Editing phases | Hidden snapshots | Text / raw Backspace / Cmd+V | Cleanup |
|---|---|---|---|---|
| `final-api35-on/result.json` | phone ON, OFF, resized OFF | 24/24 | all phases pass | exact baseline |
| `final-api35-off/result.json` | phone ON, OFF, resized OFF | 24/24 | all phases pass | exact baseline |
| `final-api37-on/result.json` | phone ON, OFF, resized OFF | 24/24 | all phases pass | exact baseline |
| `final-api37-off/result.json` | phone ON, OFF, resized OFF | 24/24 | all phases pass | exact baseline |

The final suffix indicates Android system decorations ON/OFF. Every result records the exact installed hash, real session/display identities, server arguments containing mandatory HIDE, 720×1080 initial geometry and 896×1344 resized geometry. Real rendered frames are OCR-checked twice against current Android geometry before targeting the editor. Text reaches the exact display; raw Backspace must produce a **new** shortened receipt rather than reuse a historical typing prefix. Actual Cmd+V appends the phase-specific paste. Eight WindowManager display/window/InputMethod samples follow each editing phase, for **96 final native samples**. Captured frames show received text and advancing probe ticks without a keyboard; they supplement the state oracle.

All four runs restore exact display/forward/reverse baselines, phone panel state, original Mac preference/session bytes and modes, window geometry, and every readable pasteboard item/type/data flavor held in memory. No clipboard payload is logged. Five named Android settings compare equal before/after: hardware-keyboard IME behavior, default/enabled IMEs, stay-awake and screen timeout. This checks those settings, not every Android setting.

## Preserved failures and remediation

The interim `a725…` native Android 15 runs passed, but do not substitute for the final hash above. Initial Android 17 fixture attempts missed the editor while the rendered frame still reported 696×1048 and Android already reported 720×1080. Those failures and screenshots remain under `api37-hide-decorations-on` and `api37-hide-diagnostic`; they are not relabeled passes. The fixture now waits for two real rendered dimension/geometry matches rather than a fixed delay. Both final Android 17 modes pass.

The fallback tester captured a separate Android 15 InputDispatcher pointer-overlap abort with actual system-server PID change in `../fallback/api35-sdl-health-retry`. Earlier DeadSystem exceptions alone were correctly treated as insufficient proof of a restart. A same-binary, test-only no-hover diagnostic passed, explicitly marked non-acceptance. Production now adds `--no-mouse-hover` only on Android 15 fallback, retaining clicks/drags/scrolling and other Android versions' hover. The final fallback runs below verify the production policy without the diagnostic override.

## Exact final installed fallback results

`../fallback/final-api35/result.json` and `../fallback/final-api37/result.json` both report `passed=true`, `acceptance=true`, diagnostic override false, exact host hash `13ea19…`, and unchanged bundled Player hash `d2e9b47bbff77c755bd7bcf45adc0a31a8098e2ccff178ea56ff02f7a5f69fb3`. Each covers decorations ON and OFF, with phone ON, OFF, and resized OFF editing phases. Public SDL event injection reaches the unmodified client's production event/input/transport path; every phase has an exact-display counter increment, phase-specific text, raw `k`, and Cmd+V paste receipts.

Independent `fallback35-replay.json` and `fallback37-replay.json` re-evaluate all **48 raw fallback display/window snapshots** with the same fail-closed oracle and separately check display-bound input receipts. The proxy appends only `--record`; the production argv itself supplies HIDE plus no-hover on API 35, and supplies HIDE without no-hover on API 37. There is no test-only no-hover override in these acceptance runs. Both real recordings change decoded frame hashes. The captured AppKit Player bitmaps are black under the locked host and are explicitly rejected as visual evidence. Frames independently extracted from actual recordings (`fallback35-late-recorded.png`, `fallback37-late-recorded.png`) show current probe ticks, editor content, and no software keyboard.

System-server PID remains 9550 on API 35 and 682 on API 37; crash buffers are empty. Exact display/tunnel baselines, tested Android settings, Mac preferences/session intents and clipboard restoration all pass, with unchanged installed bytes. This yields **eight final cases and 144 passing hidden-state samples** across both backends, Android versions and decorations settings. Each sampled state is bound to its actual display and visible application; input is checked independently.

## Source, artifact and compatibility boundaries

Independent `release-hash-audit.json` verifies all 47 release source/document inputs, the installed executable, and both release archives (50 matching hashes). Reviewed source places the SDK admission before staging and always applies HIDE in both backend runtime arguments; persisted legacy IME fields cannot override it. SDK admission requires Android 13/API 33 because pinned scrcpy's trusted virtual-display support begins there. The full unit result is 127 tests, four explicitly device-gated skips, zero failures; separate real evidence supplies the runtime matrix rather than treating skipped tests as passes.

Pinned scrcpy can swallow OEM reflection-policy failures, so the verified scope is the actual Android 15/17 emulator matrix, with the documented OEM compatibility limit. Finite samples cannot prove every instant or every OEM implementation. App-drawn keypads are app content. Existing self-contained copied wrappers require the documented runtime update; merely installing a new host cannot change their old executable. No fresh reconnect IME matrix or physical Pixel test is claimed.

The locked Mac host prevented physical OS-focus acceptance. Native tests use public AppKit event paths; fallback tests may use approved public SDL events. Both exercise shipping client input and real Android transport, and neither is presented as a physical-focus test. Shared preferences/devices were explicitly released to the fallback tester after all native cleanup completed.

QA process evidence is deliberately scoped: the driver writes only the tested emulator’s scrcpy-server argv rows, and the ten earlier `processes.txt` captures were narrowed to those same assertions. `process-evidence-scope.json` records this removal of unrelated host inventory. No product behavior or acceptance assertion changed.
