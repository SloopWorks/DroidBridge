# Companion startup performance gate review

Status: measurement preparation, no release exception accepted. The roadmap's
100 ms p95 local-response target and paired/unpaired first-video regression limits
remain unchanged. Installed candidate 6 must be measured after its functional
checks; candidate 3 evidence cannot establish candidate 6 behavior.

## Existing evidence and limits

The quiet candidate-3 ABBA run has five process launches per connection cohort.
Public-window preview p95 is 504 ms connected / 388 ms disconnected, so its
100 ms gate fails. Presented-video p95 is 2759 / 1967 ms, also failing the proposed
10% and 200 ms companion regression bound. These are retained failures.
`installed-api37-tls-build3-preview-quiet/phase-attribution.json` separates process
spawn, application entry, AppKit startup, launcher construction and window setup.
Its pooled spawn-to-entry p95 is 307 ms and entry-to-AppKit p95 is 166 ms. These
figures suggest investigating host/runtime startup variance; they do not establish
an unavoidable OS floor or excuse product work.

Candidate 6 presents its preview in applicationWillFinishLaunching before menus,
companion startup and Android discovery. Wrapper launcher controls are lazy and
there is no hidden launcher NSWindow on this path. The preview still constructs
its native NSView, loading indicator, window identity, size and standard controls.
Those are observations from source, not evidence of a latency pass. No speculative
product changes were made during this review.

## Standalone AppKit control

`scripts/verify-appkit-startup-baseline.py` compiles two small, ad-hoc-signed,
standalone macOS applications: Objective-C/AppKit and Swift/AppKit. They contain
no DroidBridge modules, ADB, companion broker, Android session or product settings.
The explicit QA root must be canonical, owned by the current user and mode 700;
samples and phase output stay below that root. The apps use a separate private
bundle identity, disable window restoration and never enumerate devices. They
show one standard public-AppKit window and loading label.

Compilation is the default and does not create NSApplication or show a window:

```sh
python3 scripts/verify-appkit-startup-baseline.py \
  --qa-root /Users/patrick/workspace/DroidBridge/.build/companion-appkit-baseline \
  --output-name compile-final
```

Only after the macOS test owner hands over the quiet GUI window, run a fresh
bounded cohort with `--run --samples 20 --host-context '<actual host conditions>'`.
Do not operate the Android emulators, shared ADB server or another test's windows.
The benchmark opens and terminates only its exact owned child processes. Record
compiler/signature checks, executable/source hashes, dependencies, raw sample
phase clocks, host load, sample count and p50/p95. Run the installed product cohort
in the same quiet period, retaining its connected/disconnected split; a before/
after baseline helps expose a changing host condition.

Both standalone variants use the **same passive public NSWindow observer** as
`scripts/verify-companion-preview.py`, including its 10 ms timer. The parent clock
starts before Popen, so the result includes spawn/dyld and Swift runtime loading.
Separate phases identify application entry, NSApplication availability, AppKit
launch callbacks, window construction and window ordering. No phase logging is
performed before window ordering. The observer measures NSWindow visibility,
not WindowServer paint, perceived pixels, input readiness or live Android content.
Every sample is a fresh process; filesystem and OS caches are uncontrolled and
must not be described as flushed. A repeated launch is not an uncached-install
claim. The small baselines are diagnostic lower bounds, not substitutes for the
actual signed installed application.

## Decision rules

1. Preserve the original gate result even if a separate exception is proposed.
   Never label the 100 ms target passed by subtracting a baseline or changing its
   start boundary from process spawn to application entry.
2. If the standalone controls satisfy 100 ms and the product does not, investigate
   measured product phases first. A loader/OS explanation is not established.
3. If both controls repeatedly exceed 100 ms on this host, report their exact
   distributions alongside the product's. This establishes an observed lower
   bound for these tested implementations and conditions, not a universal claim
   that AppKit cannot meet 100 ms. Inspect whether product-specific work still
   dominates before proposing an exception.
4. Do not subtract independent p95 values as a causal cost estimate. Retain raw
   rows and phase durations, compare distributions and connection cohorts, and
   state the limited confidence of five-sample p95 (the maximum observation).
5. An exception, if needed, is an explicit product decision with an identifier,
   exact installed artifact/OS/host, raw before/after evidence, original failed
   target, justified replacement boundary/budget, remaining improvement owner,
   and regression trigger. Its number is not chosen before the new evidence.
   Until accepted, release status remains a failed/open gate. Nothing in this
   review changes the roadmap or grants that exception.
6. Local preview responsiveness and first presented video are independent gates.
   Even a justified local-window exception cannot excuse companion-induced video
   delay. Profile startup correctness and independent-wrapper operation with the
   main app quit also remain separate acceptance requirements.

## Frame-rate measurement caution

The candidate-6 15 fps artifact reports a verified configured ceiling and a
32.53-second mean of 14.94 decoded frames/s, while its roughly one-second decoded
arrival intervals briefly exceed 15. Some slow intervals are followed by a burst.
This is an actual measurement failure under that script's current interval rule;
it must stay visible. Arrival batching in transport, decoding or the main queue
can make that rule differ from the encoder's frame-production limit. Before
changing product limits or relaxing a test, inspect capture/presentation timestamps
or an explicitly defined cumulative interval. A ceiling configuration pass alone
is insufficient, and receiver burst rate alone does not identify encoder failure.
Any measurement correction must document the changed boundary and preserve raw
interval data. No battery-saving claim follows from frame-rate configuration.

Independent source review agrees with correcting this measurement boundary.
`FrameMailbox.publish` increments a cumulative count for every decoded frame,
including an overwritten image. `FrameMailbox.drain` later delivers that whole
count on MainActor. `BridgeSession` increments its public metrics only in that
drain, and `recordQAMetrics` timestamps the count when MainActor samples it.
Therefore one-second count deltas are batch-arrival rates and cannot establish
per-frame encoder production cadence. The scrcpy video protocol's packet PTS is
passed into VideoToolbox but is not present in these QA counter samples.

The supported acceptance description is: exact configured server max_fps, actual
visible motion, and measured sustained decoded throughput over at least 20 seconds,
with short-interval jitter reported separately. Validate monotonic sample clocks
and frame counts, fixed geometry without resize intervals, adequate duration and
nonzero changing content. A zero-frame/static or too-short sample cannot stand in
for this motion test. A sustained mean near the selected profile is supporting
runtime evidence; it is not an encoder PTS guarantee. Retain the original failed
short-interval artifact and name the corrected measurement distinctly. This is a
measurement-boundary correction justified by the executed code, not a higher
configured ceiling or a retroactive claim that the original interval gate passed.

## Final candidate-8 measurement plan

Precommit **20 process launches per product connection cohort** and **20 per
standalone AppKit variant** before observing the new results. The product harness
uses `--samples-per-cohort 20`; its default remains five for compatibility and its
original five-per-cohort ABBA ordering is unchanged. Do not pool candidate3 with
candidate8, drop outliers, or stop/restart sampling because a partial result fails.
Retain raw rows and extremes even when p95 is below the maximum.

The product gate uses nearest-rank p95 (`ceil(0.95*n)`): at n20 this is the19th
ordered observation, rather than the maximum as at n5. Both connected and
disconnected preview p95 must stay at or below100ms. The first-video comparison
requires **both** connected-minus-disconnected p95≤200ms and connected/divided-by-
disconnected p95≤1.1. These are cohort-distribution contrasts under the interleaved
control, not a claim that subtracting independent percentiles isolates a causal
per-launch companion cost. The initial thresholds and measurement boundaries are
unchanged. Independent AST-level checks validate the old n5 order, n20 allocation,
nearest-rank example and exact boundary/AND cases without launching any application.
Evidence: `verification/companion/core/startup-method-review.json`.

Select Balanced before the run and confirm both cohorts use the30fps descriptor;
the default configuration is also30fps if an optional status response has not yet
arrived. Record actual connected/disconnected broker state after each transition,
not just the requested cohort label. Between samples observe a bounded drain of
the exact previous owned session/supervisor resources; a fixed one-second sleep
alone does not establish cleanup. Preserve all unrelated state and resources.
The root/macOS owners will complete those harness preconditions before the quiet
run. No standalone or product GUI measurements have been performed by this review.

Final harness safeguard review is accepted for execution. It validates actual
broker connection/profile state before launch and after first video. It identifies
only new logs with supervisor_started.parent equal to the exact spawned wrapper
PID, waits for matching terminal logs without cleanup failure and the captured
process start/command identities to disappear, and does not assume receipt files
are deleted. Inspection failures still enter a nested finally that terminates and
reaps the exact Popen child and closes its log. A SIGTERM timeout uses bounded
SIGKILL/reap, finishes normal supervisor-drain inspection and records a failed
sample rather than silently accepting forced termination. The observer PID must
match the child. Six synthetic executions of the **reviewed cleanup AST** cover
normal flow, process/identity inspection errors, timeout, cleanup failure and PID
reuse; a separate wrong-observer-PID check rejects stale provenance. These tests
start no processes or GUI windows. The source-hashed receipt above records them;
they approve the method, not the still-unexecuted quiet performance gate.
