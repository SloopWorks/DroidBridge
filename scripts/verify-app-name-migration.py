#!/usr/bin/env python3
"""Run the installed GUI's automatic migration on the accepted emulator cohort.

Requires exclusive ownership of DroidBridge (quit its main GUI/wrappers first).
It does not start an Android device, change preferences, or create new apps.
The accepted catalog must contain only the task-owned emulator-5580 cohort.
"""
import hashlib, json, pathlib, plistlib, re, subprocess, tempfile, time
from urllib.parse import unquote, urlparse

home = pathlib.Path.home()
app = home / 'Applications/DroidBridge.app'
support = home / 'Library/Application Support/DroidBridge/ManagedApps.noindex'
catalog = support / 'catalog.json'
out = pathlib.Path('verification/clean-app-names')
out.mkdir(parents=True, exist_ok=True)
def path(value): return pathlib.Path(unquote(urlparse(value).path))
def sha(file): return hashlib.sha256(file.read_bytes()).hexdigest()
def run(*args): return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, timeout=20)
def unsigned(file):
    with tempfile.TemporaryDirectory(prefix='droidbridge-name-code-') as directory:
        copy = pathlib.Path(directory) / 'DroidBridge'
        copy.write_bytes(file.read_bytes())
        run('/usr/bin/codesign', '--remove-signature', str(copy))
        return sha(copy)
def bundle(record): return path(record['activeBundleURL'] if record['location'] == 'active' else record['inactiveBundleURL'])
def hashed(record): return bool(re.search(r'-[0-9a-f]{16}\.app$', record['bundleFilename']))

before = json.loads(catalog.read_text())
assert before['records'] and not before['reservations'] and not before['publications']
assert all(r['deviceSerial'] == 'emulator-5580' and hashed(r) and (r.get('namingVersion') or 1) < 2 for r in before['records'].values())
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['DroidBridgeManagedNamingVersion'] == 2
old_plist = plistlib.loads((home / 'Library/LaunchAgents/app.droidbridge.availability.plist').read_bytes())
old_helper = old_plist['ProgramArguments'][0]
saved = {}
for key, record in before['records'].items():
    resources = bundle(record) / 'Contents/Resources'
    saved[key] = {'icon': sha(resources / 'AndroidApp.png'), 'config': json.loads((resources / 'launch.json').read_text()), 'record': record}
(out / 'before.json').write_text(json.dumps(before, indent=2))
(out / 'saved-before.json').write_text(json.dumps(saved, indent=2))
(out / 'old-helper.txt').write_text(old_helper)
samples, phase1, first_clean = [], None, None
host_log = (out / 'installed-migration-host.log').open('w')
child = subprocess.Popen([str(app / 'Contents/MacOS/DroidBridge'), '--serial', 'emulator-5580'], stdout=host_log, stderr=subprocess.STDOUT)
start = time.monotonic()
try:
    deadline = start + 240
    while time.monotonic() < deadline:
        assert child.poll() is None, 'Installed main exited during migration'
        current = json.loads(catalog.read_text())
        rows = current['records']
        assert set(rows) == set(saved), 'Migration must not admit or remove apps'
        old = sum((r.get('namingVersion') or 1) < 2 for r in rows.values())
        clean = sum(not hashed(r) for r in rows.values())
        sample = {'seconds': round(time.monotonic()-start, 3), 'old_readers': old, 'clean_names': clean, 'publications': len(current['publications'])}
        if not samples or sample.items() - {'seconds': sample['seconds']}.items() != samples[-1].items() - {'seconds': samples[-1]['seconds']}.items():
            samples.append(sample)
            (out / 'phase-samples.json').write_text(json.dumps(samples, indent=2))
            print(sample, flush=True)
        if not old and not clean and phase1 is None:
            phase1 = current
            (out / 'phase1-catalog.json').write_text(json.dumps(current, indent=2))
        if clean:
            assert not old, 'Clean names published before incompatible readers upgraded'
            new_plist = plistlib.loads((home / 'Library/LaunchAgents/app.droidbridge.availability.plist').read_bytes())
            assert new_plist['ProgramArguments'][0] != old_helper, 'Old helper was not replaced'
            if first_clean is None: first_clean = sample
        if clean == len(rows) and not current['publications'] and not current['reservations']: break
        time.sleep(0.2)
    else: raise AssertionError('Automatic migration did not complete in 240s')
    assert phase1 is not None, 'Did not observe compatibility-only pass'
    payload = unsigned(app / 'Contents/MacOS/DroidBridge')
    for key, record in current['records'].items():
        prior = saved[key]
        assert record['bundleIdentifier'] == prior['record']['bundleIdentifier']
        assert record['name'] == prior['record']['name'] and record['backend'] == prior['record']['backend']
        assert record['bundleFilename'] == record['name'] + '.app' or record['bundleFilename'].startswith(record['name'] + ' (' + record['packageName']), record['bundleFilename']
        resources = bundle(record) / 'Contents/Resources'
        assert sha(resources / 'AndroidApp.png') == prior['icon']
        config = json.loads((resources / 'launch.json').read_text())
        assert {k:v for k,v in config.items() if k != 'managed_generation'} == {k:v for k,v in prior['config'].items() if k != 'managed_generation'}
        assert unsigned(bundle(record) / 'Contents/MacOS/DroidBridge') == payload
        run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(bundle(record)))
        old = prior['record']
        backup = support / f"backups/{old['deviceHash']}/{old['packageName']}-{old['generation']}.app"
        assert backup.exists(), 'Original generation was not retained'
    report = {'passed': True, 'installed_version': info['CFBundleShortVersionString'], 'installed_build': info['CFBundleVersion'], 'installed_main_sha256': sha(app / 'Contents/MacOS/DroidBridge'), 'unsigned_payload_sha256': payload, 'cohort': len(saved), 'seconds': round(time.monotonic()-start, 3), 'first_clean': first_clean, 'samples': samples, 'old_helper': old_helper, 'new_helper': new_plist['ProgramArguments'][0], 'icons_config_ids_preserved': True, 'strict_signatures': True, 'old_generations_retained': True, 'phone_required': False}
    (out / 'migration-result.json').write_text(json.dumps(report, indent=2)+'\n')
    (out / 'after.json').write_text(json.dumps(current, indent=2))
    print(json.dumps(report, indent=2), flush=True)
finally:
    if child.poll() is None:
        run('/usr/bin/swift', '-e', 'import AppKit; if let app = NSRunningApplication(processIdentifier: Int32(CommandLine.arguments[1])!) { _ = app.terminate() }', str(child.pid))
        try: child.wait(timeout=20)
        except subprocess.TimeoutExpired:
            child.terminate(); child.wait(timeout=15)
    host_log.close()
