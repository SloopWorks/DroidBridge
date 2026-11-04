# Android companion integration contract

The companion remains an ordinary Android app reached through exact ADB loopback
forwarding and pinned TLS. SloopWorks tooling adds local development diagnostics
and development build distribution; it never becomes a second phone control
transport, discovers untrusted Macs, or carries screen/file/clipboard content.

## Dependency order and ownership

1. SWIP owns `registry/products/droidbridge.yaml`,
   `schemas/droidbridge/companion_action_finished.v1.yaml`, and generated
   `schema-droidbridge` Kotlin/TypeScript. Generate with `pnpm swip schema gen`.
2. DroidBridge consumes an exact copy of that generated Kotlin contract in its
   debug source set. `prepare-sloopworks.py --check-generated` checks agreement.
   This is a consumer snapshot of generated code, not a second schema authority.
3. `CompanionDiagnostics` wires the generated product factory to SWIP core
   0.1.12, SWIP debug 0.1.1, and DebugDrawer/core+SWIP adapter 0.1.1. The debug
   Activity hosts the real Compose drawer; the production UI uses Material
   Components Views 1.13.0 and AndroidX Activity 1.11.0.
4. Shipyard Deploy's Gradle plugin 0.1.0 embeds metadata into `development` only.
   The app ID is `dev.droidbridge.companion.dev`. Release and ordinary debug IDs
   are unchanged. `.shipyard-deploy.yaml` lives beside the Android Gradle settings.
5. The Deploy CLI verifies signed APK/package/provenance and the trusted server
   before upload. Device enrollment/policy owns installation; publishing is not
   proof that a device installed it.

The SDK AARs require compileSdk37 and core-library desugaring 2.1.5; runtime
minSdk33 and targetSdk35 remain explicit app policy. AGP8.13.2 warns that its
verified compile SDK ceiling is36.1; successful build/device evidence must remain
separate from vendor toolchain support. No warning suppression is used.

## Privacy and lifecycle

Diagnostics boot OFF each process. Explicit consent in the debug-only Diagnostics
screen enables anonymous, memory-only local collection. Events have only an
operation enum, outcome enum, and integer duration 0–300000ms. No Mac/package/trust
or request identity, text, paths, URLs, filenames, screenshots, or payload enters
SWIP. The generated manifest is `delivery: local_only`, with no service endpoint,
production source, vendor, uploader, or persistent analytics queue.

SWIP anonymous mode stamps a rotating per-UTC-day `anon_` identity in memory,
with no persistent installation ID or session ID; the inspector hides identifiers.
The ring has 200 records. A host sink gates records while collection is disabled;
turning collection off first gates observation, sets mode OFF, denies consent,
and synchronously clears the ring. DebugDrawer masks records and uses a secure
window for detail reveal. Release contains only the no-op host twin and excludes
SWIP, generated source keys, drawer, inspector, and diagnostic Activity. The
Compose compiler's release compile-only runtime is not an APK runtime dependency.

The `record(operation, outcome, durationMs)` seam belongs at actual command receipt
boundaries. `requested`, `accepted`, `applied`, `failed`, `unknown` remain distinct.
Transport receipt IDs stay in the product ledger, never the analytics payload.
Unknown elapsed data is omitted by not recording; it must not become zero.

## Source build and distribution

Private package reads returned HTTP401 with this machine's configured read
credential on 2026-10-30. The verified workaround builds actual sibling sources
into an ignored, isolated Maven repository; it never substitutes an implementation
stub or claims package publication:

```
./AndroidCompanion/prepare-sloopworks.py --workspace /Users/patrick/workspace
./AndroidCompanion/build.sh \
  -PsloopworksLocalMaven="$PWD/AndroidCompanion/build/sloopworks-maven" \
  :app:assembleDebug :app:assembleDevelopment :app:assembleRelease
```

Without that explicit property, pins resolve against the configured GitHub
Packages repositories. Local source artifacts and receipt are below
`AndroidCompanion/build/`; their hashes and source revisions distinguish them from
published versions. The plugin currently resolves from a content-filtered local
Maven coordinate; bootstrap it from `shipyard-deploy/gradle-plugin` with that
repository's documented `publishToMavenLocal` when absent.

`shipyard-deploy doctor --json` selects an already authenticated development
control plane, `https://shipyard-deploy-dev.patjackson52.workers.dev`. Repository
configuration does not grant trust or hold credentials. Configured channels use NOTIFY so publication does not demand automatic
install. The CLI onboarding implementation currently creates its initial main
channel with AUTO_INSTALL_WHEN_ALLOWED; if administrative registration later
succeeds, inspect and lower that ceiling to NOTIFY before publishing. `onboard --apk ... --yes` registers
only the development package/signature; publication keeps build instance UUID,
provenance SHA, Git commit and APK SHA separate. No public release, production
service deployment, device enrollment, or physical-phone operation follows from
this development configuration.

## Evidence map

| Requirement | Authoritative evidence |
|---|---|
| Closed event fields and no private text | SWIP schema check and schema-droidbridge tests |
| Exact generated consumer contract | `prepare-sloopworks.py --check-generated` |
| Actual library integration | Source staging logs, resolved graph and Android compilation |
| No collectors in release | releaseRuntimeClasspath and APK DEX/manifest inspection |
| Explicit consent and clear | Debug instrumentation test + runtime diagnostics Activity |
| Development identity and signature | Deploy `inspect` and generated provenance asset |
| Development upload | Canonical Deploy publish receipt |
| Device install | Separate enrollment/install reconciliation receipt, never inferred |
| Product e2e | Dedicated emulator5580 and Mac broker feature evidence |

Physical Pixel installation and acceptance are tracked by the delivery report;
this integration's diagnostics evidence uses the dedicated emulator. Product
Atlas acceptance is a different authority and is not implied by this integration.

## Current operational result (2026-10-30)

Actual source staging, generated-contract check, strict SWIP schema tests, Android
development APK assembly, and Deploy APK inspection passed. The authenticated
development service refused onboarding because project `droidbridge` does not
exist and the available publisher token cannot create projects (admin-only).
No package/channel/build was published and no device enrollment was changed.
This is an authorization gap, separate from private Maven read HTTP401; the latter
has a verified source-build path while administrative registration still requires
an authorized operator. Receipts are in
`verification/companion-improvements/integrations/`.

The latest development artifact was rebuilt with all 41 tasks executed from the
current final Android source/config inputs, checked stable across assembly, and
copied outside the build directory to
`dist/companion-improvements/DroidBridge-Companion-Development.apk`. Its SHA-256
is `d73d3754dcd91b0c15715c0c2599bc9e9600e3bdcaf904929ad93163aa276f6e`;
Deploy inspection and independent APK v2 signature verification pass. The exact
build UUID, canonical provenance digest, source hashes and existing development
signer certificate are recorded in `development-final-*` evidence, with stable
source inputs in `development-current-source-inputs.json`. The development test
build regenerated metadata, superseding the earlier `a1721e55...` candidate.
The final copied APK and separate `.dev.test` APK were installed on emulator5580;
both diagnostics tests pass in 2.056 seconds against these exact installed hashes.
Release product and test APKs remain `b6277fb9...` and `b1aee0e0...`, with no release
data operations. Neither companion service ran; the development process was
stopped after screenshots were collected. Nothing was published, no credentials
changed and the missing project was not provisioned. The last read-only doctor
check passes and project status is HTTP404.

Dedicated emulator5580 runtime verification passed both diagnostics tests: explicit
consent admits the generated bounded event, anonymous session ID stays absent,
disabling collection synchronously clears the ring, and new disabled calls stay
absent. The second test waits for rendered Compose accessibility nodes and uses
actual injected touches to open the library bubble and SWIP inspector. Screenshots
were visually inspected. Runtime verification found and fixed the debug host's
edge-to-edge system-navigation overlap with `safeDrawingPadding`; the final bubble
is fully touchable above navigation. The separate `.dev` test provider now binds
its authority to the resolved test application ID, preserving the existing
release test installation while permitting side-by-side diagnostics.

Share-onward acceptance additionally uses a separate ordinary fixture UID:
actual product touch opens Android Sharesheet, the selected receiver confirms
its temporary URI grant and exact PNG byte count/SHA, and a direct ungranted URI
read refuses with SecurityException. The fixture is test-only and excluded from
both production APK and Mac package. Final proof and artifact bindings are in
`verification/companion-improvements/integrations/share-onward*`.
