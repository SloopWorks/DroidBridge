# Android code10 uncertainty guidance checkpoint

Status: signed code10 focused4/4 passed32.77seconds and320dp/200%-text9/9 passed53.68seconds. No full31-test pass is claimed for code10.

## Artifact and source scope

`.build/companion-code10-candidate/DroidBridgeCompanion.apk`, version0.2.0/code10; SHA256 `49570ea24a1f4d3fd6207f9e11afa21db6e76d678090d2336770318f30de8e0b`, 2,861,023bytes. Signed test SHA256 `a271a07ae53268fadad7db22ec457f463145d23200d749d971c1d5565c91b86c`. Same persistent local signer `eb482305a29dfa3c7056f2a8eb6162eff9c123e2de6f85601284ca8967cd98c4`. Build/unit/lint passed, notices match, test/provider classes absent. Candidate manifest binds exactsource/APKs.

Manifest comparison with code9 proves the only changed files are MainActivity.kt, app/build.gradle.kts versionCode and CompanionReceiptDeviceTest.kt. All backend, HTTP, TLS, pairing, protocol, transfer and other production hashes are identical. Code9 full30/30 actualAPI35 passed257.053seconds and large8/8 passed18.675seconds; that historical proof is retained separately. Per root's verification decision, code10 runs focused4 (real wire identity, TLS identity and both native receipt cases) and large9. It does not claim a code10 full31 run.

Same-cert install-r9→10 preserved device UUID/TLS pin/settings (code10-upgrade.json), no wipe or rotation.

## Copy correction and audit

Security rejected the persistent label 'Expired · try original action again'. Expiry without a terminal receipt does not prove the Mac did nothing: an inbox/selection intent may already be durable. Persistent expired now requires checking the Mac outcome before retry; unknown requires checking the Mac before repeating. Announcements match, and duplicate suppression describes unknown as uncertainty rather than merely pending. Capacity copy no longer suggests expiry makes repeating safe.

Spotlight selection can durably queue its command before a subsequent local preference/event error. Its failure copy and explicit retry failure therefore describe unconfirmed submission and ask for Recent actions/Mac inspection, rather than falsely claiming nothing was saved or queued. General action submission failure uses the same conservative guidance. Pairing challenge renewal, public metadata refetch and transfer-state inspection remain distinct from replaying remote effects. Explicit audio retry/committed pending Spotlight retry remain user-admitted successor actions.

The new actual native test creates only its named temporary trust, admits two original UUIDs, accepts one unknown receipt, waits the other command's real30-second monotonic expiry with no clock hook, and checks both labels. It requires the journal to retain exactly those two UUIDs: polling must not automatically create a successor or repeat an action. Cleanup removes only that test trust and restores the original receiver.

## Existing uncertainty boundary

The per-Activity duplicate guard intentionally retains unknown command keys, preventing a blind repeated click. At32 unknown local keys it can require Activity recreation to admit more actions; code10 does not silently clear those keys or add an unchecked replay override. Root was notified for any later reviewed explicit acknowledgement flow. Unknown continues to mean an effect may have happened.

## Final executed evidence and runtime handoff

code10-api35-focused4.log: pinnedTLS actual server wire IDs pending/approved/repeated and rejection cases; unchangedTLS identity1.2/1.3, wrongpin and plaintext denial; saved/unconfirmed audio native copy; real30,173ms expiry+unknown native copy with exactly2 original UUIDs/no automatic successors.

code10-api35-large9-attempt1.log:9/9 actual native UI tests passed320dp/200% text53.68seconds. Real30,328ms uncertainty test again had0automatic successors; consent/draft/clipboard behavior and offline notices passed. Preconsent review919ms retained0provider query/type/open counts.

Installed base.apk hash equals the frozen candidate; all manifest source hashes match. code10-final-checkpoint.json records exact verification scopes and explicitly denies a code10 full31 claim. Code9's unchanged backend full30 proof remains separately bound, not relabeled as code10 execution.

Emulator5580 restored to physicaldensity420/nooverride/font1.0, intentional developer1/ADB1, wirelessdebug0. Product force-stopped/serviceOFF. No new ADB forwards, aliases or emulator lifecycle changes. Systems receives exclusive5580 after this checkpoint; no further runtime operations by Android agent. No physicalPixel/user5554/Mac5582 operations were made. Root retains installed Mac interoperability, API37 finalcandidate, independent review and final full-program release gates. No gitcommit/push by this agent.
