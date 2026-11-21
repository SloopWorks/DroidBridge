#!/usr/bin/env python3
"""Cold connection test; only the named owned emulator and a private QA scope.

Leaves the observed review app open for visual inspection. The report records
its exact PID/root so the reviewer can quit only that process after inspection.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument("--app", type=Path, required=True)
parser.add_argument("--evidence", type=Path, required=True)
parser.add_argument("--hold-for-review", action="store_true", help="Keep the emulator parent alive until the exact review app quits")
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
app = args.app.resolve()
evidence = args.evidence.resolve()
evidence.mkdir(parents=True, exist_ok=True)
root = Path(tempfile.mkdtemp(prefix="droidbridge-quick-cold-", dir="/private/tmp"))
root.chmod(0o700)
executable = app / "Contents/MacOS/DroidBridge"
adb = app / "Contents/Resources/Runtime/bin/adb"
helper = app / "Contents/Resources/Runtime/bin/DroidBridgeAvailability"
commands = []


def run(command, timeout=20, check=True):
    value = subprocess.run([str(x) for x in command], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout)
    commands.append({"command": [str(x) for x in command], "returncode": value.returncode, "output": value.stdout})
    (evidence / "cold-commands.json").write_text(json.dumps(commands, indent=2) + "\n")
    if check and value.returncode:
        raise RuntimeError(value.stdout)
    return value.stdout


def owned_pids():
    rows = subprocess.check_output(["/bin/ps", "-axo", "pid=,command="], text=True).splitlines()
    return [int(parts[0]) for line in rows if len(parts := line.strip().split(None, 1)) == 2 and (parts[1] == str(executable) or parts[1].startswith(str(executable) + " "))]


def wait(label, predicate, seconds=90):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.2)
    raise RuntimeError("Timed out: " + label)


def running_video():
    for path in (root / "Logs").glob("*.jsonl"):
        for line in path.read_text().splitlines():
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            if value.get("state") == "running" and value.get("package") == "dev.droidbridge.screen":
                return str(path)
    return None


assert not owned_pids(), "Close this exact review app before running the cold test"
assert executable.is_file() and helper.is_file()
state = run([adb, "-s", "emulator-5580", "get-state"], check=False).strip()
if state == "device":
    run([adb, "-s", "emulator-5580", "emu", "avd", "name"])
    assert commands[-1]["output"].splitlines()[0] == "DroidBridge_API35", "Wrong dedicated AVD"
    run([adb, "-s", "emulator-5580", "emu", "kill"])
else:
    assert "emulator-5580" not in run([adb, "devices"]), "Preserve unknown unavailable emulator on owned port"
wait("owned emulator stop", lambda: "emulator-5580" not in run([adb, "devices"]))
preferences = {"enabled": False, "target": "screen", "serial": "emulator-5580", "deviceName": "Dedicated Android 15 emulator", "hostBundlePath": str(app)}
(root / "quick-open.json").write_text(json.dumps(preferences))
(root / "preferences.json").write_text(json.dumps({"bulkWrapperOnboardingEnabled": False, "deviceAudioRoutes": {"emulator-5580": "phone"}}))
helper_args = [helper, "--adb", adb, "--private-root", root / "ManagedApps.noindex", "--active-root", root / "Applications", "--preferences", root / "preferences.json", "--log", root / "helper.jsonl", "--companion-qa-root", root, "--serial", "emulator-5580"]
run([*helper_args, "--once"])
assert not owned_pids(), "Disabled helper opened DroidBridge"
preferences["enabled"] = True
(root / "quick-open.json").write_text(json.dumps(preferences))
helper_log = (evidence / "cold-helper.log").open("w")
helper_process = subprocess.Popen([str(x) for x in helper_args], stdout=helper_log, stderr=subprocess.STDOUT)
emulator_log = (evidence / "cold-emulator.log").open("w")
try:
    time.sleep(1)
    assert not owned_pids(), "Missing saved device opened DroidBridge"
    began = time.monotonic()
    emulator = subprocess.Popen([str(repo / "scripts/android-emulator.sh")], cwd=repo, stdout=emulator_log, stderr=subprocess.STDOUT)
    print("Started dedicated emulator; waiting for automatic app launch", flush=True)
    observed = wait("automatic exact-host launch", owned_pids, seconds=120)
    opened_seconds = time.monotonic() - began
    assert len(observed) == 1, "Duplicated automatic host launch"
    run([adb, "-s", "emulator-5580", "shell", "am", "start", "-n", "dev.droidbridge.testapp20261121/.MainActivity"])
    video_log = wait("real current-screen decoded video", running_video, seconds=45)
    time.sleep(3)
    assert owned_pids() == observed, "Repeated polling launched another main app"
    report = {"passed": True, "scope": str(root), "app": str(app), "pid": observed[0], "helper_pid": helper_process.pid, "emulator_pid": emulator.pid, "automatic_launch_after_emulator_start_seconds": opened_seconds, "native_running_log": video_log, "disabled_and_disconnected_do_not_launch": True, "single_host_after_repeated_polls": True, "executable_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(), "app_left_open_for_visual_review": True}
    (evidence / "cold-results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2), flush=True)
    if args.hold_for_review:
        print("Holding owned emulator for live UI review; quit only the reported exact app PID to finish", flush=True)
        wait("review app quit", lambda: not owned_pids(), seconds=600)
        report["review_app_quit_observed"] = True
        report["forwards_after_quit"] = run([adb, "-s", "emulator-5580", "forward", "--list"])
        (evidence / "cold-results.json").write_text(json.dumps(report, indent=2) + "\n")
finally:
    helper_process.terminate()
    helper_process.wait(timeout=15)
    helper_log.close()
    emulator_log.close()
