#!/usr/bin/env python3
"""Run the packaged display-move scenario on the dedicated API 35 emulator.

Click the actual Mac window's Move to Mac button when prompted. The driver
requires the same Android task and real video readiness after the click.
"""
import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile
import time


def run(*args, check=True):
    return subprocess.run([str(arg) for arg in args], capture_output=True, text=True, timeout=20, check=check).stdout


def records(path):
    result = []
    if path.exists():
        for line in path.read_text().splitlines():
            try:
                result.append(json.loads(line))
            except json.JSONDecodeError:
                pass  # The active writer may be appending its final line.
    return result


def wait(host, label, condition, seconds=35):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        assert host.poll() is None, f"Mac process exited: {label}"
        result = condition()
        if result:
            return result
        time.sleep(0.1)
    raise AssertionError(f"Timed out waiting for {label}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--backend", choices=("native", "scrcpy"), required=True)
    parser.add_argument("--observe-seconds", type=int, choices=range(0, 31), default=2)
    args = parser.parse_args()
    app, out, backend = args.app.resolve(), args.output.resolve(), args.backend
    assert app.suffix == ".app" and ".build" not in app.parts, "Use an external packaged application"
    out.mkdir(parents=True, exist_ok=True)
    serial, package = "emulator-5580", "dev.droidbridge.testapp7"
    executable = app / "Contents/MacOS/DroidBridge"
    adb = app / "Contents/Resources/Runtime/bin/adb"

    def android(*cmd):
        return run(adb, "-s", serial, *cmd)

    def snapshot(label):
        text = android("shell", "dumpsys", "activity", "-p", package, "activities")
        (out / f"{label}-tasks.txt").write_text(text)
        display, entries = None, set()
        for line in text.splitlines():
            if match := re.match(r"Display #(\d+) ", line):
                display = int(match[1])
            if match := re.match(r"\s*\* Hist\s+#\d+: ActivityRecord\{\S+ u(\d+) " + re.escape(package) + r"/\S+ t(\d+)\}", line):
                entries.add((display, int(match[1]), int(match[2])))
        return entries

    def app_start(label, *options):
        result = android("shell", "am", "start", "-W", *options, "-a", "android.intent.action.MAIN",
                         "-c", "android.intent.category.LAUNCHER", "-n", package + "/.MainActivity")
        (out / f"{label}-start.txt").write_text(result)
        assert "Status: ok" in result, result

    def forwards():
        return sorted(line for line in android("forward", "--list").splitlines() if line.startswith(serial + " "))

    assert android("emu", "avd", "name").splitlines()[0] == "DroidBridge_API35"
    assert android("shell", "getprop", "sys.boot_completed").strip() == "1"
    android("shell", "input", "-d", "0", "keyevent", "224")
    android("shell", "wm", "dismiss-keyguard")
    baseline_forwards = forwards()

    with tempfile.TemporaryDirectory(prefix="droidbridge-display-move-", dir="/private/tmp") as directory:
        directory = pathlib.Path(directory)
        root = directory / "qa"
        root.mkdir(mode=0o700)
        (root / "preferences.json").write_text(json.dumps({"bulkWrapperOnboardingEnabled": False, "deviceAudioRoutes": {serial: "phone"}}))
        quit_source, quit_app = directory / "quit.swift", directory / "quit"
        quit_source.write_text('import AppKit\nlet pid = Int32(CommandLine.arguments[1])!\nif NSRunningApplication(processIdentifier: pid)?.terminate() != true { exit(1) }\n')
        run("swiftc", quit_source, "-o", quit_app)
        logs = root / "Logs"
        command = [str(executable), "--wrapper", "--companion-qa-root", str(root), "--serial", serial,
                   "--launch", package, "--name", "DroidBridge Display Probe", "--backend", backend, "--companion-launch-trace"]
        (out / "command.json").write_text(json.dumps(command, indent=2) + "\n")
        env = {k: v for k, v in os.environ.items() if not k.startswith(("DROIDBRIDGE_", "DYLD_"))}

        def ready(exclude=None):
            for path in logs.glob("session-*.log.jsonl"):
                if path == exclude:
                    continue
                rows = records(path)
                assert all(row.get("device") == serial for row in rows), "Escaped the dedicated emulator scope"
                bound = next((row["display"] for row in rows if row.get("event") == "app_display_bound"), None)
                if bound is None:
                    continue
                if backend == "native":
                    video = next((row["details"] for row in rows if row.get("event") == "native_content_presented"), None)
                else:
                    video = {"renderer": "SDL texture"} if "Texture" in path.with_suffix("").read_text() else None
                if video:
                    return path, bound, video
            return None

        with (out / "host.log").open("w") as host_log:
            host = subprocess.Popen(command, env=env, stdout=host_log, stderr=host_log)
            try:
                first, display, initial_video = wait(host, "decoded video on the Mac", ready)
                before = snapshot("before")
                assert len(before) == 1 and next(iter(before))[0] == display, before
                _, user, task = next(iter(before))
                app_start("untargeted-adb")
                time.sleep(3.5)
                assert snapshot("untargeted-adb") == before, "Untargeted launch unexpectedly moved the task"
                assert not any(row.get("event") == "app_move_presented" for row in records(first))
                app_start("phone-adb", "--display", "0")
                assert snapshot("phone-adb") == {(0, user, task)}, "Android did not move the existing task to display 0"
                moved_at = time.monotonic()
                presented = wait(host, "Move to Mac action", lambda: next((row for row in records(first) if row.get("event") == "app_move_presented"), None))
                detection_seconds = round(time.monotonic() - moved_at, 3)
                time.sleep(4.5)
                assert android("get-state").strip() == "device"
                assert snapshot("still-on-phone") == {(0, user, task)}
                assert list(logs.glob("session-*.log.jsonl")) == [first], "A successor took the app back automatically"
                assert not any(row.get("event") == "recovery_enqueued" for row in records(first))
                (out / "ready-for-move-button.json").write_text(json.dumps({"host_pid": host.pid, "backend": backend, "window_number": presented["details"]["window_number"], "task_id": task}, indent=2) + "\n")
                print(f"Ready: click Move to Mac in the {backend} test window (PID {host.pid})", flush=True)
                second, new_display, returned_video = wait(host, "video after Move to Mac", lambda: ready(first), seconds=180)
                time.sleep(args.observe_seconds)
                assert host.poll() is None
                assert snapshot("returned") == {(new_display, user, task)}, "Returning did not preserve the task"
                assert [row["state"] for row in records(second) if "state" in row][-1] == "running"
                if backend == "native":
                    assert returned_video["window_number"] == initial_video["window_number"], "Native window was replaced"
                result = {"backend": backend, "same_android_task": task, "display_path": [display, 0, new_display],
                          "detect_seconds": detection_seconds, "remained_on_phone_until_click": True,
                          "adb_stayed_connected": True, "initial_video": initial_video, "returned_video": returned_video,
                          "original_session": first.name, "returned_session": second.name,
                          "app": str(app), "executable_sha256": hashlib.sha256(executable.read_bytes()).hexdigest()}
            finally:
                if host.poll() is None:
                    run(quit_app, host.pid, check=False)
                    try:
                        host.wait(timeout=25)
                    except subprocess.TimeoutExpired:
                        host.kill()
                        host.wait(timeout=5)
                for path in logs.glob("session-*.log*"):
                    shutil.copy2(path, out / path.name)
                suffix = hashlib.sha256(str(root).encode()).hexdigest()[:12]
                label = f"dev.droidbridge.companion.broker.qa.{suffix}"
                plist = pathlib.Path.home() / "Library/LaunchAgents" / (label + ".plist")
                if plist.exists():
                    data = plistlib.loads(plist.read_bytes())
                    assert data["Label"] == label and data["ProgramArguments"][0].startswith(str(root) + "/")
                    run("/bin/launchctl", "bootout", f"gui/{os.getuid()}/{label}", check=False)
                    plist.unlink()

    assert host.returncode == 0, "Packaged host did not quit cleanly"
    assert forwards() == baseline_forwards, "A session forward remained after clean quit"
    result["clean_quit_and_exact_forward_cleanup"] = True
    (out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"PASS {backend}: same task moved from Mac to phone and back with real video", flush=True)


if __name__ == "__main__":
    main()
