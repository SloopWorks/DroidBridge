# Local-network popup repair

1. Preserve the incident evidence. Confirm the identity collision and distinguish the responsible PID reported by macOS from the actual network syscall (not yet traced).
2. Personalize every generated app's main Mach-O UUID, including Player, before ad-hoc signing. Verify payload provenance independently of the changed UUID/signature. Keep Android icons, independent processes, exact-device launch intent and live-session reuse.
3. Make retained backups nonlaunchable, preserving their bytes and restoration metadata. Migrate only validated owned backup paths, defer running apps, and unregister exact backup URLs. Existing current wrappers upgrade through the existing stopped-reader repair flow.
4. Disable automatic ADB mDNS browsing in DroidBridge-started children; preserve explicit pairing/connect, USB and existing shared ADB servers. Add useful local-network purpose strings and stable bundle association to installed per-user agents. Do not alter privacy settings or shared ADB server lifetime.
5. Run malformed-binary/provenance and backup-migration tests, resolver/factory regressions, package build 23 outside .build, then run real emulator native/fallback app launches and inspect UUIDs, signatures, logs and visible video. GUI launch is necessary because terminal-origin tests can bypass local-network privacy checks.

Acceptance requires executable Android video and migration evidence. Certificate-backed signing, clean-account permission persistence and physical Pixel verification must be reported separately if unavailable. No notarization, upload, push, privacy bypass, shared-server termination or unrelated emulator actions.

References: Apple TN3178 and TN3179. Incident evidence is in ../local-network-prompts-2026-11-08/.
