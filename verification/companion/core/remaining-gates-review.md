# Remaining companion acceptance gates — read-only review

This is an evidence assessment and executable closure plan, not a change to the
roadmap, a release approval, or a waiver. It incorporates installed Mac build6,
Android10 systems/recovery reports and current notification security findings.
The coordinator is still building/testing the next exact Mac8/Android11 cohort.
Historical passes remain tied to their original source/artifact hashes.

| Remaining gate | Current evidence | Concrete closure |
|---|---|---|
| Frozen final artifact/cohort | Mac6 GUI report is substantial but explicitly predates notification trust hardening; systems/recovery use Android10 and recorded QA6 runtime. | Freeze exact committed candidate after Android11/Core/Mac edits, complete focused + full Swift/Android gates, package8, verify deep/strict signatures, exact bundled APK signer/hash, portable runtime/notice inventory, and source archive against that same app. Run copied installer artifact outside build output. |
| C12 notification authority and privacy | Build6 real in-app reply/dismiss passed; private text was excluded but stale public row remained. Later Core/Mac origin/poller fixes have fixture evidence. Android11 trust-scoped wire proof is pending this review. | On final installed cohort, exercise allowed public post/update/reply/dismiss, public→private replacement/removal, stale action refusal, actual RemoteInput exactly once, selected-trust/allowlist restrictions, revoke/re-pair origin inactivity and service-epoch replacement. Keep actual denied Mac-banner permission as denied; injected callbacks do not establish granted native banners. In-app and native-banner results are separate. |
| Fallback input regression | Build6 real SDL keyboard passed; normal-hover clicks failed. Supported no-hover diagnostic passed; root integrated reviewed policy in later source. | Final packaged fallback with the shipped policy: actual WindowServer focus/click/drag/key/resize in two independent app windows, inspect Android effects on the exact displays and await cleanup. The diagnostic flag-only run cannot substitute for shipped integration. |
| C13 cold independent profile behavior | Build6 main-quit wrappers used configured15/60/30; actual sustained decoded motion14.94/34.72/25.52fps; existing sessions retained prior ceilings. Original arrival-jitter test failures retained. | Preserve those scoped passes after source/artifact equivalence review; repeat a final-cohort cold wrapper smoke if affected. Keep configuration, sustained receiver rate and short-interval jitter distinct. Do not claim per-frame encoder PTS or battery savings. |
| Cold preview + first-video budgets | Last quiet candidate3 fails original100ms preview and10%/200ms paired regression targets. Candidate6 source path is improved but new cohort unmeasured. | After all builds/tests finish and Mac/Systems hand over the GUI, run bounded paired/disconnected product cohort plus standalone AppKit control. Record raw phases/load/distributions; remediate actual product regressions or explicitly decide a measured product exception. Original gate failure is never relabeled a pass. |
| C05 Spotlight search and activation | Signed wrappers, real phone/Mac selection, Android icons and launch admission passed. App importer returns34 valid attributes. Existing ~/Applications apps and owned public probe have no mdls/mdfind hit; system Calculator control succeeds. Synthetic CoreSpotlight item query works. Spotlight UI activation remained unobserved after one exact UI restart. | Retest an ordinary system control and user-app control, then actual current generated wrapper by exact bundle ID/name using NSMetadataQuery/mdfind. In a usable Spotlight UI, search the wrapper, activate its result, observe correct distinct app/window/input; deselect/offline it and verify hidden eligibility plus stale-result refusal, then reconnect. No global index erase, privacy/hotkey reset or repeat process-kill loop. If this host remains unable to expose/index user apps, use a separately provisioned authorized interactive Mac environment or retain BLOCKED. Synthetic index success, importer metadata and LaunchServices launch are useful partial evidence, not actual Spotlight search/activation. |
| C14 public delivery | Strict metadata validators and unavailable lookup/UI are tested. No report proves a downloadable public final installer. | Use the versioned public prerelease sequence below; validate actual phone/Mac delivery controls, unauthenticated HTTPS bytes/integrity and installed downloaded copy. |
| Final security/source/privacy acceptance | Independent source closure, notices, archive validation and adversarial tests exist for earlier exact cohorts. Later notification/poller changes require their own review. | Reviewer binds final code, APK, Mac host/broker/runtime and corresponding-source hashes; finish current trust/poller regressions and installed smoke. Re-run the evidence text/QR/content audit for new captures; preserve original failures and avoid publishing enrollment links or incidental file-picker/clipboard content. |
| Final docs/cleanup | Pixel-only hardware stage remains explicit. Prior systems harnesses clean exact displays/forwards/JARs/trusts; one deliberately retained QA37 broker is documented by Mac owner. | Publish current install/uninstall/upgrade/re-pair/diagnostic and Pixel guide; reconcile C01–C15 row→source→test→artifact→review with honest boundaries; await final exact owned resource cleanup and record any deliberately retained helper/forward owner. No physical Pixel or unrelated emulator work. |

## C14: close the public-download/install sequence without circular acceptance

The product pins **v0.2.0** and the exact GitHub assets below in both Android and
Core metadata policy. A separate `v0.2.0-rc.1` download is not an equivalent test:
it will not match these compiled clients.

- `https://github.com/SloopWorks/DroidBridge/releases/download/v0.2.0/release-manifest.json`
- `https://github.com/SloopWorks/DroidBridge/releases/download/v0.2.0/DroidBridge-0.2.0-arm64.dmg`

A GitHub **public prerelease at the pinned v0.2.0 tag** can make the exact candidate
reachable for validation without claiming final acceptance. The coordinator has
publication scope; this review does not publish anything.

1. Finish locally executable source/security/packaging and outside-build installed
   gates first. Record outstanding host/platform or measured product decisions
   explicitly; do not present an unresolved required gate as complete.
2. Bind the exact candidate commit, DMG, standalone APK, release manifest,
   checksums and complete corresponding-source archive. Validate DMG size/hash,
   arm64/macOS26 metadata and ad-hoc/not-notarized classification. Public source
   must accompany this actual binary cohort, not just point to unpinned links.
3. Publish those immutable bytes as the versioned validation **prerelease**.
   Record asset IDs/URLs/hashes and candidate commit. Public exposure is a release
   action; its existence is not evidence that C14 or the program passed.
4. Through actual installed phone Get Mac App controls, explicitly fetch metadata,
   inspect version/size/signing/checksum, and exercise Copy/Open on its fixed URL.
   Check the Mac Get Mac App refresh and explicit Download/Copy controls too.
   Record the real approved HTTPS redirect chain, successful bounded metadata,
   and actual installer bytes accessible without repository credentials. Do not
   substitute a signed-in GitHub CLI download or a local cached file.
5. Download the actual versioned DMG in the Mac browser path, hash downloaded bytes
   and compare exact length/hash with the displayed public manifest and prerelease
   asset. Independently fetch/hash the corresponding-source and other listed
   assets. A checksum binds bytes, not a Developer ID identity.
6. Mount that downloaded DMG read-only and copy its app to a fresh outside-build
   install path. Verify strict nested signatures and host/broker/bundled APK/runtime
   identity against the accepted local candidate. Observe the real quarantine/
   Gatekeeper path and any explicit OS approval required; do not strip quarantine
   and then claim browser-install approval behavior was tested. The phone cannot
   install or approve Mac software.
7. Launch the downloaded installed copy in an explicit private QA scope. Run a
   final connection/catalog/real-app/input/backend-selection smoke and the changed
   security/UI paths; verify bundled Android install/update identity and retained
   settings/re-pair behavior as applicable. Keep first-install/new-scope and upgrade
   evidence distinct. This exact downloaded-copy run closes the install half of
   the public-delivery gate.
8. Reviewer checks the receipts. Only after all required gates or explicit product
   decisions are accepted may the coordinator promote the **same tag and assets**
   from prerelease. Promotion does not rebuild or replace accepted bytes. Publish
   the acceptance/evidence commit separately when it follows the immutable source
   commit, and retain both identities. If a public-candidate test fails, retain the
   failed attempt; changing code/assets requires a new reviewed candidate/version
   policy and retest, not replacement of bytes already claimed as accepted.

## Spotlight blocker: exact current interpretation

The evidence does **not** establish that every Spotlight service/index is broken:
the system-app control and a synthetic named CoreSpotlight query succeeded.
It establishes missing metadata hits for the tested user Applications paths and
an unbindable/unobserved Spotlight search UI in this session. Repeating an
Application importer test validates wrapper metadata but does not commit a search
index entry. Likewise a synthetic CoreSpotlight result has neither the shipping
wrapper identity nor verified UI activation. The program's actual Spotlight row
therefore remains blocked rather than passed. Finder/Dock/direct launch and
stale-result admission protection remain useful, separately passed behavior.

## Traceability questions to resolve before the final C01–C15 ledger

These are unmapped evidence boundaries in the reports inspected, not claims that
the product is broken. Bind an existing exact executable result if available;
otherwise execute the bounded missing flow rather than closing it by assertion.

- **C02 GUI setup / endpoint change:** the current systems report proves real
  Android wireless-debugging TLS pairing and alias capture through an emulator
  redirection, explicitly not physical Wi-Fi. The Mac UI component report proves
  reachable controls and validation but explicitly did not pair. Identify actual
  installed Mac Pair/Connect UI and changed-endpoint/outage receipts, or run those
  on the owned emulator. Physical Wi-Fi remains part of final hardware scope.
- **C09 diagnostics/export:** map an actual installed opt-in diagnostic export and
  its bounded/redacted contents, including one real actionable failure; the broad
  component-surface capture is not that evidence.
- **C07 application switching:** independent bundle/PID/window/icon evidence is
  strong. Map actual Cmd+Tab/Dock activation of those distinct wrappers if required
  by the final experience claim; a separate identity alone is not an observed
  switcher interaction.
- **Upgrade/uninstall:** retain the nonempty settings/profile/export upgrade proof,
  and bind the documented exact helper/wrapper cleanup to a disposable installed
  scope. Never uninstall production state to create this evidence.
