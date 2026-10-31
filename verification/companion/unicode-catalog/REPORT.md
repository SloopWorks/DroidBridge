# Android12 Unicode catalog and broadcast routing checkpoint

## Changes

The wire contract remains256 Unicode scalars per label,64 apps per page,4096 apps total and262,144 JSON bytes. Android now truncates at complete scalar boundaries; isolated UTF16 surrogates become U+FFFD. Valid86-scalar CJK labels and256 supplementary scalars retain their content. This is a correction to existing semantics, not a limit increase.

Optional activity_name retains its512 UTF8-byte limit. Oversized or invalid UTF16 identities are omitted from copied wire catalog snapshots/deltas. The private catalog keeps the complete activity component used to retrieve icons; component names are never truncated or replaced. An app is not removed because optional wire metadata is omitted.

An independently reproduced installed catalog-update failure came from `JSONObject.NULL` target handling: `optString` returns the literal string `null`, which previously caused public catalog/profile change hints to be filtered as another trust's events. `eventPage` now distinguishes absent/JSON-null targets from string targets and rejects malformed non-string target records. Exact target matching remains required for targeted events. Notification content and cleanup both explicitly require the authenticated target; nullable broadcast control metadata does not widen notification delivery.

## Frozen candidate

- Product: `.build/companion-code12-candidate1/DroidBridgeCompanion.apk`
- SHA256: `bc17d7b1275929f88ac445b5a2b99869982eabafa423eec53ae1c161e684db2b`
- Version0.2.0/code12, bytes2,870,487.
- Persistent release signer SHA256: `eb482305a29dfa3c7056f2a8eb6162eff9c123e2de6f85601284ca8967cd98c4`.
- Test APK: `b0eda9e5f7763c062abe2ee7f72e49f48dd1da762331257dc2e83cbcd15c1552`.
- `code12-frozen-manifest.json` binds all Android app source/test/assets plus build.gradle, artifacts and signer. Prior11 artifacts remain intact.

## Executed verification

- JVM unit8/8 passed, including CJK/emoji/mixed/combining/malformed UTF16 scalar boundaries and activity UTF8 limits. Raw JUnit XML is retained.
- Release and release-test builds, instrumentation Kotlin compilation and release lint completed successfully. Lint reports are retained; no new root/private Android capability is used.
- Offline notice assets extracted from the actual signed APK match source bytes.
- Actual owned API35 emulator5580 booted with existing userdata. `runtime-before.json` captures its baseline. No shared ADB lifetime operation or other device was touched.
- Actual install-r11→12 preserved public phone UUID, TLS pin and settings; installed base.apk SHA256 matches frozen candidate. Before/after raw snapshots and `code11-to12-upgrade.json` retain the evidence.
- Installed signed12 focused3/3 passed through real pinned TLS:65-row Unicode fixture snapshot/pagination, changed combining-label delta, byte cap, optional activity omission/private identity retention; two trusted peers receive JSON-null public hints while targeted/literal-null/malformed events remain isolated; unauthenticated request401; actual TLS1.2/1.3 identity gate. See `code12-focused3-attempt1.log`.
- Full36 actual instrumentation: PASS36/36 in285.923s (`code12-full36-attempt1.log`).
- Large text9 cases: PASS9/9 in46.425s with540density/200%font,320dp-wide configuration (`code12-large9-attempt1.log`).
- Final source hashes all match frozen manifest. UUID/pin/settings still match code11 baseline after all tests. Font1.0/physical420density, developer1/ADB1/WiFi-debug0 restored/preserved; notification listener empty and test posting permission denied. Product/test processes force-stopped, no owned forwards, display[0]. Exact owned5580 emulator terminated gracefully; PID95722 gone and console/ADB ports5580/5581 closed. See restored/off JSON evidence. No physical or other emulator was touched.

## Original APK fixtures for installed Mac verification

Built and aapt2-verified, without device operations by this agent:

- `dev.droidbridge.unicodefixture.cjk`:86 CJK scalars/258UTF8 bytes. `.build/unicode-label-fixture/UnicodeCJK-v1.apk`, SHA256 `f79db3d34eeb65a3f8213ee101c6221ae4921d722c40175f7d076f6857e34a4f`.
- `dev.droidbridge.unicodefixture.supplementary`:255 ASCII plus one supplementary emoji;256 scalars/257UTF16 units/259UTF8 bytes. `UnicodeSupplementary-v1.apk`, SHA256 `f46cf8671358d2539ab8db0477f5916e95ac08d3ad26dbad9b82236a978e9f2c`.

These ordinary permission-free fixtures have distinct package identities and original vector icons. Their build script/source are `scripts/build-unicode-label-fixture.py` and `android/unicode-label-fixture/`. Actual installed Mac source10/APK12 catalog/UI verification belongs to the macOS agent and remains separate from Android loopback TLS fixture acceptance. No physical Pixel verification is claimed.
