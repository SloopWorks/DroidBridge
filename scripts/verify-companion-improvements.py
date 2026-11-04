#!/usr/bin/env python3
"""Actual installed Mac/Android commands; only the dedicated coordinated emulator."""
import argparse
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("installed_flow", ROOT / "scripts/verify-companion-installed.py")
installed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installed)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--qa-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--adb", type=Path, required=True)
    parser.add_argument("--serial", choices=["emulator-5580"], default="emulator-5580")
    parser.add_argument("--defer-system-save", action="store_true", help="Run independent transport/frame checks; retain overall acceptance as incomplete until the real Save dialog is exercised")
    parser.add_argument("--manual-ui-checkpoint", action="store_true", help="Retain the exact scoped host after file handoff for separately recorded native keyboard/window checks")
    parser.add_argument("--reuse-pairing", action="store_true", help="Reconnect the existing trust in this exact QA scope instead of enrolling again")
    parser.add_argument("--retain-failed-ui", action="store_true", help="Keep the exact scoped UI for diagnosis before owned pairing cleanup; use stop-installed-runner to finish")
    args = parser.parse_args()
    args.leave_running = False; args.pairing_path = "manual"; args.trace = True
    flow = installed.InstalledFlow(args)
    driver = None; trust = None
    seen = threading.Event()
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/droidbridge-e2e": seen.set()
            self.send_response(200); self.end_headers(); self.wfile.write(b"DroidBridge local verification")
        def log_message(self, *_): pass
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        flow.start(); flow.prepare_phone()
        if args.reuse_pairing: flow.reconnect()
        else: flow.pair_by_import()
        flow.launch_fixture()
        binary = args.qa_root / "broker-rpc"
        modules = ROOT / ".build/debug/Modules"
        objects = sorted((ROOT / ".build/debug/DroidBridgeCore.build").glob("*.swift.o"))
        subprocess.run(["swiftc", "-parse-as-library", "-I", str(modules), str(ROOT / "scripts/verify-companion-broker-rpc.swift"), *map(str, objects), "-o", str(binary)], check=True, capture_output=True)
        driver = subprocess.Popen([str(binary), "--companion-qa-root", str(args.qa_root), "--serial", args.serial], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        def rpc(operation, payload=None):
            driver.stdin.write(json.dumps({"operation": operation, "payload": payload or {}}) + "\n"); driver.stdin.flush()
            response = json.loads(driver.stdout.readline())
            assert not response.get("error"), response.get("error")
            return response["data"]
        deadline = time.monotonic() + 30
        phone = None
        while time.monotonic() < deadline:
            devices = rpc("status")["devices"]
            phone = next((d for d in devices if (d["serial"] == args.serial or args.serial in d.get("aliases", [])) and d["connected"] and d["paired"]), None)
            if phone: break
            time.sleep(.2)
        if not phone:
            (flow.output / "connection-check.json").write_text(json.dumps([{k: d.get(k) for k in ("serial", "aliases", "paired", "connected", "connection_error")} for d in devices], indent=2))
        assert phone, "The exact paired companion did not become connected for desktop commands"
        trust = phone["trust_id"]
        clipboard = "DroidBridge explicit E2E clipboard probe"
        flow.action("clipboard_save", expected=clipboard)
        try:
            command = [str(args.adb), "-s", args.serial, "shell", "am", "instrument", "-w", "-r", "-e", "class", "dev.droidbridge.companion.CompanionDesktopE2EDeviceTest#actualMacAppliesPhoneCommandsAndDesktopPreset", "-e", "real_desktop", "1", "-e", "e2e_trust", trust, "-e", "e2e_url", f"http://127.0.0.1:{server.server_port}/droidbridge-e2e", "dev.droidbridge.companion.test/androidx.test.runner.AndroidJUnitRunner"]
            result = subprocess.run(command, capture_output=True, text=True, timeout=180)
            (flow.output / "desktop-android-instrumentation.log").write_text(result.stdout + result.stderr)
            assert result.returncode == 0 and "OK (1 test)" in result.stdout and "FAILURES" not in result.stdout, "Actual desktop command instrumentation failed; inspect its log"
            flow.action("clipboard_matches", expected=clipboard)
            assert seen.wait(10), "The browser did not load the explicit owned-loopback share URL"
        finally:
            flow.action("clipboard_restore")
        evidence = json.loads(flow.adb("shell", "cat", "/sdcard/Android/data/dev.droidbridge.companion/files/verification/desktop-e2e.json"))
        (flow.output / "desktop-actions.json").write_text(json.dumps(evidence, indent=2))
        assert len(evidence["actions"]) == 4 and all(a["status"] == "applied" for a in evidence["actions"])
        flow.events.append({"kind": "actual_phone_to_mac_actions", "count": 4, "clipboard_exact_match": True, "owned_url_loaded": True, "preset_completed": True})
        # Verify this independent boundary before a system dialog can suspend
        # UI automation. Static Android content needs an explicit resize to
        # produce a fresh decoded frame after companion shutdown.
        flow.adb("shell", "am", "start", "-W", "-n", "dev.droidbridge.companion/.MainActivity")
        flow.phone_click("Start connection service", optional=True)
        def frame_counts():
            values = {}
            for path in (args.qa_root / "Logs").glob("session-*.log.jsonl"):
                for line in path.read_text().splitlines():
                    row = json.loads(line)
                    if row.get("event") == "qa_video_metrics": values[row["session"]] = int(row["details"]["frames"])
            return values
        counts_before = frame_counts()
        before = flow.action("status")
        assert any(w["visible"] and w["title"] == "Companion Verification" for w in before["windows"])
        # BridgeService is deliberately non-exported. Exercise the actual
        # foreground confirmation instead of trying to stop it as shell UID.
        flow.phone_click("Stop connection service")
        flow.phone_click("Stop service")
        time.sleep(2)
        flow.action("resize_window", window="Companion Verification", width=760, height=940)
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            counts_after = frame_counts()
            if any(counts_after.get(key, 0) > count for key, count in counts_before.items()): break
            time.sleep(.2)
        else: raise AssertionError("No new decoded frame after companion stop and explicit native resize")
        after = flow.action("status")
        assert any(w["visible"] and w["title"] == "Companion Verification" for w in after["windows"])
        flow.events.append({"kind": "companion_stop_preserves_independent_native_window", "observed": True, "new_decoded_frames_after_stop": True, "frames_before": counts_before, "frames_after": counts_after})
        flow.adb("shell", "am", "start", "-n", "dev.droidbridge.companion/.MainActivity")
        flow.phone_click("Start connection service", optional=True)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if any(d["device_id"] == phone["device_id"] and d["connected"] for d in rpc("status")["devices"]): break
            time.sleep(.2)
        else: raise AssertionError("Companion did not reconnect after the explicit foreground test")
        records = rpc("trust_list", {"device_id": phone["device_id"]})["items"]
        receiver = next(row["mac_name"] for row in records if row["trust_id"] == trust)
        # A separate phone-display task leaves the registered Mac task intact.
        flow.adb("shell", "am", "start", "--display", "0", "-f", "0x18000000", "-n", "dev.droidbridge.companionfixture/.MainActivity")
        flow.phone_click("Share deterministic 2 MiB file")
        flow.phone_choose_trusted_mac(receiver, trust)
        flow.phone_click("Send files")
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            items = rpc("inbox_list", {"device_id": phone["device_id"]})["items"]
            if any(row["kind"] == "file_shared" and row["payload"]["size"] == 2097152 for row in items): break
            time.sleep(.2)
        else: raise AssertionError("The named Mac never received the actual file-share metadata")
        benchmark = args.qa_root / "companion-performance"
        subprocess.run(["swiftc", "-parse-as-library", "-I", str(modules), str(ROOT / "scripts/verify-companion-performance.swift"), *map(str, objects), "-o", str(benchmark)], check=True, capture_output=True)
        measured = subprocess.run([str(benchmark), "--companion-qa-root", str(args.qa_root), "--serial", args.serial], check=True, capture_output=True, text=True, timeout=180)
        performance = json.loads(measured.stdout)
        assert performance["passed"] and all(row["hashVerified"] for row in performance["actual_transfers"])
        (flow.output / "actual-transport-performance.json").write_text(json.dumps(performance, indent=2))
        flow.events.append({"kind": "actual_hash_verified_download_benchmark", "transfers": len(performance["actual_transfers"]), "bytes_each": 2097152})
        if args.defer_system_save:
            (flow.output / "component-results.json").write_text(json.dumps({"passed": True, "scope": "Actual installed phone/Mac commands, pinned transport downloads and decoded-frame independence; system Save dialog and Finder selection remain unverified", "applied_commands": 4, "hash_verified_downloads": len(performance["actual_transfers"]), "decoded_frames_after_service_stop": True, "system_save_dialog_verified": False}, indent=2))
            flow.finish(False, "Independent installed checks passed; real system Save dialog and Finder selection are deferred until the Mac is unlocked")
            return
        flow.action("navigate", section="handoff")
        flow.action("click", title="Refresh Inbox")
        flow.wait_text("sample.bin")
        destination = args.qa_root / "received-fixture.bin"
        flow.action("click_async", title="Save File…")
        print(f"Awaiting real CUA Save dialog interaction: save to {destination}", flush=True)
        deadline = time.monotonic() + 120
        while not destination.exists() and time.monotonic() < deadline: time.sleep(.2)
        assert destination.exists(), "Complete the real system Save dialog using CUA on the unlocked Mac"
        flow.wait_text("the phone confirmed completion", timeout=35)
        expected = hashlib.sha256(bytes(i % 251 for i in range(65536)) * 32).hexdigest()
        assert destination.stat().st_size == 2097152 and hashlib.sha256(destination.read_bytes()).hexdigest() == expected
        flow.action("click", title="Reveal Saved File")
        flow.events.append({"kind": "actual_verified_file_handoff", "bytes": 2097152, "sha256": expected, "finder_reveal_control_executed": True})
        flow.capture("completed-actions-mac.png")
        if args.manual_ui_checkpoint:
            checkpoint = args.qa_root / "manual-ui-checks.json"
            checkpoint.unlink(missing_ok=True)
            print("Awaiting native UI review of the exact scoped host; record manual-ui-checks.json after observation", flush=True)
            deadline = time.monotonic() + 600
            while not checkpoint.exists() and time.monotonic() < deadline:
                assert flow.process.poll() is None, "The scoped host exited during native UI review"
                time.sleep(.2)
            assert checkpoint.exists(), "Native UI review was not completed"
            manual = json.loads(checkpoint.read_text())
            assert manual.get("passed") is True and manual.get("checks"), "Native UI review must record its actual checks"
            (flow.output / "native-ui-checks.json").write_text(json.dumps(manual, indent=2))
            flow.events.append({"kind": "separately_observed_native_ui", "checks": manual["checks"]})
        flow.finish(True)
    except Exception as error:
        if args.retain_failed_ui:
            args.leave_running = True
        flow.finish(False, str(error))
        if args.retain_failed_ui:
            print("Retaining failed scoped UI for diagnosis before cleanup; use stop-installed-runner to finish", flush=True)
            flow.hold()
        raise
    finally:
        if trust:
            cleanup = subprocess.run([str(args.adb), "-s", args.serial, "shell", "am", "instrument", "-w", "-r", "-e", "class", "dev.droidbridge.companion.CompanionDesktopE2EDeviceTest#cleanupOwnedPairing", "-e", "real_desktop", "1", "-e", "cleanup_pairing", "1", "-e", "e2e_trust", trust, "dev.droidbridge.companion.test/androidx.test.runner.AndroidJUnitRunner"], capture_output=True, text=True, timeout=45)
            (flow.output / "pairing-cleanup.log").write_text(cleanup.stdout + cleanup.stderr)
        if driver:
            driver.stdin.close()
            try: driver.wait(timeout=10)
            except subprocess.TimeoutExpired: driver.terminate(); driver.wait(timeout=10)
        server.shutdown(); server.server_close()
        label = "dev.droidbridge.companion.broker.qa." + hashlib.sha256(str(args.qa_root).encode()).hexdigest()[:12]
        subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{label}"], capture_output=True)


if __name__ == "__main__": main()
