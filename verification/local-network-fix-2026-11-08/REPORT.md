# DroidBridge local-network popup repair — 2026-11-08

Local popup-fix acceptance: **passed with the limits below**. Build 23 is installed at `/Users/patrick/Applications/DroidBridge.app`. The exact external review artifact is under `~/Library/Application Support/DroidBridge/ReviewBuilds/local-network-fix-23/`. Main executable SHA-256: `d241ddb9e897254e2943b53bd239a587c3a1d5d7d17c95d3546a8df519e5090b`. Signing is ad-hoc; this is not a notarized release.

## Findings and repair

The reported `jj.app.cyf-E2A3DA8E-17D8-4754-A1C5-E1089AC2CE62` was a retained Challenge Your Friends wrapper. Different bundle IDs reused the main app's build-20 executable UUID `B77BBDC5-BEA5-3F7B-A7A3-62870B2EC411`. macOS logs resolve requests attributed to the old PID829/UUID to unrelated wrapper IDs and show alerts bearing backup filenames. Apple TN3178/TN3179 describe this identity collision. This is packaging/identity attribution, not evidence that those Android apps independently requested Mac network access.

Generated main and Player executables now receive deterministic, distinct per-bundle UUIDs in every architecture before signing. Stopped-app reuse verifies actual normalized code against the installed host. Read-only scrcpy staging copies temporarily gain owner write permission and regain their original mode. Meaningful purpose strings and agent bundle associations were added. DroidBridge-started ADB children disable unused automatic mDNS browsing; explicit wireless pair/connect remain available. Existing shared servers are preserved.

Backups retain their exact signed metadata under `DroidBridgeRetiredInfo.plist`; outer and Player apps become nonlaunchable. Exact URLs are unregistered with independent Launch Services absence verification. Already-absent copies, partial migration, invalid entries, running paths, cancellation, and pending publications are handled. A forced rescan can create a generic launch-disabled/no-info.plist placeholder, but cannot recover the old bundle identifier or executable UUID; it must not be described as guaranteed absence of every database row.

## Executed evidence

- Full suite: 364 tests, four skips, zero failures (`swift-test-final.log`). After the final narrow backup/read-only refinements, 61 focused tests passed (`focused-unregistered-fix.log`).
- Resolver: 21 shipping-code checks passed. Packaged runtime: all 17 cases passed, including actual native decoded Android content, fallback video texture, independent Android icons/UUIDs, stopped/live reuse, cancellation, rediscovery and exact cleanup (`runtime-accepted/`).
- Independent GUI launch: visible Android test display7 ticks advanced21→488, and a real click incremented the Android counter. Screenshots and AX state are saved. The152-second window also recorded two incorrect *old-backup* prompts during migration; it is not a no-popup acceptance pass.
- All931 original backups (927 managed, four manual) migrated through production APIs. All1862 original outer/Player Info files remained byte-identical (`actual-migration-metadata.json`). The exact reported backup was restored in a private COW copy and its complete original signature verified (`original-backup-restore-signature.json`). No original backup was deleted.
- All264 existing catalog apps now use build23. Audit verifies528 distinct main/Player UUIDs against the installed source, original icons and complete launch intent (excluding the new generation ID), and zero pending publications/registrations (`actual-wrapper-audit.json`). One early Python probe failed to URL-decode a filename and incorrectly suggested a missing QR app; the production URL handling and final audit correctly include all264 apps.
- An obsolete ignored `dist/DroidBridge.app` was the last Launch Services record for the old UUID. Its bytes remain as `dist/DroidBridge-build20.retired` with metadata parked. The previous installed build is in the verified, nonlaunchable `ReviewBuilds/pre-popup-fix-20.zip` archive.
- An isolated owned ADB server verified `MDNS_DISABLED` with USB and emulator scanning disabled. The existing shared server PID987 was preserved throughout implementation, then stopped once after the user explicitly approved one restart. The replacement SDK server PID2056 was preserved. The dedicated emulator5580 and exact disposable scopes were cleaned up; no emulator5554 action occurred.

## Completed rollout and observation

All264 existing wrappers were upgraded and audited. The user explicitly approved one ADB restart after reviewing the concrete fix. The exact old server PID987 was validated and stopped once. The replacement PID2056 reports the Android SDK platform-tools executable and mDNS enabled; no second stop occurred. This was not a DroidBridge-owned disabled-mDNS server, and its starter was not established.

Both native and fallback video then passed all17 runtime checks again using the installed artifact (`runtime-after-restart/`). The dedicated emulator was stopped and its forwards/scopes cleaned up. The installed GUI was reopened for the owner. The final332-second post-restart observation recorded zero DroidBridge local-network alerts and zero old-UUID blocked requests (`after-authorized-restart.json`). No privacy permissions or databases were changed.

Causal limit: the final three minutes immediately before the restart also had zero old-UUID blocked records. The evidence therefore supports the completed identity/backup migration as the repair; it does **not** prove the restart was necessary or identify the exact initial network syscall. Earlier migration windows did show continuing historical prompts, so only the final post-rollout observations count as no-popup acceptance.

Generated wrappers remain ad-hoc signed. Apple-issued release signing and durable privacy permission persistence across updates remain separate release work. Physical Pixel verification is owner-deferred. No public upload, push or notarization claim was made.

Primary references: https://developer.apple.com/documentation/technotes/tn3178-checking-for-and-resolving-build-uuid-problems and https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy .
