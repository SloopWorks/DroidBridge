# PTY/readiness independent review

The prior unmodified fallback client buffered INFO/Texture output when stdout was a regular session log, so a strict Texture readiness check could incorrectly time out. The lead reproduced the problem (`../fallback-buffered-failure.log`) and introduced an opt-in supervisor output PTY; no scrcpy client patch or test-only unbuffering is required.

Review of the production C path found no blocking issue: only fallback opts in, the raw slave avoids CR conversion, the master is CLOEXEC and nonblocking, the child duplicates the slave to stdout/stderr, and the parent closes its slave reference. Reads are bounded to 16×4096 bytes per watchdog cycle. Output writes go to the GUI's controlled regular session log. This is not a controlling TTY or interactive shell; stdin still carries the inherited per-port lock description, preserving that lock through GUI-crash cleanup. Parent-death and signal checks remain after each bounded read batch.

`../fallback-real.log` records the unmodified client reaching Texture readiness, its exact owned PID/window geometry, and cleanup. The installed four-cycle test similarly records two real fallback handoffs without Player instrumentation.

The new buffered-child unit test initially stalled in its test-only `defer { helper.waitUntilExit() }`. Independent read-only sampling of xctest 7716 locates that Foundation wait at `SupervisorDiagnosticsTests.swift:31`; see `full-suite-wait-sample.txt`. This does not demonstrate a production PTY/watchdog stall. The lead repaired the fixture with finite async teardown; the subsequent full suite records 124 tests, four explicit device-gated skips and zero failures. The failed log/sample remain evidence; no process was signaled by this reviewer.
