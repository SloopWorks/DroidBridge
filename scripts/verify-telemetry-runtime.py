#!/usr/bin/env python3
"""Hold an isolated packaged-app/collector run for actual AppKit verification.

The UI reviewer writes <scope>/finish after closing only the review processes.
Only synthetic usage may cross the loopback proxy; captured bodies are validated
as three bounded integers before any evidence is retained.
"""
import argparse
from contextlib import closing
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import sqlite3
import subprocess
import tempfile
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument("--app", type=Path, required=True)
parser.add_argument("--collector", type=Path, required=True)
parser.add_argument("--evidence", type=Path, required=True)
args = parser.parse_args()
evidence = args.evidence.resolve(); evidence.mkdir(parents=True, exist_ok=True)
root = Path(tempfile.mkdtemp(prefix="droidbridge-telemetry-", dir="/private/tmp")); root.chmod(0o700)
app = args.app.resolve()
captures = []
(evidence / "wire-captures.json").unlink(missing_ok=True)
limits = {"foreground_sessions": 8, "active_minutes": 120, "native_sessions": 8}
with socket.socket() as probe:
    probe.bind(("127.0.0.1", 0)); origin_port = probe.getsockname()[1]
database = root / "usage.sqlite"
collector_log = (evidence / "collector.log").open("w")
collector = subprocess.Popen(["python3", "-B", str(args.collector.resolve()), "serve", "--database", str(database), "--port", str(origin_port)], stdout=collector_log, stderr=subprocess.STDOUT)


class Capture(BaseHTTPRequestHandler):
    def log_message(self, *unused):
        pass

    def do_POST(self):
        size = int(self.headers.get("Content-Length", "0"))
        assert 0 < size <= 256
        body = self.rfile.read(size)
        value = json.loads(body)
        assert value.keys() == limits.keys()
        assert all(type(value[k]) is int and 0 <= value[k] <= cap for k, cap in limits.items())
        row = {"method": self.command, "path": self.path, "header_names": sorted(self.headers.keys()), "body": value}
        captures.append(row)
        (evidence / "wire-captures.json").write_text(json.dumps(captures, indent=2) + "\n")
        with closing(http.client.HTTPConnection("127.0.0.1", origin_port, timeout=5)) as conn:
            conn.request("POST", self.path, body, {"Content-Type": "application/json", "Content-Length": str(len(body))})
            response = conn.getresponse(); response.read(); status = response.status
        self.send_response_only(status); self.send_header("Content-Length", "0"); self.end_headers()


proxy = HTTPServer(("127.0.0.1", 0), Capture)
proxy_port = proxy.server_port
thread = threading.Thread(target=proxy.serve_forever, daemon=True); thread.start()
with (app / "Contents/Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
assert "DroidBridgeUsageEndpoint" not in info and info.get("DroidBridgeUsageLane", "off") == "off", "Default package must not enable production delivery"
preferences = root / "preferences.json"
preferences.write_text(json.dumps({"bulkWrapperOnboardingEnabled": False, "deviceAudioRoutes": {"emulator-5580": "phone"}})); preferences.chmod(0o600)
for _ in range(100):
    if database.exists():
        break
    if collector.poll() is not None:
        raise RuntimeError("Collector exited before startup")
    time.sleep(.05)
assert database.exists()
command = [str(app / "Contents/MacOS/DroidBridge"), "--companion-qa-root", str(root), "--serial", "emulator-5580", "--usage-loopback-port", str(proxy_port)]
app_log = (evidence / "application.log").open("w")
main = subprocess.Popen(command, stdout=app_log, stderr=subprocess.STDOUT)
state = {"scope": str(root), "app": str(app), "main_pid": main.pid, "collector_pid": collector.pid, "proxy_port": proxy_port, "origin_port": origin_port, "command": command, "executable_sha256": hashlib.sha256((app / "Contents/MacOS/DroidBridge").read_bytes()).hexdigest(), "production_endpoint_absent": True}
(evidence / "runtime-state.json").write_text(json.dumps(state, indent=2) + "\n")
print(json.dumps(state, indent=2), flush=True)
try:
    deadline = time.monotonic() + 1200
    while not (root / "finish").exists():
        if time.monotonic() > deadline:
            raise RuntimeError("Runtime review timed out")
        if collector.poll() is not None:
            raise RuntimeError("Collector unexpectedly exited")
        time.sleep(.2)
finally:
    proxy.shutdown(); proxy.server_close(); thread.join(timeout=3)
    collector.terminate(); collector.wait(timeout=10); collector_log.close()
    if main.poll() is None:
        main.terminate(); main.wait(timeout=10)
    app_log.close()
    if database.exists():
        with closing(sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True)) as db:
            db.row_factory = sqlite3.Row
            result = {"tables": [row["name"] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")], "columns": [row["name"] for row in db.execute("PRAGMA table_info(weekly)")], "totals": [dict(row) for row in db.execute("SELECT * FROM weekly ORDER BY week")], "database_mode": oct(database.stat().st_mode & 0o777), "captured_requests": len(captures)}
            (evidence / "receiver-readback.json").write_text(json.dumps(result, indent=2) + "\n")
    if (root / "Logs").exists(): shutil.copytree(root / "Logs", evidence / "runtime-session-logs", dirs_exist_ok=True)
    if (root / "AnonymousUsage/aggregate-v1.json").exists(): shutil.copy2(root / "AnonymousUsage/aggregate-v1.json", evidence / "final-local-aggregate.json")
    print("Runtime hold ended; exact QA broker/process cleanup remains with reviewer", flush=True)
