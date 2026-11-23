#!/usr/bin/env python3
"""Verify actual Swift transport -> local workerd -> durable D1 -> operator SQL."""
from contextlib import closing
import http.client
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time

repo = Path(__file__).resolve().parent.parent
service = repo.parent / "sloopworksinstrumentationplatform/services/anonymous-usage/worker"
wrangler = service.parents[2] / "packages/workerd-smoke/node_modules/.bin/wrangler"
out = repo / "verification/telemetry-2026-11-21"
out.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, WRANGLER_SEND_METRICS="false", CI="1")
commands = []


def run(args, cwd=repo):
    p = subprocess.run([str(a) for a in args], cwd=cwd, env=env, capture_output=True, text=True, timeout=120)
    commands.append({"command": [str(a) for a in args], "cwd": str(cwd), "returncode": p.returncode, "output": p.stdout + p.stderr})
    (out / "swift-worker-commands.json").write_text(json.dumps(commands, indent=2) + "\n")
    assert p.returncode == 0, p.stdout + p.stderr
    return p.stdout


with tempfile.TemporaryDirectory(prefix="droidbridge-swift-worker-") as scratch:
    root = Path(scratch)
    local = ["--local", "--persist-to", str(root / "d1"), "--config", str(service / "wrangler.jsonc")]
    run([wrangler, "d1", "migrations", "apply", "USAGE", *local], service)
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0)); port = sock.getsockname()[1]
    with (out / "local-worker.log").open("w") as log:
        child = subprocess.Popen([str(wrangler), "dev", "--ip", "127.0.0.1", "--port", str(port), *local], cwd=service, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            for _ in range(120):
                try:
                    with closing(http.client.HTTPConnection("127.0.0.1", port, timeout=2)) as connection:
                        connection.request("GET", "/v1/droidbridge/usage")
                        if connection.getresponse().status == 405: break
                except OSError:
                    pass
                assert child.poll() is None, "Local Worker exited"
                time.sleep(.1)
            else:
                raise RuntimeError("Local Worker startup timeout")
            run(["swift", "build"])
            binary = Path(run(["swift", "build", "--show-bin-path"]).strip())
            executable = root / "swift-probe"
            run(["swiftc", "-I", binary / "Modules", repo / "scripts/verify-telemetry-worker.swift", *sorted((binary / "AnonymousUsage.build").glob("*.o")), "-o", executable])
            run([executable, root / "meter", str(port)])
            result = json.loads(run([wrangler, "d1", "execute", "USAGE", "--command", "SELECT * FROM weekly ORDER BY week", "--json", *local], service))[0]["results"]
            assert len(result) == 1 and result[0]["foreground_sessions"] == 1 and result[0]["active_minutes"] == 0 and result[0]["native_sessions"] == 1, result
            assert set(result[0]) == {"week", "foreground_sessions", "active_minutes", "native_sessions"}
            (out / "swift-worker-results.json").write_text(json.dumps({"passed": True, "path": "real Swift Network transport -> local workerd -> local D1 -> operator CLI", "rows": result, "no_remote_deployment": True, "wrangler_metrics_disabled": True}, indent=2) + "\n")
            print("PASS: actual Swift transport to local Cloudflare Worker and D1, one contribution only")
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM); child.wait(timeout=15)
