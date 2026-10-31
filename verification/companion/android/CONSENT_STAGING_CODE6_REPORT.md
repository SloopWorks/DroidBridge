# Android consent and staging checkpoint — code6

The signed Android 0.2.0/versionCode6 checkpoint is verified on the assigned API37 emulator. This accepts these Android changes and their executed tests; the full companion program, installed Mac build3, public delivery and physical Pixel acceptance remain separate gates.

## Frozen artifact

- Product: `.build/companion-consent-code6-candidate/DroidBridgeCompanion.apk`
- SHA-256: `b17b6bcae25cb3549ec696a868675807aa93fc316ae1327bd8af9ede5dfc31f5`; 2,852,495 bytes.
- Signed test APK: `DroidBridgeCompanion-test.apk`, SHA-256 `1ff26182e53c9a0ceba3dd8ed6df57eeb63801ad05b2e75d5a58551db1b1befc`.
- Same persistent local release certificate: `eb482305a29dfa3c7056f2a8eb6162eff9c123e2de6f85601284ca8967cd98c4`. Full apksigner output is `consent-code6-certificates.txt`.
- Exact source and APK hashes are bound by the candidate `manifest.json` and `consent-code6-artifact.json`. Every bound source still matches. Product APK notices were extracted and compared byte-for-byte with source assets; test/provider classes are absent from product DEX. Earlier frozen code2/code4/code5 paths were preserved.

## Consent and actual large-text defect

Forget now says companion sharing and commands stop immediately while existing ADB/scrcpy windows can continue. Android USB/wireless debugging must be revoked separately; pairing and saved external files have explicit treatment.

An additional actual native-dialog inspection found that the old platform action bar allocated space for one stacked button and only a small peek of the next at 320dp/200% text. Raising individual button minimum height did not fix parent clipping: the regression measured a 219 px button with only 104 px visible. That candidate was rejected, despite its earlier19+4 unrelated tests passing.

All MainActivity dialogs now use one public-API helper. It keeps the existing native Button objects/listeners and dialog semantics, allows intrinsic wrapping, ensures at least 48 dp and intrinsic text-plus-padding height, and groups all native actions in one vertical WRAP_CONTENT container so the stock dialog reserves the whole group. It neither caps nor overrides user font scaling. Activity destruction dismisses its active dialog.

`CompanionConsentDeviceTest` opens the real Settings→Forget flow for a temporary named test trust. It checks complete global button bounds,48dp targets, vertical text layout fit and no ellipsis. Cancel preserves every trust. Confirm removes only that explicit temporary trust and preserves the original trust set and receiver. No existing QA trust is confirmed or removed.

## S07: blocked content-provider read

Previously, staging checked its 30-second budget only before InputStream.read. A provider pipe that never sent a byte could block the worker indefinitely.

Staging now reserves its slot before provider work. A single shared scheduled executor issues one deadline per transfer. Cancellation marks the operation before sending a CancellationSignal to provider query/open and closing the registered stream on a bounded two-worker/two-queue executor. Timer/UI threads never wait for those operations. There are checks before and after each read, including EOF, and before publication; a close that wakes read with EOF cannot publish a truncated file. The scheduled task is removed in finally, and the reader slot is retained until its worker actually exits. No thread or timer is created per chunk.

The release-signed regression uses a real unexported test-APK ContentProvider in a separate UID. Its owner Activity grants only explicit nonce-scoped read URIs. Two reliable pipes hold their writer ends open without sending data or EOF. The test verifies both are open, refuses a third staging reader, exercises the real production 30-second timer, and requires both worker futures to complete within 37 seconds. Both rows fail and normal staging succeeds afterward. A separate stalled pipe verifies explicit Cancel returns its worker within 4 seconds and normal staging capacity recovers again. Provider writer counts remain nonzero until explicit fixture cleanup, proving provider EOF did not make the test pass. The fixture is excluded from the production APK.

Security reviewed the cancellation/admission design. Important limitation: Android cannot force a malicious provider Binder query/type/open implementation to honor cancellation. Such a call can retain its bounded reader until it returns; no slot is released early and no absolute 30-second guarantee is claimed for an arbitrary provider. The same qualification is documented in BACKEND_APIS.md. Public release metadata's 10-second elapsed budget plus configured per-I/O timeout overrun is documented separately; it is not described as an absolute wall-clock deadline.

## Executed evidence

- `consent-code6-final-api37.txt`: **21/21 actual signed tests pass in 80.764 s**, covering prior security/TLS/catalog/transfers/metadata/notices/UI plus consent and real stalled pipes.
- `consent-code6-final-large-text.txt`: **5/5 actual tests pass in 13.071 s** at 320 dp width/200% text, including consent action geometry and offline notices.
- `consent-code6-dialog-api37.{png,xml}`: final real Forget dialog at those settings; both action labels are fully visible. Cancel was used.
- `consent-code6-ui-restored.json`: exact original font 1.0, physical density 480,1280x2856, no override restored.
- `consent-code5-upgrade-{before,after}.json` and `consent-code6-upgrade-after.json`: same-signer install-r upgrades without uninstall/data clear preserve UUID `d562ee9a-1236-4f3c-a0ae-1f47a1b345fa` and leaf pin `82f9aeab82dcb375f75a490ad81a064e315da5211e033c8938928a930b05ee8d`. Public hello was checked against the known pin before sending HTTP. Public identity continuity alone is not accepted Mac Keychain trust-continuity proof.
- `consent-code6-broker-{pause,restored}.json`: the exact scoped QA broker 53979 command and process start identity were verified before SIGSTOP/SIGCONT; stopped T state became running without T after production service restoration.

Failed fixture attempts are retained. The test APK initially used Kotlin Activity/provider classes in its own UID, but AGP had deduplicated Kotlin runtime into the target product APK. The owner Activity crashed with ClassNotFoundException before granting access; correct provider denial followed. Pure-Java test fixtures fixed that dependency error. The initial background-launch explanation was a hypothesis, not the root cause. Those failed attempts are not included as passing deadline evidence.

## Runtime handoff

Only emulator 5582/API37 was operated; no physical Pixel, emulator 5554 or Systems-owned 5580 operations occurred. Production service is running, UUID/pin were reverified, the temporary exact-owned verification forward was removed, and the original scoped broker 53979 resumed. Mac received direct ownership of 5582. No further runtime operations are pending from this Android checkpoint.

Existing QA trust and receiver were preserved. Singleton upgrade fixtures reassert clipboard=true/profile=battery; real-trust export choices were not changed. Remaining installed Mac/build3, authenticated trust update/alias rollback, performance/resource/recovery, final security review, public release delivery and physical Pixel gates remain with their assigned owners.
