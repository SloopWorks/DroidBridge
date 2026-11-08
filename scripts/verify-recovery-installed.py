#!/usr/bin/env python3
"""Test an actual packaged app outside .build using only emulator-5580.

Disrupts an exact owned Android server/native transport, or the supervised SDL
client. Never restarts the shared ADB server or controls a physical device.
"""
import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time

p = argparse.ArgumentParser()
p.add_argument('app', type=pathlib.Path)
p.add_argument('--output', type=pathlib.Path, required=True)
a = p.parse_args()
app = a.app.resolve()
assert '.build' not in app.parts, 'Acceptance artifact must be outside .build'
out = a.output.resolve(); out.mkdir(parents=True, exist_ok=True)
adb = app/'Contents/Resources/Runtime/bin/adb'
serial = 'emulator-5580'
results = []

def run(args, timeout=15, check=True):
    result = subprocess.run([str(x) for x in args], capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f'{args}: {result.stdout}{result.stderr}')
    return result

def android(*args):
    return run([adb, '-s', serial, *args]).stdout

def events(path):
    records = []
    if path.exists():
        for line in path.read_text().splitlines():
            try: records.append(json.loads(line))
            except json.JSONDecodeError: pass  # writer may still be appending
    return records

def wait(condition, message, host, timeout=50):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        assert host.poll() is None, f'Host exited: {message}'
        value = condition()
        if value: return value
        time.sleep(.1)
    raise AssertionError(f'Timed out: {message}')

def running(logs, excluded, backend):
    for path in logs.glob('session-*.log.jsonl'):
        if path.name in excluded: continue
        rows = events(path)
        assert all(r.get('device') == serial for r in rows), 'QA scope escaped dedicated emulator'
        if not any(r.get('state') == 'running' for r in rows): continue
        if backend == 'native':
            if not any(r.get('event') == 'native_content_presented' for r in rows): continue
        elif 'Texture' not in path.with_suffix('').read_text(): continue
        return path
    return None

def disrupt(path, backend, host):
    rows = events(path)
    if backend == 'native':
        scid = next(r['scid'] for r in rows if r.get('event') == 'native_resources')
        matches = []
        for line in android('shell', 'ps', '-A', '-o', 'PID,ARGS').splitlines():
            fields = line.split()
            if len(fields) > 1 and fields[1] == 'app_process' and f'com.genymobile.scrcpy.Server 5.0.1 scid={scid} ' in line:
                matches.append(fields[0])
        assert len(matches) == 1, 'Cannot identify exact owned Android server'
        android('shell', 'kill', matches[0])
        return {'exact_scid': scid, 'android_pid': int(matches[0])}
    records = []
    for line in path.with_suffix('').read_text().splitlines():
        try: records.append(json.loads(line))
        except json.JSONDecodeError: pass
    started = next(r for r in records if r.get('event') == 'supervisor_started' and r.get('parent') == host.pid)
    child = started['child']
    info = run(['ps', '-p', child, '-o', 'ppid=,command=']).stdout.strip().split(maxsplit=1)
    parent = int(info[0])
    assert str(app/'Contents/Resources/Runtime/Player.app/Contents/MacOS/scrcpy') in info[1]
    assert int(run(['ps', '-p', parent, '-o', 'ppid=']).stdout.strip()) == host.pid
    os.kill(child, signal.SIGKILL)
    return {'exact_supervised_client_pid': child}

assert android('shell', 'getprop', 'sys.boot_completed').strip() == '1'
android('shell', 'input', '-d', '0', 'keyevent', '224')
android('shell', 'wm', 'dismiss-keyguard')
with tempfile.TemporaryDirectory(prefix='droidbridge-recovery-acceptance-', dir='/private/tmp') as temp:
    temp = pathlib.Path(temp)
    (temp/'quit.swift').write_text('import AppKit\nguard let app=NSRunningApplication(processIdentifier:Int32(CommandLine.arguments[1])!) else {exit(2)}\nif !app.terminate() {exit(1)}\n')
    run(['swiftc', temp/'quit.swift', '-o', temp/'quit'], timeout=60)
    for backend in ['native', 'scrcpy']:
        root = temp/backend; root.mkdir(mode=0o700)
        (root/'preferences.json').write_text(json.dumps({'bulkWrapperOnboardingEnabled': False, 'deviceAudioRoutes': {serial: 'phone'}}))
        logdir = root/'Logs'
        env = {k: v for k, v in os.environ.items() if not k.startswith('DROIDBRIDGE_') and k not in ['DYLD_INSERT_LIBRARIES', 'DYLD_LIBRARY_PATH']}
        command = [str(app/'Contents/MacOS/DroidBridge'), '--companion-qa-root', str(root), '--serial', serial, '--launch', 'dev.droidbridge.testapp7', '--name', 'Recovery Acceptance', '--backend', backend]
        (out/f'{backend}-command.json').write_text(json.dumps(command, indent=2)+'\n')
        with (out/f'{backend}-host.log').open('w') as hostlog:
            host = subprocess.Popen(command, env=env, stdout=hostlog, stderr=hostlog)
            try:
                first = wait(lambda: running(logdir, set(), backend), 'initial decoded content', host)
                disruption = disrupt(first, backend, host)
                wait(lambda: any(r.get('event') == 'recovery_enqueued' for r in events(first)), 'transport failure queued without device absence', host)
                assert android('get-state').strip() == 'device'
                resumed = wait(lambda: running(logdir, {first.name}, backend), 'automatic successor decoded content', host)
                assert host.poll() is None
                assert any(r.get('event') == 'recovery_succeeded' for r in events(resumed))
                if backend == 'native':
                    initial_window = next(r['details']['window_number'] for r in events(first) if r.get('event') == 'native_content_presented')
                    resumed_window = next(r['details']['window_number'] for r in events(resumed) if r.get('event') == 'native_content_presented')
                    assert initial_window == resumed_window, 'Native recovery replaced the Mac window'
                # Pinned ADB format_host_command uses host-serial:<serial> for
                # this command. Interrupt only emulator-5580, never all devices.
                previous_names = {path.name for path in logdir.glob('session-*.log.jsonl')}
                reconnect_at = time.monotonic()
                reconnect_output = android('reconnect')
                transport_resumed = wait(lambda: running(logdir, previous_names, backend), 'recovery after scoped ADB reconnect', host)
                assert any(r.get('event') == 'recovery_succeeded' for r in events(transport_resumed))
                recovery_seconds = round(time.monotonic() - reconnect_at, 3)
                run([temp/'quit', host.pid]); host.wait(timeout=30)
                assert host.returncode == 0
                results.append({'backend': backend, 'passed': True, 'host_pid': host.pid, 'same_host_survived': True, 'original': first.name, 'successor': resumed.name, 'transport_successor': transport_resumed.name, 'scoped_adb_reconnect_output': reconnect_output.strip(), 'transport_recovery_seconds': recovery_seconds, 'decoded_content': True, 'same_native_window': backend == 'native', 'disruption': disruption})
            finally:
                if host.poll() is None:
                    run([temp/'quit', host.pid], check=False)
                    try: host.wait(timeout=25)
                    except subprocess.TimeoutExpired: host.kill(); host.wait(timeout=5)
                for path in logdir.glob('*'):
                    if path.is_file(): shutil.copy2(path, out/f'{backend}-{path.name}')
                # Remove only this QA scope's registered helper, preserving all
                # production broker jobs and their credentials/data.
                suffix = hashlib.sha256(str(root).encode()).hexdigest()[:12]
                label = f'dev.droidbridge.companion.broker.qa.{suffix}'
                plist = pathlib.Path.home()/'Library/LaunchAgents'/f'{label}.plist'
                if plist.exists():
                    data = plistlib.loads(plist.read_bytes())
                    assert data['Label'] == label and data['ProgramArguments'][0].startswith(str(root)+'/')
                    run(['/bin/launchctl', 'bootout', f'gui/{os.getuid()}/{label}'], check=False)
                    plist.unlink()
        owned = [line for line in android('forward', '--list').splitlines() if line.split() and line.split()[0] == serial and 'scrcpy_' in line]
        assert not owned, f'Session forward leaked: {owned}'
        # Android's remote shell/virtual-display destruction may finish shortly
        # after the supervised host process exits. Require bounded convergence,
        # preserving observations rather than treating one snapshot as a leak.
        cleanup_start = time.monotonic()
        snapshots = []
        while True:
            servers = [line for line in android('shell', 'ps', '-A', '-o', 'PID,ARGS').splitlines() if 'com.genymobile.scrcpy.Server 5.0.1' in line]
            snapshots.append({'elapsed_seconds': round(time.monotonic() - cleanup_start, 3), 'servers': servers})
            if not servers: break
            assert time.monotonic() - cleanup_start < 10, 'Owned Android server did not clean up within ten seconds'
            time.sleep(.2)
        (out/f'{backend}-cleanup.json').write_text(json.dumps(snapshots, indent=2)+'\n')
        assert 'DisplayDeviceInfo{"scrcpy"' not in android('shell', 'dumpsys', 'display'), 'Owned virtual display leaked'
        print(f'PASS packaged {backend}: interrupted stream recovered automatically with real decoded content', flush=True)
(out/'results.json').write_text(json.dumps({'artifact': str(app), 'sha256': hashlib.sha256((app/'Contents/MacOS/DroidBridge').read_bytes()).hexdigest(), 'results': results}, indent=2)+'\n')
