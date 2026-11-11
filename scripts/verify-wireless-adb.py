#!/usr/bin/env python3
"""Exercise Android Settings QR pairing and real TLS ADB on DroidBridge_API35.

Run only with the owned emulator-5580. Scoped loopback forwards and temporary
DNS-SD proxy advertisements bridge the emulator's NAT; no shared server restart.
The QR image, Android IDs, and temporary ADB key never enter retained evidence.
"""
import argparse
import json
import os
import pathlib
import re
import socket
import subprocess
import tempfile
import time
import uuid
import xml.etree.ElementTree as ET

P = argparse.ArgumentParser(description=__doc__)
P.add_argument("--app", type=pathlib.Path, required=True)
P.add_argument("--probe", type=pathlib.Path, required=True)
P.add_argument("--output", type=pathlib.Path, required=True)
P.add_argument("--direct-camera", action="store_true", help="Restart the dedicated AVD with emulator imagefile camera input")
P.add_argument("--android-code", action="store_true", help="Exercise the stock Settings code fallback without retaining its code")
P.add_argument("--overlap-advertisements", action="store_true", help="Keep the old exact phone advertisement briefly alongside the rotated endpoint")
a = P.parse_args()
assert not (a.android_code and a.direct_camera)
app = a.app.resolve()
assert app.suffix == ".app" and ".build" not in app.parts
runtime = app / "Contents/Resources/Runtime"
adb = runtime / "bin/adb"
sdk = pathlib.Path.home() / "Library/Android/sdk"
shared_adb = sdk / "platform-tools/adb"
serial = "emulator-5580"
out = a.output.resolve()
out.mkdir(parents=True, exist_ok=True)
env_base = {k: v for k, v in os.environ.items() if not k.startswith(("ADB_", "DROIDBRIDGE_", "DYLD_"))}
evidence = []


def run(cmd, *, env=env_base, timeout=15, check=True):
    completed = subprocess.run([str(x) for x in cmd], env=env, capture_output=True, text=True, timeout=timeout, check=check)
    return completed.stdout


def device(*cmd, timeout=15):
    return run([shared_adb, "-s", serial, *cmd], timeout=timeout)


def until(label, callback, seconds=25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = callback()
        if result:
            return result
        time.sleep(.15)
    raise RuntimeError(f"Timed out: {label}")


def note(text):
    evidence.append(text)
    print(text, flush=True)


def nodes():
    text = device("exec-out", "uiautomator", "dump", "/dev/tty")
    start, end = text.find("<?xml"), text.find("</hierarchy>")
    if start < 0 or end < start:
        return []
    return list(ET.fromstring(text[start:end + len("</hierarchy>")]).iter("node"))


def tap(entries, title):
    match = next((n for n in entries if n.get("text") == title), None)
    if match is None:
        return False
    x1, y1, x2, y2 = [int(v) for v in re.findall(r"\d+", match.get("bounds", ""))]
    if x1 >= x2 or y1 >= y2:
        return False
    device("shell", "input", "tap", (x1 + x2) // 2, (y1 + y2) // 2)
    return True


def wireless_page():
    current = nodes()
    if any(n.get("text") == "Scan QR code" for n in current):
        device("shell", "input", "keyevent", "4")
        current = nodes()
    if any(n.get("text") == "Use wireless debugging" for n in current):
        return current
    device("shell", "am", "start", "-W", "-a", "android.settings.APPLICATION_DEVELOPMENT_SETTINGS")
    for _ in range(10):
        if tap(nodes(), "Wireless debugging"):
            return nodes()
        device("shell", "input", "swipe", "540", "1580", "540", "490", "480")
    raise RuntimeError("Cannot find Wireless debugging in Android Settings")


def set_wireless(on):
    if (device("shell", "settings", "get", "global", "adb_wifi_enabled").strip() == "1") != on:
        assert tap(wireless_page(), "Use wireless debugging")
        if on:
            tap(nodes(), "ALLOW")
    until(f"Android Wireless debugging {'on' if on else 'off'}",
          lambda: (device("shell", "settings", "get", "global", "adb_wifi_enabled").strip() == "1") == on)


def port_log(pattern):
    # Filter in memory; the logcat stream and any device-specific material are
    # never copied to artifacts. AVD port properties may be unreadable.
    text = device("logcat", "-d", "-b", "all", "-t", "1500", "-v", "brief")
    values = re.findall(pattern, text)
    return int(values[-1]) if values else None


def safe_quit(process):
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=7)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=3)


assert device("emu", "avd", "name").splitlines()[0] == "DroidBridge_API35"
before_listener = run(["/usr/sbin/lsof", "-nP", "-iTCP:5037", "-sTCP:LISTEN"])
start_wireless = device("shell", "settings", "get", "global", "adb_wifi_enabled").strip() == "1"
with tempfile.TemporaryDirectory(prefix="droidbridge-wireless-qa-", dir="/private/tmp") as td:
    root = pathlib.Path(td)
    home = root / "adb-home"
    home.mkdir(mode=0o700)
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        server_port = probe.getsockname()[1]
    env = dict(env_base, ADB_SERVER_SOCKET=f"tcp:{server_port}", ADB_USB="0", ADB_EMU="0", ADB_MDNS="0",
               ADB_LOCAL_TRANSPORT_MAX_PORT="0", ANDROID_USER_HOME=str(home),
               DROIDBRIDGE_ADB=str(adb), DROIDBRIDGE_SCRCPY=str(runtime / "Player.app/Contents/MacOS/scrcpy"),
               DROIDBRIDGE_SERVER=str(runtime / "share/scrcpy/scrcpy-server"), DROIDBRIDGE_SUPERVISOR=str(runtime / "bin/DroidBridgeSupervisor"),
               DROIDBRIDGE_WIRELESS_EVIDENCE=str(out))
    log = (root / "server.log").open("w")
    server = subprocess.Popen([str(adb), "-L", f"tcp:{server_port}", "nodaemon", "server"], env=env, stdout=log, stderr=log)
    forwards = {}
    ads = []
    pair = None
    relaunched = None

    def start_probe(phase, file):
        args = [str(a.probe.resolve()), phase, "--companion-qa-root", str(root), "--serial", serial]
        return subprocess.Popen(args, env=env, stdout=file, stderr=file)

    def relay(guest_port):
        assert 0 < guest_port < 65536
        host_port = int(device("forward", "tcp:0", f"tcp:{guest_port}").strip())
        forwards[host_port] = guest_port
        return host_port

    def publish(instance, kind, guest_port):
        assert re.fullmatch(r"[A-Za-z0-9_-]{4,63}(?: \([1-9][0-9]{0,2}\))?", instance)
        host_port = relay(guest_port)
        proc = subprocess.Popen(["/usr/bin/dns-sd", "-P", instance, kind, "local", str(host_port),
                                 f"droidbridge-qa-{uuid.uuid4().hex[:12]}.local.", "127.0.0.1"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        ads.append(proc)
        return host_port, proc

    def remove(host_port):
        guest_port = forwards.pop(host_port)
        if f"{serial} tcp:{host_port} tcp:{guest_port}" in device("forward", "--list").splitlines():
            device("forward", "--remove", f"tcp:{host_port}")

    try:
        until("owned loopback ADB server", lambda: server.poll() is None and str(server.pid) in
              run(["/usr/sbin/lsof", "-nP", f"-iTCP:{server_port}", "-sTCP:LISTEN"], check=False))
        note("Started an isolated loopback ADB server with USB, emulator scanning and mDNS disabled.")
        if not a.direct_camera:
            set_wireless(True)
        with (out / "pair.log").open("w") as pair_log:
            if a.android_code:
                assert tap(wireless_page(), "Pair device with pairing code")

                def read_code_dialog():
                    values = [n.get("text", "") for n in nodes()]
                    codes = [v for v in values if re.fullmatch(r"[0-9]{6}", v)]
                    ports = [int(m[1]) for v in values if (m := re.fullmatch(r"[0-9.]+:(\d+)", v))]
                    return (codes[0], ports[0]) if len(codes) == 1 and len(ports) == 1 else None

                code, port = until("Android Settings code dialog", read_code_dialog, 10)
                pair_host, pair_ad = relay(port), None
                path = root / "pair-code.json"
                with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as handle:
                    json.dump({"code": code, "endpoint": f"127.0.0.1:{pair_host}"}, handle)
                del code
                pair = start_probe("code", pair_log)
                note("Used Android’s real Settings code dialog as the camera-independent fallback. The code stayed in private test storage.")
            else:
                pair = start_probe("pair", pair_log)
                instance_path = root / "camera-ready"
                until("private QR camera input", instance_path.exists)
                instance = instance_path.read_text()
            if a.direct_camera:
                device("emu", "kill")
                time.sleep(1.5)
                with (out / "image-camera-emulator.log").open("w") as emulog:
                    relaunched = subprocess.Popen([str(sdk / "emulator/emulator"), "-avd", "DroidBridge_API35", "-port", "5580",
                                                   "-no-window", "-no-audio", "-no-boot-anim", "-no-snapshot-save",
                                                   "-camera-back", f"imagefile:{root / 'camera.png'}"], stdout=emulog, stderr=emulog)
                until("emulator ready", lambda: run([shared_adb, "-s", serial, "shell", "getprop", "sys.boot_completed"], check=False).strip() == "1", 40)
                assert device("emu", "avd", "name").splitlines()[0] == "DroidBridge_API35"
                device("shell", "input", "keyevent", "224")
                device("shell", "wm", "dismiss-keyguard")
                set_wireless(True)
            elif not a.android_code:
                device("emu", "virtualscene-image", "wall", root / "camera.png")
            if not a.android_code:
                old_pair_port = port_log(r"Pairing server started on port (\d+)")
                assert tap(wireless_page(), "Pair device with QR code"), "No Android Settings scanner action"
                pair_port = until("Android Settings QR scanner started a pairing server",
                                  lambda: (p if (p := port_log(r"Pairing server started on port (\d+)")) and p != old_pair_port else None), 30)
                note("Android Settings camera scanned the invitation and started its real pairing server.")
                pair_host, pair_ad = publish(instance, "_adb-tls-pairing._tcp", pair_port)
            guid_path = root / "paired-service"
            until("PAKE pairing receipt", guid_path.exists, 25)
            service = guid_path.read_text()
            guest_port = until("Android TLS port", lambda: port_log(r"TlsServer running on port (\d+)"))
            host_port, conn_ad = publish(service, "_adb-tls-connect._tcp", guest_port)
            assert pair.wait(timeout=35) == 0, "Pair/connect probe failed; inspect pair.log"
            safe_quit(pair_ad)
            remove(pair_host)
            (root / "camera.png").unlink(missing_ok=True)
            note("Paired and established a verified TLS ADB transport with the packaged runtime.")
        # Stop the first TLS listener through Android UI and recreate it. Only
        # the disposable connection relay and its DNS-SD record are removed.
        set_wireless(False)
        if not a.overlap_advertisements:
            safe_quit(conn_ad)
        remove(host_port)
        # Only the test server's exact obsolete relay. Do not allow its own
        # stock ADB reconnect timer to preserve a stale device-list entry.
        run([adb, "disconnect", f"127.0.0.1:{host_port}"], env=env, check=False)
        listing = run([adb, "devices", "-l"], env=env)
        assert not any(line.split()[:1] == [f"127.0.0.1:{host_port}"] for line in listing.splitlines())
        set_wireless(True)
        rotated = until("rotated Android TLS port",
                        lambda: (p if (p := port_log(r"TlsServer running on port (\d+)")) and p != guest_port else None))
        instance = service + " (2)" if a.overlap_advertisements else service
        new_host, _ = publish(instance, "_adb-tls-connect._tcp", rotated)
        assert new_host != host_port
        (out / "endpoints.json").write_text(json.dumps({"initial_android_tls_port": guest_port, "rotated_android_tls_port": rotated,
            "initial_test_relay": host_port, "rotated_test_relay": new_host, "old_advertisement_retained_during_reconnect": a.overlap_advertisements}, indent=2) + "\n")
        note("Android rotated its TLS port. Started a fresh Mac probe with the same saved profile.")
        with (out / "reconnect.log").open("w") as reconnect_log:
            recovery = start_probe("recover", reconnect_log)
            try:
                assert recovery.wait(timeout=70) == 0, "Reconnect/video probe failed; inspect reconnect.log"
            finally:
                safe_quit(recovery)
        assert (root / "recovered-serial").read_text() == f"127.0.0.1:{new_host}"
        note("Saved phone reconnected without a QR or typed values; native AppKit showed decoded Android video.")
    finally:
        safe_quit(pair)
        for proc in ads:
            safe_quit(proc)
        for port in list(forwards):
            remove(port)
        if not a.direct_camera and not a.android_code:
            device("emu", "virtualscene-image", "wall")
        try:
            set_wireless(start_wireless)
        finally:
            safe_quit(server)
            log.close()
            for path in (root / "Logs").glob("session-*.log*"):
                (out / path.name).write_bytes(path.read_bytes())
            (out / "steps.json").write_text(json.dumps(evidence, indent=2) + "\n")
    assert not forwards
    assert run(["/usr/sbin/lsof", "-nP", "-iTCP:5037", "-sTCP:LISTEN"]) == before_listener
    print("PASS: cleanup left the shared ADB listener unchanged", flush=True)
