# Installed fallback, independent wrapper, and actual transport recovery

Accepted artifact: DroidBridge 0.1.8 build 14, installed main SHA256
`08d5e7011d4febb88d8fc56eab9f65f9bd3ae5525df60d944dcf57bbadc27865`.
The video Player is unchanged, SHA256
`d2e9b47bbff77c755bd7bcf45adc0a31a8098e2ccff178ea56ff02f7a5f69fb3`.

| Executed case | Result | Phases | Successful aggregate PCM blocks | Dropped metric frames |
|---|---|---:|---:|---:|
| API35 graphical fallback | Pass | 13 | 913 | 0 |
| Independent copied native wrapper beside fallback main app | Pass | 6 | 177 | 0 |
| API37 graphical fallback | Pass | 13 | 268 | 0 |
| Actual API37 emulator shutdown/reboot and same-GUI recovery | Pass | 6 | 95 | 0 |

The authoritative reports are `api35/result.json`,
`api35/wrapper-ownership/result.json`, `api37/result.json`, and
`api37/disconnect-recovery/result.json`. All four finished with one physical
emulator display, no owned forwards/reverses, and no cleanup errors. Global input,
IME, stay-awake, and timeout settings, physical panel state, preferences, persisted
sessions, and window geometry were restored. No production source was changed
while executing these cases.

The real main launcher was driven through public AppKit targets/actions: device
selection, app search, graphical Launch, Audio picker, Retry Audio, and Use Phone.
Fallback click stimuli use the unchanged Player's public SDL event queue on its
main thread. Audio argv exactly matches production; the test observer measures
successful SDL PCM submissions and retains only aggregate statistics from the
synthetic 997/1499Hz fixtures. It records no PCM. Presence requires six new blocks
from the exact owned PID, silence-relative amplitude and narrowband dominance;
absence requires the unrelated tone below 2% of wanted amplitude. Silence/Stop
controls, A/B/mixed sources, both Mac routes, panel OFF, resize, capture-only
failure, explicit Retry, and Phone release all passed. Physical speaker audibility
and physical OS focus were not measured.

The only added video argument is `--record=<owned path>`. API35's production
`--no-mouse-hover` is present; API37's is absent. Both retain mandatory hidden IME
and video `--no-audio`. Production/observed argv and process mappings are retained.
API35's accepted main matrix requires sequential recorded source dimensions and
12 positive numeric tick advances. The wrapper and API37 cases use on-demand
public `SDL_RenderReadPixels` immediately before the original `SDL_RenderPresent`.
The fresh request/ack binds exact Player PID, ID, main thread, Metal renderer,
actual bitmap/output dimensions, and actual OCR content; Android Texture dimensions
are logged separately. For example Retina output 1440x1812 correctly corresponds
to Android 720x906. These are real renderer pixels, not an OS screenshot. The
independent red/blue/no-request/stale-ID control is in
`../player-capture-control/result.json`.

The wrapper was made using production `MacAppWrapper.create`, actual device icon,
actual installed host, a unique owned QA Applications destination, and strict
signature verification. Its separate NSRunningApplication bundle identity and
regular activation policy were verified. Re-signing changes signature bytes, so
unsigned payload equality was checked on disposable executable copies only;
the actual signed bundles stayed sealed. Main fallback and native wrapper shared
one device audio client and mixed both tones. Killing only the owned main GUI
caused its supervisor to drain. The surviving wrapper acquired the lease, loaded
its own copied AudioClient/SDL, and submitted new 997Hz PCM; its Audio menu changed
Mac+Phone and then released capture to Phone while video continued. The owned QA
wrapper was unregistered/deleted afterward. No managed catalog or helper generation
was edited or evicted.

The recovery case actually stopped only `emulator-5582`, restarted the same
DroidBridge_API37 AVD with retained userdata and audio enabled, and verified a new
boot ID. The original GUI PID remained responsive. Its retained fallback video
intent restored automatically, and a new audio PID submitted 1499Hz PCM. Explicit
Retry was unnecessary in this reboot case; both normal matrices separately proved
that action after a latched capture-only failure. The new qemu PID 25229 and exact
restart argv are recorded in the report and were handed to the lead for cleanup.
Unrelated emulator 5554 and physical devices were untouched.

Observed, instrumented process snapshots are in the reports. Across API37 tone
phases, AudioClient was approximately 0.6–1.3% CPU and at most 31,072KiB RSS; Player
approximately 0.8–2.8% CPU and at most 150,288KiB RSS. These are scoped observations,
not performance acceptance thresholds or a benchmark without instrumentation.

## Preserved fixture failures

Every failed run remains under `api35-before-*` or
`api35/wrapper-ownership-before-*`, with original run logs at this directory.

- Initial two instant recording seeks saw the same tick 67. The SAME completed
  recording later decoded tick 122, proving continued producer content.
- The next fast-seek capture retained the PNG encoder's initial 720x1080 output
  despite real decoded/Player 720x906 content. The source-dimension fence rejected
  it. Completed sequential decoding reached tick 436.
- Two subsequent 25-second capture budgets correctly refused the recorder's
  buffered pre-resize frames (first 262KiB at720x1080). Sequential source-dimension
  validation with a finite 60-second budget passed the complete API35 matrix.
- First wrapper handoff inspected vmmap while the new successor's dyld/libSystem
  had not initialized. Its saved vmmap states that explicitly. Waiting for the
  positive initialized-output menu before inspection fixed the test; the complete
  wrapper replay passed.

None of these failures was counted as acceptance. Their causes and corrections
were test instrumentation/readiness changes, not production changes. Subsequent
fresh SDL renderer captures removed recorder-flush dependence. Accepted reports,
metrics, frames, bindings, driver snapshots, and source hashes are bound by
`accepted-evidence-manifest.json`.
