# Corrected Android10 systems runtime

**PASS for the tested Core/Streaming boundary.** This does not claim installed AppKit GUI acceptance or physical Wi-Fi/Pixel acceptance.

The actual installed Android base.apk matched SHA256 `49570ea24a1f4d3fd6207f9e11afa21db6e76d678090d2336770318f30de8e0b`. The harness linked the current DEBUG Core/Streaming objects and used the signed installed **DroidBridge Companion QA6.app** ADB, scrcpy5.0.1, server, audio client and supervisor. `candidate.json` and `harness-build.json` bind their exact bytes. The QA6 bundle contains Android9; Android10 was already installed by the Android owner. Package7 runtime equivalence is a separate final-artifact check.

The fresh private QA root was `.build/companion-systems-code10-qa35`, with mode700 and the unchanged emulator5580 scope for catalog, Keychain and forward receipts. The one compiled DEBUG loopback alias admission hook had no endpoint override: both companion connections used real reserve/establish ADB forwards, mandatory QR certificate pin/UUID/expiry and actual phone comparison/approval. No shipping authentication or protocol guard was relaxed.

| Executed check | Result | Evidence |
|---|---|---|
| Android Wireless Debugging pairing-code TLS through exact emulator redirections | Pass | prepare-wireless.log; real TLS alias authenticated by broker |
| Corrected pending/approved phone pairing | Pass | driver.log; runtime.log |
| Both aliases resolve to authenticated canonical installation | Pass | runtime-report.json |
| Two concurrent native video streams | Pass | 49/1 decoded frames at checkpoint; session-logs |
| Adaptive resize | Pass | decoded640×800 geometry assertion |
| Mac audio output initialization | Pass | actual router ready-state assertion; no audibility claim |
| Audio-only ownership blocks second alias after video stops | Pass | runtime-report.json |
| Phone audio preference shared across aliases | Pass | canonical preference assertions |
| Host SIGKILL retains supervisor lease until teardown | Pass | 12 refused polls,0.294s drain; session-logs |
| Wireless native capture after crash recovery | Pass | decoded-frame assertion |
| Five alternating USB/TLS launch-close cycles | Pass | each decoded1–3 frames then awaited stop |
| Resource cleanup | Pass | resources-before/after.json; cleanup.json |

All five observed first-frame times were1.09–1.41s and awaited stops0.27–0.34s. These are observations while packaging/other work could run, **not quiet performance acceptance**. Forty-two harness-only samples had peak RSS40,448KiB and peak CPU8.6%; child processes are not included and no memory-leak conclusion is inferred from this small sample.

Final Android display IDs were exactly the starting `[0]`. No owned forwards, redirections, scrcpy server processes or staged DroidBridge JARs remained. The authenticated broker revoked its exact test trust; phone UI then confirmed no trusted Macs remained. ServiceOFF, developer1/ADB1, wireless-debug0, font1.0 and physical density420 were restored/preserved. The AVD was never restarted, and physical Pixel, emulator5554/5582, shared ADB server and Mac UI were untouched.

The actual crash test kills the capture host. Unexpected supervisor SIGKILL/guard-fork teardown remains covered by the independent real-C unit tests, rather than being claimed as an Android runtime check here. Keyboard/mouse input, fallback windows, installed broker relaunch, and Spotlight UI are outside this harness; their owning GUI/system reports remain separate gates.

## Execution and retained failures

`harness-build.log/json` record direct `swiftc` linking of existing Core/Streaming object files, with no SwiftPM build. `executed-harness/` retains the exact private phone driver/setup/cleanup source without pairing secrets. Setup initially found the previously restored Wireless Debugging panel rather than the expected parent Developer Options list; `prepare-restored-settings-page.log` retains that failed setup read. The private setup adapter was corrected to recognize the existing official panel; device/product policies were unchanged.

The earlier final5/Android8 pairing failure remains in `../final5-systems/`; it was not overwritten or treated as a pass. This run proves the corrected Android10 backend with the recorded packaged-runtime cohort.
