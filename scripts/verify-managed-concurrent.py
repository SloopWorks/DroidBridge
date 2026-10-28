#!/usr/bin/env python3
"""Two actual installed managed apps, live-frame receipts and crash cleanup.

Requires exclusive dedicated emulator-5580 ownership. Sends SIGTERM only to
the two exact wrapper processes this invocation starts; supervisor cleanup is
part of the assertion. Does not change preferences or accepted app bundles.
"""
import hashlib, json, pathlib, plistlib, subprocess, tempfile, time

home = pathlib.Path.home()
app = home / 'Applications/DroidBridge.app'
support = home / 'Library/Application Support/DroidBridge'
active = (home / 'Applications/DroidBridge Apps/Devices').resolve()
logs = home / 'Library/Logs/DroidBridge'
output = pathlib.Path('verification/onboarding/concurrent-managed')
output.mkdir(parents=True, exist_ok=True)
adb = str(app / 'Contents/Resources/Runtime/bin/adb')
def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, timeout=15)
def device(*args):
    return run(adb, '-s', 'emulator-5580', *args)
def unsigned_digest(path):
    with tempfile.TemporaryDirectory(prefix='droidbridge-code-') as directory:
        target = pathlib.Path(directory) / 'DroidBridge'
        target.write_bytes(path.read_bytes())
        run('/usr/bin/codesign', '--remove-signature', str(target))
        return hashlib.sha256(target.read_bytes()).hexdigest()
def virtual_displays():
    return device('shell', 'dumpsys', 'display').count('DisplayDeviceInfo{')
def forwards():
    return '\n'.join(line for line in device('forward', '--list').splitlines() if line.startswith('emulator-5580 '))
baseline = {'forwards': forwards(), 'displays': virtual_displays()}
manifest = json.loads((support / 'ManagedApps.noindex/catalog.json').read_text())
expected = unsigned_digest(app / 'Contents/MacOS/DroidBridge')
records = [next(r for r in manifest['records'].values()
                if r['deviceSerial'] == 'emulator-5580' and r['packageName'] == package)
           for package in ['com.android.settings', 'com.android.deskclock']]
before = set(logs.glob('session-*.log.jsonl'))
children, handles = [], []
report = {'baseline': baseline, 'sessions': [], 'purpose': 'real managed native concurrent launch and owned-parent termination cleanup'}
try:
    for record in records:
        from urllib.parse import urlparse, unquote
        bundle = pathlib.Path(unquote(urlparse(record['activeBundleURL']).path))
        assert bundle.resolve().is_relative_to(active) and not bundle.is_symlink()
        info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
        assert info['CFBundleIdentifier'] == record['bundleIdentifier']
        assert info['CFBundleVersion'] == '6' and record['backend'] == 'native'
        run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(bundle))
        executable = bundle / 'Contents/MacOS/DroidBridge'
        assert unsigned_digest(executable) == expected
        handle = (output / (record['packageName'] + '.host.log')).open('w')
        handles.append(handle)
        children.append(subprocess.Popen([str(executable)], stdout=handle, stderr=subprocess.STDOUT))
    deadline = time.monotonic() + 35
    while time.monotonic() < deadline:
        found = {}
        for path in set(logs.glob('session-*.log.jsonl')) - before:
            events = []
            for line in path.read_text().splitlines():
                try: events.append(json.loads(line))
                except json.JSONDecodeError: pass # a concurrent final write can be incomplete
            for record in records:
                selected = [e for e in events if e.get('package') == record['packageName'] and e.get('device') == 'emulator-5580']
                if any(e.get('state') == 'running' for e in selected) and any(e.get('event') == 'native_window_presented' and e.get('details', {}).get('visible') == 'true' for e in selected):
                    found[record['packageName']] = {'events': selected, 'log': str(path)}
        if len(found) == 2:
            report['sessions'] = found
            break
        assert all(child.poll() is None for child in children), 'Wrapper exited before real native presentation'
        time.sleep(.1)
    assert len(report['sessions']) == 2, 'Both real native frame/window receipts required'
    assert virtual_displays() >= baseline['displays'] + 2
    report['pids'] = [child.pid for child in children]
    report['simultaneous_display_count'] = virtual_displays()
    report['unsigned_payload_sha256'] = expected
finally:
    for child in children:
        if child.poll() is None: child.terminate()
    for child in children:
        try: child.wait(timeout=5)
        except subprocess.TimeoutExpired: child.kill(); child.wait(timeout=5)
    for handle in handles: handle.close()
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        after = {'forwards': forwards(), 'displays': virtual_displays()}
        if after == baseline: break
        time.sleep(.2)
    report['after'] = after
    (output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
assert report['after'] == baseline, 'Owned process/display/forward cleanup failed'
assert len(report['sessions']) == 2
print('PASS two exact installed managed native apps, live presentation, distinct displays, owned-parent crash cleanup')
