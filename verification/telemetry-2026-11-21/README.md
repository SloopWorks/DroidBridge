# SloopWorks desktop usage implementation verification

Date: 2026-11-21. Implementation and recommendation:
[desktop plan](../../docs/DESKTOP_USAGE.md). Acquisition reporting:
[download metrics](../../docs/telemetry/DOWNLOAD_METRICS.md).

This is local implementation acceptance, **not production deployment or a claim
of end-to-end network anonymity**. All submitted contributions were synthetic.
The user explicitly deferred live UI checks after CUA found the Mac locked.

## What was implemented

- A separate Swift `AnonymousUsage` module, an AppKit adapter, shared private
  aggregate storage, explicit consent and durable revocation. Control and native
  wrapper processes share consent/caps without exporting process or session IDs.
- Three closed wire counters: `foreground_sessions`, `active_minutes`, and
  `native_sessions`. No account/install/session/device IDs, app names, free text,
  screen content, precise timestamps, cookies or user-agent fields enter reports.
- At most one destructive send attempt per UTC day. Sampling timers cannot cause
  delivery. Lifecycle events can submit a prior period. No retry/dedupe identity
  is introduced; uncertain delivery can undercount.
- SWIP-owned contract, Python reference receiver, Cloudflare Worker/D1 adapter,
  migration, scheduled pruning and operator-only aggregate readback. The product
  table contains only UTC receipt week and the three totals.
- Read-only GitHub aggregate download reporting, with format-separated counts,
  bounded pagination and conservative handling of replaced/missing counters.

## Executed evidence

| Requirement | Evidence |
| --- | --- |
| Existing suite remains compatible | `swift-test.log`: 396 tests, 4 skipped, zero failures before final privacy fixes; affected standalone and full-UI harnesses also linked |
| Final consent, lock/error, expiry, clipping, timer and exact-origin behavior | `final-usage-tests.log`: all 11 focused Swift tests passed on the final implementation |
| Final packaged shipping host, actual decoded emulator frames and independent wrappers | `appkit-runtime.log`, `appkit-runtime-results.json`, `runtime-session-logs/` |
| No collection state before consent | A real native wrapper reached running/presented content; no `AnonymousUsage` directory was created |
| Shipping Settings action controls collection | The AppKit fixture selects Integration and performs the shipping checkbox action; this verifies wiring/persistence, not physical focus or appearance |
| Shared consent after control-app exit | A wrapper survives quitting the exact review control process; a newly presented native frame still increments the aggregate with that control process absent |
| Withdrawal | A newly launched decoded wrapper after withdrawal leaves zero unauthorized counters; final permission is revoked |
| Anonymous wire projection | `wire-captures.json`: exactly three integer fields and `Connection`, `Content-Length`, `Content-Type`, `Host` headers |
| Useful aggregate transport, no repeated attempt | One contribution `{foreground_sessions:1, active_minutes:2, native_sessions:1}` reached the reference receiver; `receiver-readback.json` proves the committed weekly row and no request-level table |
| Foreground timing provenance | The two minutes and day rollover were explicitly injected through the same Swift meter. They are not evidence of real desktop attention, unlocked focus, sleep or idle transitions |
| Real Swift → Cloudflare execution | `swift-worker-results.json`, `swift-worker-commands.json`: actual Swift Network transport → local workerd → D1 → operator SQL; one contribution despite repeated send |
| Strict receiver admission and retention | `receiver-tests.log`: four tests; `worker-tests.log`: actual Wrangler/Miniflare/workerd tests with invalid bodies, concurrent writes, restart and scheduled pruning |
| Product isolation and no HTTP reads | `matrix-test.log`: another product route returns 404; HTTP read returns 405; seeded totals remain unchanged. SWIP isolation matrix updated |
| Downloads | `download-tests.log`: five tests; `download-report-live.json`: authenticated read returned no published asset counters, which means unavailable inventory, not zero users/downloads |
| Local package | `package-final.log`, `package-command.json`, `copied-artifact.json`: ad-hoc package passed strict signatures, was copied outside `.build`, and was run from that exact location |
| Cleanup | `cleanup.json`, `cleanup-commands.json`, `emulator-stop.json`: exact test processes/brokers drained, no native forwards or virtual displays, no real user usage directory, only the dedicated emulator stopped |

The review artifact is:

`/Users/patrick/Library/Application Support/DroidBridge/ReviewBuilds/anonymous-usage-2026-11-21/DroidBridge.app`

The independent GPT-6.2 Sol privacy review was coordinated by Astra 6.2. Its two
mandatory findings were fixed: the destination is pinned to the owner-approved
SloopWorks origin, and storage failures can no longer falsely report successful
withdrawal. Permission is revoked independently of the aggregate lock; unavailable
or purge-pending status is explicit. Additional verification hardened file modes
to 0600 and ensured that minute accounting never initiates an upload.

## Production recommendation and remaining release gates

Use `https://usage.sloopworks.com/v1/droidbridge/usage` for the SloopWorks-managed
product. Future products may share the hostname while retaining distinct routes,
contracts, databases and operator permissions. Default builds omit active endpoint
settings. Nothing was deployed, uploaded, pushed or enabled for customers.

The plan deliberately cannot report unique people, DAU/MAU, individual retention,
or a joined download-to-install funnel. Native and foreground counters are clipped
participating activity, with consent, flooring, process and delivery-loss biases.
External scrcpy Player windows are outside native foreground coverage.

Before activation, verify domain/TLS ownership, ingress capacity and disable
controls, account-level IP/header/body/timing retention, access and backup expiry.
A direct TLS terminator can associate a network address with a contribution.
Worker observability being disabled does not prove provider-level unlinkability.
D1 Time Travel also retains fine-grained recovery history, so sparse contribution
differencing remains a production privacy decision. These constraints are explicit
in the SWIP runbooks and the plan; local tests do not close those deployment gates.

Live UI appearance and actual unlocked-desktop foreground/sleep behavior remain
deferred at the user's request. Physical Pixel 10 Pro verification and production
signing/notarization remain owner-side release work.

## Scope and unsuccessful intermediate attempts

Only DroidBridge_API35 on emulator-5580 was controlled, using the existing unique
deterministic `dev.droidbridge.testapp20261121` fixture. No command targeted
emulator-5554 or killed the shared ADB server. Unrelated naming, Pixel-debugging
and pre-existing SWIP Android schema changes were preserved.

Initial packaged receipts predate the final privacy changes and are named
`initial-*`. A Swift-to-Worker attempt overlapped an in-progress API change and
failed compilation; the retained `swift-worker-intermediate-*` logs are not
acceptance evidence. The final frozen-source rerun passed. Source fingerprints
and integrity checks are recorded separately for both repositories.
