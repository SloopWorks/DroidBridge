# Android code8 admission and consent checkpoint

Status: signed API35 full28-test and320dp/200%-text7-test gates passed. No full-program acceptance claimed.

## Exact artifact

Signed product `.build/companion-code8-candidate/DroidBridgeCompanion.apk`: version0.2.0/code8, SHA256 `0bddc834ac688fedb23d18138a59ea39c6fd7f4d3ecda0d0f63759d8ab999ee9`, 2,860,059bytes. Signed test SHA256 `340a57014faa15f4f1328cac2dc646ba2f82bffdd2dc8f42f0cb9fe727334d13`. Persistent signer `eb482305a29dfa3c7056f2a8eb6162eff9c123e2de6f85601284ca8967cd98c4`. Exact source/artifact bindings are in candidate manifest.json. Offline license bytes match; test provider classes are excluded from productDEX. Release compilation/unit/lint passed (`code8-build.log`).

Same-cert code7→8 install-r preserved UUID/pin/settings (`code8-upgrade.json`, before/after raw logs). Code4→7 continuity is separately retained. No phone data wipe or identity rotation was used.

## Bounded admitted lifetime

Root independently rejected code7's unlimited admitted-outcome lifetime. Code8 records first admission epoch and elapsedRealtime once before acknowledging it. Identical admission retries retain that original time. After120,000ms unresolved admission becomes durable unknown with admission_outcome_unknown; it is eligible for bounded terminal history eviction, never replay. Process/epoch loss also retires accepted/admitted as unknown. A later remote result cannot overwrite locally retired unknown (409command_outcome_retired). Timely admitted work may still complete after the original30-second command deadline within that120-second admission window.

Expiry changes are journaled before publication with rollback on persistence failure. Trust and recipient are checked before receipt expiry/read. Unknown never means the remote effect did not happen.

Focused actual API35 test filled32 admitted slots, rejected a33rd, proved duplicate timestamps unchanged, restarted the isolated peer, verified32 unknown/no replay events, rejected late terminal overwrite and admitted a new successor UUID: PASS0.414seconds (`code8-api35-admission-focused.log`). Full28-test gate passed in234.42seconds (`code8-api35-full-attempt1.log`). Large7 gate passed in20.205seconds (`code8-api35-large7-attempt1.log`).

Code8 retains code7's exact pairing consent binding, no-provider-I/O preconsent file review, text-only bounded clipboard Paste, monotonic clock_anchor_v1 protocol and saved Spotlight intent/pending materialization/retry UI. See CODE7_CONSENT_CLOCK_REPORT.md for scope and platform limitations; code7 is explicitly superseded.

## Executed full-suite evidence

Actual120,302ms pairing/admission test: expired Trust tap created no trust; first admission retired unknown after120s despite a duplicate at60s; a late terminal could not overwrite it; a midpoint admission completed truthfully after its original30s command TTL while younger than120s. C10 review appeared in709ms with query/type/open counts all0 before and after Cancel. Clipboard tests rejected URI/UTF16/UTF8 oversized input without replacing the draft, accepted bounded direct text, and restored the original clipboard. Android's asynchronous MIME classification at clipboard setup was explicitly observed before measuring Paste.

Actual stalled-provider timings: pipe deadline30,039ms; cancellation-aware query deadline30,007ms; explicit Cancel6ms. Both worker capacity checks recovered. TLS1.2 and1.3 negotiated with unchanged installation leaf; wrong pin and plaintext rejection tests passed. Canonical receipt capacity/restart, scoped trust/revoke, transfer/hash, heartbeat and all native default-font UI cases passed.

## Handoff state and remaining gates

All frozen source hashes still match the code8 manifest. Actual installed base.apk SHA256 matches the candidate, recorded in code8-final-checkpoint.json. API35 baseline restored to physical density420/no override and font_scale1.0; intentional lab developer_settings1/adb_enabled1 preserved. Product is force-stopped and foreground connection service is off. No new ADB forwards were created. Existing trusts/receiver were protected by per-test assertions; tests created and removed only their named temporary trusts. No physical device, user5554 or Mac-owned5582 was operated.

Independent root/UX/security review of this exact candidate and installed Mac code8 interoperability remain release gates. API37 code8 and changed-version trusted-Mac upgrade/Forget/re-pair continuity are not proven by this API35 checkpoint. The full companion program, public delivery and final physical Pixel stage remain separate. No commit, push or overall completion claim was made by this agent. Prior code6/code7 APKs and failed evidence were preserved.
