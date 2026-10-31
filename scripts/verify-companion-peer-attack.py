#!/usr/bin/env python3
"""Owned emulator regression: ordinary Android app impersonates companion.

No secrets in argv or evidence. All device operations require an explicitly assigned 5580/5582 emulator.
The Core probe receives synthetic credentials through bounded stdin. Public
certificate pin/device UUID are supplied from genuine companion installation.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import stat
import subprocess
import time
import uuid
import re
import xml.etree.ElementTree as ET

PACKAGE = "dev.droidbridge.companion"
ATTACKER = "dev.droidbridge.peerattack"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--serial", choices=["emulator-5580", "emulator-5582"], required=True)
    parser.add_argument("--adb", type=Path, required=True)
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--server-pin", required=True)
    parser.add_argument("--device-id", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--attacker-apk", type=Path, default=Path("AndroidCompanion/attacker/build/outputs/apk/debug/attacker-debug.apk"))
    parser.add_argument("--aapt", type=Path, default=Path.home() / "Library/Android/sdk/build-tools/35.0.0/aapt")
    args = parser.parse_args()
    assert len(args.server_pin) == 64 and all(c in "0123456789abcdef" for c in args.server_pin)
    assert str(uuid.UUID(args.device_id)).lower() == args.device_id.lower()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    def adb(*parts, binary=False):
        result = subprocess.run([str(args.adb), "-s", args.serial, *parts], capture_output=True, timeout=20, check=True)
        return result.stdout if binary else result.stdout.decode("utf-8", "strict")
    def shell(*parts):
        return adb("shell", *parts)
    def probe(operation):
        data = dict(operation=operation, baseURL=f"https://127.0.0.1:{port}", serverPin=args.server_pin, deviceID=args.device_id)
        if operation == "pair": data.update(pairingSecret=pair_secret, macID=str(uuid.uuid4()))
        if operation == "reconnect": data.update(credential=bearer, trustID=str(uuid.uuid4()))
        result = subprocess.run([str(args.probe)], input=json.dumps(data).encode(), capture_output=True, timeout=12, check=True)
        value = json.loads(result.stdout)
        assert "credential" not in value and "pairingSecret" not in value
        return value
    def acquire_port():
        directory = Path.home() / "Library/Application Support/DroidBridge/StreamPorts.noindex"
        assert directory.is_dir() and directory.stat().st_uid == os.getuid()
        for candidate in range(46000, 46064):
            descriptor = os.open(directory / f"{candidate}.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
                os.close(descriptor); continue
            try: fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError: os.close(descriptor); continue
            test = socket.socket()
            try: test.bind(("127.0.0.1", candidate))
            except OSError: test.close(); os.close(descriptor); continue
            test.close()
            return candidate, descriptor
        raise RuntimeError("No owned test port available")
    def read_capture():
        return json.loads(adb("exec-out", "run-as", ATTACKER, "cat", "files/capture.json"))
    def wait_capture(run_id, ready=False):
        deadline = time.monotonic() + 7
        while time.monotonic() < deadline:
            try:
                value = read_capture()
                if value["run_id"] == run_id and (value["listening"] if ready else value["captures"]): return value
            except (subprocess.SubprocessError, KeyError, ValueError): pass
            time.sleep(.05)
        raise RuntimeError("Attacker did not produce expected run receipt")
    def uid(package):
        value = shell("pm", "list", "packages", "-U", package).strip().splitlines()
        line = next(line for line in value if line.startswith(f"package:{package} "))
        return int(line.rsplit("uid:", 1)[1])
    def requested_permissions():
        raw = shell("dumpsys", "package", ATTACKER)
        lines = raw.split("requested permissions:", 1)[1].split("install permissions:", 1)[0].splitlines()
        return sorted(line.strip() for line in lines if line.strip().startswith("android.permission."))

    pair_secret = secrets.token_urlsafe(32)
    bearer = secrets.token_urlsafe(32)
    assert len(pair_secret) == len(bearer) == 43
    def installed_apk_hash(package):
        locations = shell("pm", "path", package).strip().splitlines()
        assert len(locations) == 1 and locations[0].startswith("package:/data/app/")
        path = locations[0].removeprefix("package:")
        digest = shell("sha256sum", path).split()[0]
        assert len(digest) == 64
        return digest
    companion_uid, attacker_uid = uid(PACKAGE), uid(ATTACKER)
    assert companion_uid >= 10000 and attacker_uid >= 10000 and companion_uid != attacker_uid
    permissions = requested_permissions()
    sdk = int(shell("getprop", "ro.build.version.sdk").strip())
    expected_permissions = ["android.permission.INTERNET"]
    if sdk >= 37 and "android.permission.ACCESS_LOCAL_NETWORK" in permissions:
        expected_permissions.insert(0, "android.permission.ACCESS_LOCAL_NETWORK")
    assert permissions == expected_permissions, permissions
    permission_manifest = subprocess.check_output([str(args.aapt), "dump", "permissions", str(args.attacker_apk)], text=True)
    declared = sorted(re.findall(r"uses-permission: name='([^']+)'", permission_manifest))
    assert declared == ["android.permission.INTERNET"], declared
    attacker_apk_hash = installed_apk_hash(ATTACKER)
    assert hashlib.sha256(args.attacker_apk.read_bytes()).hexdigest() == attacker_apk_hash
    report = dict(serial=args.serial, companion_uid=companion_uid, attacker_uid=attacker_uid,
                  requested_permissions=permissions, manifest_declared_permissions=declared, android_sdk=sdk,
                  platform_implicit_permissions=sorted(set(permissions)-set(declared)), probe_sha256=hashlib.sha256(args.probe.read_bytes()).hexdigest(),
                  expected_server_pin=args.server_pin, synthetic_credentials=True,
                  installed_companion_apk_sha256=installed_apk_hash(PACKAGE),
                  installed_attacker_apk_sha256=attacker_apk_hash, cases=[])
    port, descriptor = acquire_port()
    forwarded = False
    try:
        adb("forward", "--no-rebind", f"tcp:{port}", "tcp:37841"); forwarded = True
        # A real positive request first proves the forward reaches the genuine
        # installation. Then the same port is occupied by the malicious app.
        baseline = probe("hello")
        assert baseline.get("status") == "ok" and baseline.get("device_id", "").lower() == args.device_id.lower(), baseline
        report["genuine_hello_before_rebind"] = baseline
        shell("am", "force-stop", PACKAGE)
        for mode in ["tls", "plain"]:
            for operation in ["pair", "reconnect"]:
                shell("am", "force-stop", ATTACKER)
                run_id = str(uuid.uuid4())
                shell("am", "start", "-n", f"{ATTACKER}/.AttackActivity", "--es", "mode", mode,
                      "--es", "run_id", run_id, "--es", "claimed_device_id", args.device_id)
                ready = wait_capture(run_id, ready=True)
                if mode == "tls": assert ready["server_pin"] != args.server_pin
                result = probe(operation)
                assert result.get("status") == "error", result
                assert result.get("code") == ("server_pin_mismatch" if mode == "tls" else "server_authentication_failed"), result
                capture = wait_capture(run_id)
                case = dict(mode=mode, operation=operation, run_id=run_id, result=result,
                            attacker_receipt=capture, raw_capture_evidence=[])
                for index, receipt in enumerate(capture["captures"]):
                    raw = adb("exec-out", "run-as", ATTACKER, "cat", f"files/{run_id}-{index}.bin", binary=True)
                    assert len(raw) == receipt["captured_bytes"]
                    assert hashlib.sha256(raw).hexdigest() == receipt["captured_sha256"]
                    assert pair_secret.encode() not in raw and bearer.encode() not in raw
                    assert b"authorization:" not in raw.lower()
                    assert not any(raw.startswith(method) for method in [b"GET ", b"POST ", b"PUT ", b"DELETE "])
                    if mode == "tls": assert raw == b"" and not receipt["tls_handshake_completed"]
                    else: assert len(raw) >= 5 and raw[0] == 22 and raw[1] == 3  # TLS handshake record, no HTTP.
                    evidence_name = f"{mode}-{operation}-{index}.hex"
                    (output / evidence_name).write_text(raw.hex() + "\n")
                    case["raw_capture_evidence"].append(dict(path=evidence_name, bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest(), independently_verified_http_bytes=0))
                report["cases"].append(case)
                (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
        report["acceptance"] = True
    finally:
        shell("am", "force-stop", ATTACKER)
        if forwarded:
            rows = [line.split() for line in adb("forward", "--list").splitlines()]
            if [args.serial, f"tcp:{port}", "tcp:37841"] in rows:
                adb("forward", "--remove", f"tcp:{port}")
        os.close(descriptor)
        # Restore through the real exported Activity and visible button; the
        # production service is deliberately not exported to shell/other apps.
        shell("am", "start", "-n", f"{PACKAGE}/.MainActivity")
        remote_ui = "/data/local/tmp/droidbridge-peer-restore-" + str(uuid.uuid4()) + ".xml"
        restored = False
        try:
            for _ in range(3):
                shell("uiautomator", "dump", remote_ui)
                ui = ET.fromstring(shell("cat", remote_ui))
                button = next((node for node in ui.iter("node") if node.get("text") == "Start connection service"), None)
                if button is not None:
                    bounds = list(map(int, re.findall(r"[0-9]+", button.get("bounds", ""))))
                    assert len(bounds) == 4
                    shell("input", "tap", str((bounds[0] + bounds[2]) // 2), str((bounds[1] + bounds[3]) // 2))
                if button is not None or any(node.get("text") == "Stop connection service" for node in ui.iter("node")):
                    restored = True; break
                time.sleep(.2)
        finally:
            shell("rm", "-f", remote_ui)
        report["companion_service_restore_action"] = restored
        report["exact_forward_removed"] = [args.serial, f"tcp:{port}", "tcp:37841"] not in [line.split() for line in adb("forward", "--list").splitlines()]
        (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(dict(acceptance=report.get("acceptance", False), cases=len(report["cases"]), exact_forward_removed=report["exact_forward_removed"])))

if __name__ == "__main__": main()
