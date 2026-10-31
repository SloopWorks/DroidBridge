# Android code9 pairing wire contract checkpoint

Status: signed API35 full30/30 passed in257.053seconds;320dp/200%-text8/8 passed in18.675seconds. Superseded by code10 UI-copy correction. This is not full-program acceptance.

## Root cause and exact fix

Actual Mac pairing failed because Core requires each pending/approved poll response pairing_id to match the admitted pairing ID, while Android pollPair returned only status and clock/credential fields. Prior Swift fixtures contained the field, while Android tests checked status or consumed direct store output without asserting this mandatory wire identity. Compilation and the prior28 Android tests could therefore pass despite the cross-boundary mismatch.

Code9 adds canonical pairing_id from the validated current pending record to BOTH pending and approved GET/v1/pair/<id> responses. Core's exact-ID check is unchanged. Wrong ID, replaced ID, wrong secret and denied/expired pairing still fail closed. No compatibility fallback or weaker identity validation was added.

## Artifact

`.build/companion-code9-candidate/DroidBridgeCompanion.apk`, version0.2.0/code9, SHA256 `bdc1d8bd2ae2f46917a738054ef1a9482095ee58592f9e53e11853c36e8ad084`, 2,860,647bytes. Test SHA256 `bd101a57acdc11d8df8f00ad92a93fb1da3588fd26ae5b5b0ff0c25d0f46e80b`. Same local signer `eb482305a29dfa3c7056f2a8eb6162eff9c123e2de6f85601284ca8967cd98c4`. Candidate manifest binds exact source/APKs; offline notice assets match and test/provider classes are absent from productDEX. Release build/unit/lint passed (code9-build.log). Code8 artifact/proof is preserved and superseded.

Same-cert install-r8→9 preserved device UUID, TLS pin and settings (code9-upgrade.json and raw before/after logs); no uninstall/data wipe/rotation.

## Actual wire regression

The signed instrumentation starts the production BridgeHttpServer with an isolated Android store and real Android Keystore identity. It sends actual HTTP over pinnedTLS using PinnedTestClient, not a mirror DTO/mock. POST/v1/pair admits the exact ID. GET pending and approved return200 and canonical matching IDs; repeated approved polling retains the same ID/credential. Wrong IDs return400, wrong secrets401; replacing the pending pair prevents old-ID/old-secret polling and deny closes the replacement. Only approval itself uses the store's explicit consent method; all response identity assertions inspect actual server JSON bytes parsed from HTTPS.

Focused2 tests passed in1.808seconds (code9-api35-focused.log). Sanitized evidence records only transport, status, schema field names and matched/rejected booleans. It does not emit pairing secrets or credentials. Pending wire fields are clock_epoch,expires_uptime_ms,pairing_id,status; approved adds capabilities,credential,device_id,protocol,trust_id.

## Audio receipt copy

Thin durable result projection now preserves typed output_confirmed. For set_audio_route/retry_audio with committed intent and output_confirmed=false, native Recent actions and announcements say the audio preference was saved but output is unconfirmed. Existing live audio status and retry controls remain visible. The actual native-view regression checks the persisted false value and the saved/unconfirmed text, and rejects the prior generic completed label. No physical audibility is inferred.

## Large-text evidence

Actual signed code9 passed8/8 native UI tests at320dp/200% text in18.675seconds (`code9-api35-large8-attempt1.log`), including saved/unconfirmed audio copy. File review645ms with unchanged0query/0type/0open counts and preserved draft after Cancel. Consent actions retain full native intrinsic layout and48dp minimum targets. Baseline restored to physical density420/no override/font1.0, with intentional developer1/ADB1 preserved (`code9-ui-restored.json`).

## Full-suite result and superseding copy review

code9-api35-full-attempt1.log records30/30 passing, including actual wire polling,120-second expiry/admission,30-second stalled read/query, receipt/restart security and native views. Independent Security then rejected the persistent expired-action label suggesting blind repetition. Code10 changes that label and related uncertain-submission guidance, adds a real30-second expired/unknown UI regression, and requires its own exact-artifact UI gates. Backend/TLS/pairing code is unchanged between9 and10. Code9 evidence and APK are preserved.
