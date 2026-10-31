# Independent Android code4 checkpoint

Reviewed and executed on 2026-10-30 against the frozen signed companion0.2.0/versionCode4. This checkpoint accepts the Android changes below; it does not accept the full companion release or public Mac installer delivery.

## Artifact and actual execution

- Product APK `.build/companion-heartbeat-candidate/DroidBridgeCompanion.apk`, SHA-256 `51a776498d3774317c7fea79de0494b7ae97fc92344a5014229245459b58e4f1`.
- All frozen production/test source hashes matched `manifest.json`; installed APK bytes were read from the assigned emulator and matched the candidate hash. `heartbeat-code4-installed-api37.json` records this check.
- Persistent release certificate SHA-256 `eb482305a29dfa3c7056f2a8eb6162eff9c123e2de6f85601284ca8967cd98c4`, verified independently with apksigner; full output `heartbeat-code4-release-certificate.txt`.
- `heartbeat-code4-api37-instrumentation.txt`: **19/19 actual release-signed tests pass in49.989s**, including real TLS/server requests, scoped security, catalog, transfers, snapshot heartbeat, strict metadata and offline notices.
- `heartbeat-code4-api37-large-text.txt`: **4/4 UI/license tests pass in10.603s** with physical1280px width/density640 =320dp and font_scale2.0. `heartbeat-ui-{original,restored}-api37.json` prove restoration to font1.0, physical density480 and1280x2856 with no override.
- Only emulator5582/API37 was operated. No physical Pixel, emulator5554 or Systems-owned5580 operations were performed.

## Review findings

`updatePeerState` is serialized with revoke, rechecks current trust, admits unchanged snapshots only after a full snapshot, and refreshes timestamps without discarding sessions/audio/profile. The negotiated capability is `state_heartbeat`. The delta schema is exactly `{request_id, unchanged:true}` with optional protocol; it rejects contradictory fields and non-Boolean values. Systems was informed that connection_state belongs in full snapshots. Existing real TLS tests exercise preservation, missing prior snapshot409, ambiguity400 and post-revocation refusal. End-to-end broker cadence/bytes/performance remain Systems-owned.

`ReleaseDelivery` performs an explicit user-initiated HTTPS lookup of the fixed official versioned manifest, sends no phone identity/trust/content, validates size/strict UTF8/duplicate and depth rules, and binds architecture/minimum macOS/hash/signing/version plus exact official download/release URLs. Redirect hosts and response bytes are bounded; there is no arbitrary installer URL from peer data. Android only opens/copies the validated link after explicit action and never installs Mac software. The checksum is correctly described as byte integrity rather than Developer ID identity. Background work is separated from UI and cancelled on Activity destruction.

Timing observation: the10s elapsed-loop budget is not a strict wall-clock socket deadline because a final blocked read can consume up to its5s read timeout. This remains bounded and is outside device transport; do not describe this lookup as an exact10s absolute deadline. No production change was made by this reviewer.

`ThirdPartyActivity` is unexported, uses fixed bundled asset names, exposes the shipped ZXing/Kotlin/annotations notices offline, and has a usable Done action. Actual installed native-view tests passed at normal and large text. APK ZIP filename case matches Apache-2.0.txt.

## Update and trust boundary

`heartbeat-upgrade-before-api37.json` and `heartbeat-upgrade-after-api37.json` show actual signed code2→4 `adb install -r`, without uninstall/data clear, preserving device UUID `d562ee9a-1236-4f3c-a0ae-1f47a1b345fa` and exact TLS pin `82f9aeab82dcb375f75a490ad81a064e315da5211e033c8938928a930b05ee8d`. The new capability appears after update. This public identity proof does not establish accepted Mac Keychain trust continuity; that requires authenticated Mac evidence.

The isolated Peer test stores use separate private preferences/files. Singleton tests revoke only the newly created test trust, not an existing QA trust. The upgrade fixture reasserts clipboard_enabled=true/profile=battery. During server tests, a polling QA broker can observe fixture401/identity mismatch, so Root coordinated pausing that exact scoped broker. Its code does not erase Keychain credentials for poll failure. The earlier apparent stall resolved as the long security case; no deadlock was established.

After tests, native Start connection service was used, production pinned public hello verified again (`heartbeat-restored-api37.json`), temporary exact-owned verification forward removed, and5582 returned to Root/Mac. The broker had already removed/replaced its original transport forward during reconnect; no broker-owned forward was deleted by this reviewer. No production code was edited or APK rebuilt here.

## Remaining acceptance gates

The exact public versioned manifest/installer is not yet verified downloadable: C14 remains open. Actual Mac authenticated reconnect/trusted update, Forget/re-pair/alias rollback, source-bound installed macOS M1, notification producer/reply/filter cases, full throughput/recovery/resource gates, independent final review and physical Pixel verification remain open under their assigned owners. These19 tests are not claims of those outcomes.
