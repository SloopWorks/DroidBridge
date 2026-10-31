# QA8 comparison with the actual M6/recovery cohort

**Exact runtime equivalence confirmed for the external capture/audio/transport components. The whole application and broker are not equivalent.** This is a read-only filesystem/source comparison; no device, GUI, installed job, process lifecycle or Keychain state was changed.

## Artifacts bound

The actual M6/five-cycle and companion-service-recovery reports used signed installed `DroidBridge Companion QA6.app` runtimes with Android10 on the owned API35 emulator. Both historical candidate records contain the same runtime hashes. Those recorded QA6 files still match their exact bytes: `prior-runtime-record-binding.json` verifies every recorded component, including the historical host, broker and bundled Android9 APK. The separate Android10 device hash remains in the historical reports; it is not confused with the bundled Android9 APK.

QA8 is `/Users/patrick/Applications/DroidBridge Companion QA8.app`, bound by `package-build8-installed.json` and `package-build8-installed-validation.json`. Both app inventories contain198 entries. This comparison independently hashes the installed files, modes and symlink identities; existing packaging verification supplies the signature/dependency gate. The relevant source audit compares `5720ddf` to current committed `a2a37c68d67d7f809ea7e1694fdf030414334435` and confirms audited working-tree files match the latter commit. Earlier tests retained exact compiled object hashes; this source comparison does not pretend to reconstruct their entire build from Git alone.

| Component | QA6 → QA8 |
|---|---|
| ADB executable | Exact bytes/mode |
| Entire scrcpy Player.app,5 entries | Exact bytes/modes |
| Pinned scrcpy-server JAR | Exact bytes/mode |
| DroidBridgeSupervisor | Exact bytes/mode |
| DroidBridgeAudioClient | Exact bytes/mode |
| All23 bundled dylib entries | Exact bytes/modes/symlink identities |
| Main host executable | Changed |
| Companion broker executable | Changed |
| Availability helper executable | Changed |
| Android companion APK | Changed; QA8 carries Android11 candidate2 |
| icon-helper.jar | Archive bytes changed; every uncompressed entry payload is identical |
| Runtime versions.txt | Changed |

Full inventories and differences are in `qa6-inventory.json`, `qa8-inventory.json` and `runtime-comparison.json`. Runtime paths differing are exactly the Availability helper, CompanionBroker, icon-helper.jar and versions.txt. Whole-app changes also include metadata, APK, notices/provenance and documentation/signature resources. No claim is made that the whole Runtime directory, Swift module, broker or app is unchanged.

QA8's recorded main host SHA256 is `02f9ecc40b2a9d7d769dee919b1f6f29bdab312b5f52be818b9e78590149a5a7`, broker is `82bae4c6d6e18f27db9df640f1c53a9e6cec83c8a7103faadd99b28168102386`, and APK is `6fa302dd74bd42d67a4bcc88a9970c8079af880a376263ca3ff42584ef809029`.

## Mechanism evidence that still applies

`source-bindings.json` confirms unchanged production source bytes for canonical alias admission, export/catalog authority, audio preferences/router, broker registry/scheduler, Keychain/forward/installer/portable-runtime code, frame mailbox/decoder/socket transport/control protocol, native recovery, supervisor C and NativeWindow. In the changed BridgeSession file, exact function text remains unchanged for `spawn`, `startNative`, remote-socket derivation, `cleanup`, `resize`, `sendInput`, `stopAndWait` and `stop` (`bridge-function-bindings.json`). The common start call changed only the fallback method's obsolete Android API parameter; the native branch remains the same.

Consequently, the earlier actual tests remain evidence for these specific mechanisms: concurrent native streams on one admitted alias; decoded adaptive resize; shared audio ownership/Phone intent; cross-process refusal of a second alias until teardown; capture-host SIGKILL lease retention; five finite launch/close cycles; and exact stream/process/display/JAR cleanup. The relevant external runtime bytes and mechanism source did not change. These are not recast as tests of the new installed GUI/broker/APK.

Broker `connect`, `admit`, QR begin/poll, maintenance/reconnect scheduling, state publication and forward removal/retirement function text remains unchanged (`broker-function-bindings.json`). However, its event poller and failure ownership changed to generation/token fencing. Notification projection/trust authority and client/model fields also changed. Therefore the earlier successful service-restart report proves the prior actual recovery boundary; it cannot by itself certify the new poller or Android11 integration.

The fallback now always suppresses buttonless mouse hover, instead of only on API35. That is an intentional input behavior change requiring current fallback interaction evidence, even though the Player binary itself is identical. The Availability helper changed as a linked binary despite unchanged relevant source; its artifact validation/managed-wrapper availability gate must remain separate from M6.

## Current-installed smoke still required

The Mac expert's QA8/API37 run should supply the current-artifact evidence; this comparison performs none of it:

1. Fresh/stored pairing to Android11, catalog refresh, live native window and input, proving the changed host/broker/APK work together.
2. While a native stream runs, force-stop only the companion; observe disconnected status without losing/replacing capture, then restart it and verify automatic reauthentication, same trust/UUID/pin, new clock epoch and exactly one restored phone session. This specifically covers the new poller/failure ownership. Do not substitute the historical Android10 recovery report.
3. Current fallback launch with mouse movement followed by clicks, dragging and scrolling on API37, covering the changed universal no-hover flag. Earlier native-only M6 checks are not fallback-input evidence.
4. Current notification scope/permission/action tests for notification_scope_v2, plus current managed-wrapper availability/export validation where required by those owning gates. These features were outside the actual M6 mechanism run.

Existing QA8 signature/dependency verification and the current Swift suite are separate gates. A quiet performance cohort is also separate; no timing/resource claim is created by this read-only comparison.
