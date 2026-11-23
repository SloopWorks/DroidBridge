# DroidBridge desktop measurement plan

## Decision

Start with two independent weekly series: release-asset downloads and consenting desktop usage. Use them to see whether distribution and repeat *activity in aggregate* are increasing. Unique people, installations, DAU/MAU, returning cohorts, acquisition conversion and individual retention require information this design deliberately omits. Downloads and usage have different populations and never share a join key. No per-install heartbeat or persistent, rotating or probabilistic identifier is needed.

## Platform inventory and ownership

DroidBridge starts at `60f445d`. The SWIP source checkout starts at `549429a`, with unrelated local Android schema work. The reviewed upstream SWIP main is `db075de`. The existing DroidBridge source binding is an Android development-only Kotlin contract. Its local ring includes a rotating daily identifier in anonymous mode. The SWIP JS/KMP event transport carries event context, and SWIP archives can retain individual events. KMP desktop means JVM. The inspected Swift/macOS consumer had no published Swift SDK or suitable anonymous aggregate lane. The bug-report gateway handles opt-in diagnostic artifacts, Shipyard measures executions, and Shipyard Deploy distributes Android builds. Each retains its existing purpose.

SWIP owns the new aggregate family in `services/anonymous-usage/contract.json`, its admission and weekly operator query, and ADR-0029. It introduces a versioned route for this use case without opening the general event gateway. DroidBridge’s `AnonymousUsage` Swift module owns the typed counter projection, consent, storage and transport. AppKit is responsible only for the lifecycle signals and choice UI. Use the local Swift module for this first consumer. If another Swift product adopts the lane, publish it from SWIP after establishing a versioned product binding, independent consumer tests and a migration path. Local builds do not imply package publication.

## SloopWorks-managed domain

The owner wants SloopWorks to operate instrumentation for its products. We recommend
`usage.sloopworks.com` as a shared hostname, with
`/v1/droidbridge/usage` reserved for this desktop contract. DNS, certificates,
routing and a privacy-reviewed ingress are still unverified. Default packages
have no active endpoint configuration. The production transport allowlists
this exact HTTPS origin and route so consent always names the same recipient. Register each future product through a separate decision,
schema and route. Route to a product-specific store with scoped read access.
The hostname supplies no reason to share identifiers or join activity across
products. The present service accepts DroidBridge only.

SWIP invariant 21 covers customer and product **mobile binaries**; ADR-0027
permits a narrowly declared internal debug exception. This proposal concerns
the SloopWorks-managed macOS desktop app. Extending the hostname to a production
mobile binary requires a compliant product endpoint or a superseding SWIP
decision. The Android companion keeps its existing local-only diagnostics.

## What the numbers mean

| Metric | Measure | Interpretation |
| --- | --- | --- |
| Downloads | Provider asset download counter snapshots and differences from the prior observation for the same release asset | Requests counted by GitHub. A re-download can count again. An absent asset or first snapshot has no attributable interval delta. This captures neither installs nor all distribution channels. |
| Foreground sessions | First eligible foreground entry per process, plus entries following at least 30 minutes ineligible in that process | The control app and independently launched native wrappers contribute. Process restarts, switching among wrappers, sleep and changes in eligibility affect counts. |
| Active minutes | Whole minutes of sampled eligible foreground time, with gaps bounded to 60 seconds per sample | Control-app time requires a visible key window and includes using the launcher. The sampler runs only during eligible foreground use with consent. A wrapper requires an active app, key visible native window and presented video in a running session. Sleep and display sleep pause measurement. This is approximate foreground time, not Android screen-on time or proof that somebody watched the content. |
| Native sessions | First presented decoded frame in each native attachment | A launch failure or still-empty window contributes none. Reattachment during recovery can contribute again. External scrcpy Player windows are outside native coverage. |

The foreground and native metrics describe different events. A control-app session can start without a native session; one foreground session can open several Android streams. The wire format sums eligible foreground time from both host kinds. It cannot split totals by control versus wrapper. Use release asset reporting through `scripts/telemetry-downloads.py`; its definitions and operating instructions are in [Download metrics](telemetry/DOWNLOAD_METRICS.md). Keep provider-level aggregate reports entirely separate from client counts.

## Data path and loss behavior

1. A regular package ships with delivery disabled. The shipping build configuration can specify an exact reviewed HTTPS endpoint and the `production-v1` lane. The installed control app then offers Settings → Integration → Share usage totals with SloopWorks, off by default. Managed and on-demand wrappers inherit their build's configuration. Older wrapper binaries need their normal update or regeneration. A settings toggle in the control app governs future writes by all participating processes. The ledger and a separate owner-only permission file must agree. Withdrawal revokes the permission before attempting to purge counters. Settings distinguishes an unconfirmed choice from confirmed withdrawal with a locally pending purge.
2. Control and wrappers feed only foreground booleans and native starts to the Swift facade. They share a private, locked aggregate ledger. Monotonic foreground timing stays within the running process. Per-report clipping is 8 foreground sessions, 120 minutes and 8 native starts. The file tracks only enough local state to maintain consent, pending counters and send budget. Isolation for verification uses a private QA root. No queue of individual events accumulates.
3. A foreground transition or native start can send a nonempty previous measurement period, at most one attempt per UTC day across contributing processes. The minute timer only samples and persists counters, including at UTC day rollover. A long uninterrupted foreground interval can therefore span receipt days before delivery. An aggregate older than seven days is discarded on the next accounting operation. There is no quit flush, tracking token or replay ledger. Clear the contribution before transmission. Failures, a crash between drain and send, uncertain delivery, clipping and flooring can cause undercount. Revocation removes pending counters. Counters already merged at the origin cannot be attributed back to a person.
4. The SWIP receiver validates exact fields, integer bounds, content type and byte limits against its product-specific versioned contract. The database sums three counters into the UTC **receipt week**. Delayed submissions can fall into another week. The collector retains the current and twelve preceding weeks. Operators must run idle pruning and align backups with that retention. Keep reads offline and restricted. A missing row means no available measurement.
5. The private aggregate query supports release and product review. Comparative analysis belongs at weekly granularity. Repeated queries over a nearly empty population can reveal individual contributions through subtraction. Avoid publishing weekly cells until a disclosure policy for small populations, stable windows and differencing has been independently validated. A report count cannot prove the number of distinct contributors. No metric supports a user-conversion funnel.

## Operating the aggregate service

The intended managed lane uses a Cloudflare Worker and a dedicated DroidBridge D1
database. The Python loopback service is a local reference for protocol and
app integration checks. Both use the SWIP contract and keep the same three
weekly sums. There is no public read route. A separate administrative read
permission is needed to query the managed store. Use local workerd/D1 migration
and admission tests before provisioning its deployment binding.

D1 Time Travel on the production storage subsystem is always active. A
privileged operator can restore a database to a minute within its recovery
window (7 days on Free, 30 on Paid). Differences between restored weekly
totals can reveal the values and approximate arrival time of isolated reports.
Restrict restore privileges, review exports, and include this additional
history in the retention and unlinkability assessment. Worker observability
settings alone cannot remove that history. [Cloudflare D1 recovery documentation](https://developers.cloudflare.com/d1/reference/time-travel/)

## Rollout dependencies and acceptance

1. Review and land the SWIP ADR, exact aggregate contract and strict receiver before enabling the application lane. Cross-check the client wire with that receiver. Contract changes that alter fields, privacy or metric meaning require explicit review and a new version. Keep v1 compatible for installed applications.
2. Exercise the local receiver with synthetic reports and a packaged app copied outside its build directory. Verify a real decoded frame in a native wrapper on the dedicated emulator, main-app closure, multi-process consent and caps, withdrawal, no report before consent, invalid input refusal, ambiguous transmission, restart and aggregate readback. The loopback-only QA override requires a private QA scope, emulator-5580 and an explicit port. No customer endpoint is required for those checks.
3. For production, establish an owner-controlled hostname, TLS and a separately reviewed ingress. Validate address, header, body and timing handling at the network provider, relay, WAF, proxies, collectors, traces, error systems and backups with synthetic traffic and privileged readback. A direct HTTPS receiver can associate a network address with a report. Disabling access logs reduces retention but does not prevent observation at ingress. For an unlinkability requirement covering the receiving infrastructure, implement and verify a split-knowledge relay with encrypted submissions, or keep remote delivery disabled. Test global capacity limits, overload behavior, no per-user keys, backup expiry, offline query permissions and rollback. No public release of statistics is part of v1.
4. After approval, the build operator supplies `DROIDBRIDGE_USAGE_LANE=production-v1` and `DROIDBRIDGE_USAGE_ENDPOINT=https://usage.sloopworks.com/v1/droidbridge/usage` when packaging. These values are build inputs. Default builds omit the endpoint setting; recipients cannot retarget submissions via ordinary preferences. Confirm the package’s signature and configuration, run opt-in and opt-out synthetic checks in an isolated QA lane and validate the approved ingress using separately authorized synthetic traffic, then request a limited release. Neither publication, deployment, production traffic nor live ingress privacy verification is established by local tests.
5. Roll back by disabling ingestion upstream and shipping the normal package with the lane off. Verify deployed wrappers are updated through their normal lifecycle, and that the stopped receiver and its proxies retain no new requests. Revisit the measurement after enough **aggregate** weeks accrue. Start with distribution and consenting usage trends; add a counter only when a stated product decision cannot be answered by those series.
