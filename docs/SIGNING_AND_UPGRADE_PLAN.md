# DroidBridge signing and upgrade plan

Prepared November 3, 2026. Scope: an executable work plan and current-state assessment; no signing credentials, enrollment, installed applications or external accounts were changed. The target remains the full DroidBridge workflow, including independent Android-app launchers, audio, companion controls and safe upgrades.

**Subsequent implementation:** the original assessment below is retained as a
dated record. The public-beta work now verifies the live organization membership
and implements a Developer ID packaging lane plus delivery metadata validation.
An ad-hoc regression passed; the Developer ID lane is not yet accepted. See
[the current beta ledger](PUBLIC_BETA_STATUS.md) and
[organization observation](../verification/public-beta-2026-11-03/apple-organization-observation.json).

Company account facts remain owned by the canonical [SloopWorks organization record](/Users/patrick/workspace/SloopWorks/org-facts.md), [Apple enrollment task](/Users/patrick/workspace/SloopWorks/ops/tasks.md:22), [filing log](/Users/patrick/workspace/SloopWorks/compliance/filings-log.md) and [renewal calendar](/Users/patrick/workspace/SloopWorks/compliance/calendar.md). This document is a dated product assessment, not a replacement company registry.

## Status established by this review

| Area | Evidence and conclusion |
|---|---|
| Organization enrollment | Canonical SloopWorks records say approved/paid, with auto-renew enabled. Membership is already budgeted company-wide; do not buy a second enrollment for DroidBridge. Use the organization account/team identified there. |
| Current browser portal | A read-only visit to Apple Developer Account showed the historical **personal** Individual team and its expired 2016 membership. This agrees with the warning in the organization records. It does not show that the organization membership expired. The organization's authenticated live membership/agreements screen still needs checking under its own account. |
| Local signing identities | `security find-identity -v -p codesigning` lists Apple Development and SloopWorks Apple Distribution identities, but **no usable Developer ID Application identity**. A certificate could exist elsewhere or lack its private key locally; this command is not an inventory of all portal certificates. |
| Existing artifact | `dist/DroidBridge.app` remains ad-hoc signed with no TeamIdentifier. Existing compilation/unit/offline-signature passes do not establish Developer ID signing or notarization. |
| Earlier agents | The Apple-specific Claude session identified by the company-record chat reported successful organization setup, signed iPhone installation and PickedPlate TestFlight upload in August. That is evidence of an App Store workflow, not DroidBridge Developer ID/notarization readiness. No active enrollment worker was identified in the checked records. |
| Credential follow-up | That historical agent reported an exposed Admin API private key and requested revocation. Revocation/replacement status was not verified here. Do not reuse historical transcript credentials. Confirm that follow-up before selecting notarization authentication; no key material is included in this plan. |

Read-only commands and observations are retained in [verification/signing-plan-2026-11-03](../verification/signing-plan-2026-11-03/), including [portal scope](../verification/signing-plan-2026-11-03/portal-observation.json) and [agent observations](../verification/signing-plan-2026-11-03/agent-observations.json). No other agent was messaged or dispatched. SloopWorks' existing uncommitted compliance changes were preserved.

## Recommended order

| Step | Work and responsibility | Exit evidence |
|---|---|---|
| 1. Establish the release identity | Account Holder: use the organization account, inspect live membership/agreements and existing Developer ID certificates. Release engineer: inventory public certificate metadata and local private-key availability. | Correct organization selected; usable Developer ID Application certificate/private key available; notarization authentication confirmed. Any agreement acceptance or new credential creation is a separate owner-authorized action. |
| 2. Resolve independent-wrapper trust | Mac engineer: build a private signed/notarized candidate and test its exact existing wrapper-creation path on an account/Mac with no prior DroidBridge trust decisions. | Finder, Dock, Spotlight and Cmd+Tab behavior observed for independent launchers under default security settings, including update and fallback. Record which code is Developer ID signed and which wrapper envelope remains locally generated. |
| 3. Implement release signing | Release engineer: add a strict Developer ID packaging mode; sign all owned executable dependencies, rebuild signature-dependent inventories and notarize/staple final deliverables. | Every executable/nested bundle validates, notary submission is Accepted, tickets validate, and the genuinely downloaded copy passes Gatekeeper and actual runtime checks. |
| 4. Deliver the one-time migration | Core/Mac engineer: retain existing application/storage identities, migrate compatible settings and managed wrappers, and provide bounded recovery for legacy Keychain ACL failures. Android engineer: retain release package/signer and implement explicit compatible update checks. | Actual old ad-hoc → first signed migration preserves the tested data and provides a deliberate re-pair path when required. Existing app/window/helper ownership is preserved. |
| 5. Add normal updates | Mac/release engineer: integrate a pinned Sparkle 2 version into the main application and a single coordinated wrapper/helper migration flow. | Two real signed/notarized versions update through the actual installer, with invalid updates refused and interrupted upgrades recoverable. |
| 6. Add trial/paid entitlement | Core/Mac engineer: one policy shared across all launch/control paths; managed checkout and activation, trial persistence and offline rules. | Activation/trial state survives upgrades, wrappers and phone actions cannot bypass admission, cleanup never depends on payment, and outage/expiry cases pass. |
| 7. Accept and publish one cohort | Release engineer + independent QA, with owner physical verification and final publication authority. | Exact-source/artifact/source-license cohort, installed emulator evidence, owner hardware results and public downloaded-copy evidence support every advertised feature. |

Do steps 1–3 before committing to a paid-release date. Complete the manual migration in a technical prerelease; complete the normal updater before a broad paid launch. There is no need to wait for Apple enrollment again according to the canonical company records. The unresolved operational prerequisite is access to the correct organization and its Developer ID/notarization credentials.

## 1. Credentials and account boundaries

Use **Developer ID Application** for direct-distribution Mac apps and tools. The existing Apple Distribution identity is not the substitute for this lane. A Developer ID Installer certificate is unnecessary while the product ships a DMG/ZIP rather than a PKG. Check for an existing usable certificate before creating another; Apple limits certificate issuance. [Apple Developer ID certificate guidance](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/).

Keep certificate private keys in Keychain, with an encrypted recovery backup in the established company secrets system. Choose a verified notarization credential stored as a local Keychain profile or a suitably scoped supported API key in the company secret store. Do not place `.p8`, `.p12`, app-specific passwords or secret values in Git, product resources, verification logs or chat. Check the reported historical key's revocation before reuse of related automation. App Store Connect supports multiple key types with different capabilities; do not assume an existing individual/team key can perform notarization solely because TestFlight upload once worked. [Apple API-key guidance](https://developer.apple.com/documentation/AppStoreConnectAPI/creating-api-keys-for-app-store-connect-api), [notary authentication](https://developer.apple.com/documentation/notaryapi/submitting-software-for-notarization-over-the-web).

For this direct-sales lane, App Store Connect app listings, Paid Apps banking/tax setup and Small Business enrollment are not the signing gate. Applicable Developer Program agreements still need to be current. The separate merchant-of-record onboarding remains necessary before accepting payment. Do not change the historical personal membership or revoke unrelated certificates used by other SloopWorks products.

## 2. Independent app launchers are an early engineering gate

The current factory copies the host executable/runtime, personalizes Info.plist/icons/configuration, and ad-hoc signs the generated wrapper and its Player. Simply applying a Developer ID signature to the source app cannot make every personalized derivative a notarized app.

First determine the actual behavior of this locally generated workflow from a genuinely downloaded signed main app: generated-app creation, provenance/quarantine behavior without stripping attributes, first and subsequent launch, separate Dock/Cmd+Tab identity, Spotlight activation, native/fallback input and update. Do not infer this from `codesign --verify`, bundle IDs or a developer Mac's accumulated trust. Preserve a portable independently launchable workflow as the requirement; main-process windows alone do not close this step.

If the locally generated envelope works under normal security settings, document its precise trust boundary rather than calling every wrapper notarized. Evaluate a small per-app launcher with immutable signed executable code and a controlled local descriptor, reducing copied mutable runtime while preserving the independent application identity. Any change to portability/shared-runtime dependence needs an explicit design decision and acceptance evidence.

If default-security launch fails, prototype an alternate independent-launcher design and seek Apple technical guidance before selecting it. A fixed signed runner plus shortcuts may be a useful diagnostic alternative, but is not automatically equivalent to the promised per-app Mac identity. Keep the gate open until the chosen design meets that promise. Do not ship signing private keys, suppress Gatekeeper, clear quarantine to manufacture a pass, or claim notarization transfers to changed bundles.

## 3. Release pipeline changes

Primary files: `scripts/package.sh`, ADB/audio/runtime build/staging scripts, `scripts/verify-package.py`, `scripts/create-release-manifest.py`, Swift `CompanionReleaseMetadata`, Android `ReleaseDelivery`, packaging/source manifests and relevant tests.

1. Add explicit **development ad-hoc** and **release Developer ID** modes. Release mode must fail when its intended identity/team, timestamping, executable signatures or notarization evidence is unavailable; never silently fall back to ad-hoc. Keep scrcpy client/server pinned to 5.0.1.
2. Complete relocations and bundle layout first. Sign libraries, tools, supervisors, broker, availability helper, audio client and nested Player inside-out, then the enclosing application. Apply hardened runtime to executable targets and audit the minimum necessary entitlements against actual runtime behavior. Avoid blanket library-validation/JIT/debug exceptions as a shortcut.
3. Account for signed-byte hashes: the source-built ADB cohort, helper generations and Player library inventory contain hashes of executable files. Re-signing changes those bytes. Generate the release inventories/provenance bindings after the final relevant signatures; verify portable-copy identity again. Do not re-sign installed helper generations or edited customer wrappers with a development identity.
4. Notarize the completed application payload, preserve the submission ID/log and verify Accepted status. Staple/validate the app ticket before generating the final ZIP. Build/sign/notarize/staple the DMG as appropriate to the selected Apple workflow. Compute published archive hashes only after all changes to those archives are finished. No post-sign bundle edits.
5. Change **all three delivery-policy participants together**: `create-release-manifest.py`, Swift validation and Android validation currently require `ad_hoc_not_notarized` and version 0.2.0. Define a versioned release metadata contract for the reviewed signing state, expected team, source revision, platform, URLs, sizes and hashes. Keep validation strict; metadata text alone does not prove signature trust or notarization. An already-installed old companion will require an explicit APK update before it can consume the changed contract.
6. Produce one immutable candidate per public version/build, with matching companion signer/versionCode, exact dependency notices and corresponding-source artifacts. Source provenance and signing evidence must bind the final cohort, not an earlier ad-hoc candidate. Leave publication as the final authorized action.

## 4. Upgrade contracts

Keep the current desktop bundle ID, broker/availability service labels, managed app identities and data paths unless a concrete capability forces a migration. The company bundle-ID namespace convention is not a reason to gratuitously rename existing identities during first signing. Document any necessary identifier migration as a separate compatibility change.

**Current ad-hoc → first signed version:** use a manual verified DMG install. The upgrade UI inventories only DroidBridge-owned main/wrapper/audio/helper processes and offers a graceful close/defer choice. Drain in-flight work and owned cleanup before replacement; never kill the shared ADB server, the user's emulator or unrelated processes. Copy the main app to its installed location, launch it once, then run the migration. Retain launch settings, Android icons, wrapper names/paths, export choices, saved content and session intent. Update idle wrappers atomically, keep usable previous generations, and queue running wrappers for later rather than overwriting their executable files.

The existing broker intentionally refuses interactive Keychain access. An ad-hoc → stable signed identity change may deny access to old trust records. Test it first; migrate through supported Keychain authorization when possible, otherwise explain and offer explicit local Forget/phone revoke/re-pair. Never silently delete credentials, widen their ACL to all apps, or export bearer credentials to a plaintext file. Future signed N→N+1 releases must preserve access under the intended stable signing requirement; certificate replacement needs its own regression.

**Background helpers:** stage a complete verified generation, hold existing cross-process leases, negotiate compatible broker/owner protocol versions, then switch the exact owned service registration. New and old processes must not interpret incompatible journal data or command receipts. Refuse incompatible owners with an actionable update message. Retire only unreferenced verified generations and retain recoverable journals. Sparkle replacing the main bundle does not by itself update all existing private helper generations.

**Android companion:** keep `dev.droidbridge.companion` and the existing release signer. Back up its signing key securely; do not substitute a debug/development signer. Increment versionCode for released updates and verify old→new data/trust preservation. Negotiate capability/protocol changes so a Mac update does not require destructive uninstall/reinstall. Keep `.dev` separate. OS-level Android downgrade restrictions mean rollback is not the same as restoring an old APK; use a compatible forward fix with a higher versionCode and preserve data.

**Paid-state upgrades:** keep trial dates, entitlement version eligibility, activation instances and recovery paths separate from ordinary preferences. A reinstall, wrapper refresh or update must not reset the trial or use another activation slot. Before a paid major upgrade, show eligibility/price and retain a download path for the customer's licensed compatible version. Continue offering applicable fixes and update information even when a new paid major version is declined.

## 5. Normal updates after the transition

Use **Sparkle 2 in the main application only**; wrappers route “Check for Updates” to the main application. Pin the chosen package version, sign its nested components correctly and keep its required notices. Use an HTTPS appcast and Ed25519-signed archives, with the public update key embedded in the app and the private signing key retained separately from hosting credentials. Preserve an authorized key-rotation path. These are separate concerns from Developer ID signing. [Sparkle's official setup/security guidance](https://sparkle-project.org/documentation/).

Offer explicit Check for Updates and opt-in automatic checks; defer installation while owned sessions/transfers are active unless the user chooses a controlled stop. Let Sparkle handle the supported main-bundle replacement flow; let DroidBridge own wrapper/helper/data compatibility and post-update verification. Start with full update archives. Delta optimization is unnecessary until full N→N+1 and interruption recovery work.

Use GitHub Releases for immutable archives and a stable HTTPS location for appcast metadata, selected alongside the paid-product hosting policy. Begin with the existing public release page/check link in the first signed technical prerelease. Introduce Sparkle in that tested signed base, then verify an actual second signed/notarized version before a broad paid launch. No custom binary-update downloader/installer is recommended.

Rollback keeps a known compatible signed version and wrapper/helper recovery information. Do not promise rollback of already-migrated data without a tested reversible schema or backup restoration path. Never automatically retry a phone command with an uncertain outcome just because an upgrade restarted a process.

## Required verification matrix

| Scenario | Evidence needed |
|---|---|
| New installation | Real HTTPS download with normal provenance, copied app outside build/DMG directories, expected Developer ID/team, notarization/stapling checks, launch under default Gatekeeper. |
| Product runtime | Actual changing decoded Android video, OS-routed input/resize on both advertised backends, audio runtime initialization and physical audibility tested separately, exact owned-process/forward/display cleanup. |
| Generated launchers | Separate app identities, Finder/Dock/Spotlight activation, first launch and launch after main-app update, native/fallback behavior and retained app icon/name/settings. No prior security exception used as acceptance. |
| Legacy migration | Frozen real ad-hoc candidate → signed candidate with existing trust, managed wrappers, helpers and saved data; expected bounded Keychain recovery where necessary. |
| Normal upgrade | Two real signed/notarized versions through Sparkle, stable entitlement/trust/settings, compatible helper/wrapper generations and correct first launch. |
| Refusal/recovery | Corrupted/wrongly signed update, wrong team, unsupported OS, unavailable network, unavailable notary evidence in release mode, running wrapper, interrupted staging/install and incompatible protocol/schema. |
| Android update | Same-signer old/new APK with increasing versionCode, retained installation identity and pairing, explicit refusal of incompatible signer/protocol, update without data-clearing. |
| Trial/paid state | Trial/paid/expired/offline users retain correct state across all upgrade paths; admission gated consistently and save/stop/revoke/uninstall remain available. |
| Release identity | Clean reviewed source revision and exact final app/APK/archive/source hashes; public metadata matches real downloadable bytes. |

Run device work serially against dedicated `DroidBridge_API35` / `emulator-5580`, with deterministic fixtures. Preserve `emulator-5554`. Physical Pixel 10 Pro USB/Wi-Fi, sleep/wake, thermal, screen-off and audible-output acceptance stays with the owner. Keep executed commands/output and failed attempts under `verification/`; compilation or unit assertions cannot close the installed acceptance rows.

## Immediate next work item

**Verify the organization Developer ID/notarization prerequisites, then produce the private signed/notarized wrapper-trust prototype.** This is the earliest experiment that resolves the largest distribution risk. If the organization portal is accessible only through a different Apple account, the Account Holder should use that account in an appropriate separate browser session; the current personal account's Renew button is not the solution. No enrollment fee or new paid infrastructure is expected for this step under the existing membership.

The implementation/release steps above remain unexecuted and are not represented as accepted deliverables. Only the plan and its read-only assessment evidence were produced here.
