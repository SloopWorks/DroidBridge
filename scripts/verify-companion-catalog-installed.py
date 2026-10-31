#!/usr/bin/env python3
"""Real owned-emulator package changes -> both installed AppKit catalogs.

Requires explicit exclusive device/GUI handoff and the installed observer runner.
Only purpose-created Alpha/Beta fixture APKs are installed/removed. No Refresh
button, private journal or credential access; cached status uses public NSXPC.
"""
import argparse, hashlib, importlib.util, json, os, select, stat, subprocess, threading, time
from pathlib import Path


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--serial', choices=['emulator-5580', 'emulator-5582'], required=True)
    p.add_argument('--adb', type=Path, required=True)
    p.add_argument('--qa-root', type=Path, required=True)
    p.add_argument('--rpc', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    root = args.qa_root.resolve(strict=True)
    assert root.stat().st_uid == os.getuid() and stat.S_IMODE(root.stat().st_mode) == 0o700
    assert not args.output.exists(), 'Retain earlier attempts'
    args.output.mkdir(parents=True)
    spec = importlib.util.spec_from_file_location('installed', Path(__file__).with_name('verify-companion-installed.py'))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    f = module.InstalledFlow.__new__(module.InstalledFlow)
    f.args, f.root, f.output, f.process, f.events = args, root, args.output, None, []
    f.sequence = json.loads((root/'receipt.json').read_text())['id']
    rpc = subprocess.Popen([str(args.rpc.resolve(strict=True)), '--companion-qa-root', str(root), '--serial', args.serial], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    def request(op, payload=None):
        rpc.stdin.write(json.dumps({'operation': op, 'payload': payload or {}})+'\n'); rpc.stdin.flush()
        assert select.select([rpc.stdout], [], [], 15)[0], 'Bounded public IPC timed out'
        reply = json.loads(rpc.stdout.readline()); assert reply.get('status') == 'ok', reply
        return reply['data']
    def phone():
        value = request('status'); candidates = [d for d in value['devices'] if args.serial in d['aliases'] and d['connected'] and d['paired']]
        assert len(candidates) == 1 and not value['sessions'], 'Use one paired phone and no sessions for catalog mutation tests'
        return candidates[0]
    def state(window):
        v = f.action('status', window=window)
        labels = v['texts'] + [b['title'] for b in v['buttons']]
        return {label: label in labels for label in ['Input Alpha', 'Input Alpha Updated', 'Input Beta']}
    def save():
        (args.output/'result.json').write_text(json.dumps(report, indent=2))
    report = {'passed': False, 'boundary': 'Android package operation and public cached broker status -> actual shipping AppKit row state in both visible windows', 'refresh_clicked': False, 'mutations': []}
    try:
        first = phone(); device = first['device_id']; trust = first['trust_id']
        f.action('set_field', window='DroidBridge', label='Search Android apps', value='Input')
        f.action('click', label='Companion section Apps')
        f.action('set_field', label='Companion app search', value='Input')
        for _ in range(80):
            if state('DroidBridge').get('Input Beta') and state('DroidBridge Companion').get('Input Beta'): break
            time.sleep(.05)
        else: raise RuntimeError('Initial automatic catalog was not visible')
        fixtures = Path(__file__).resolve().parents[1]/'.build/desktop-input-fixture'
        manifest = json.loads((fixtures/'manifest.json').read_text())
        for name in ['InputAlpha-v1', 'InputAlpha-v2', 'InputBeta-v1']:
            row = next(r for r in manifest if r['name'] == name)
            assert hashlib.sha256((fixtures/(name+'.apk')).read_bytes()).hexdigest() == row['sha256']
        operations = [
            ('remove_beta', ['uninstall', 'dev.droidbridge.inputbeta'], {'Input Alpha Updated': True, 'Input Beta': False}),
            ('install_beta', ['install', '-r', str(fixtures/'InputBeta-v1.apk')], {'Input Alpha Updated': True, 'Input Beta': True}),
            ('remove_alpha', ['uninstall', 'dev.droidbridge.inputalpha'], {'Input Alpha Updated': False, 'Input Alpha': False, 'Input Beta': True}),
            ('install_alpha_v1', ['install', '-r', str(fixtures/'InputAlpha-v1.apk')], {'Input Alpha': True, 'Input Alpha Updated': False, 'Input Beta': True}),
            ('rename_icon_alpha_v2', ['install', '-r', str(fixtures/'InputAlpha-v2.apk')], {'Input Alpha': False, 'Input Alpha Updated': True, 'Input Beta': True}),
        ]
        for name, parts, expected in operations:
            before = phone(); token = before['catalog_change_token']
            before_catalog = request('catalog', {'device_id': device, 'expected_trust_id': trust})
            initial_main, initial_companion = state('DroidBridge'), state('DroidBridge Companion')
            main_needs_change = not all(initial_main[k] == v for k, v in expected.items())
            companion_needs_change = not all(initial_companion[k] == v for k, v in expected.items())
            start = time.monotonic(); child = subprocess.Popen([str(args.adb), '-s', args.serial, *parts], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            finished = []
            def reap():
                out, err = child.communicate()
                finished.append((time.monotonic(), out, err, child.returncode))
            waiter = threading.Thread(target=reap, daemon=True); waiter.start()
            completion, token_at, main_at, companion_at = None, None, None, None
            observations = []
            while time.monotonic()-start < 20:
                now = time.monotonic()
                if completion is None and finished: completion = finished[0][0]
                current = phone()
                if token_at is None and current['catalog_change_token'] != token: token_at = time.monotonic()
                main_state = state('DroidBridge'); main_time = time.monotonic()
                companion_state = state('DroidBridge Companion'); companion_time = time.monotonic()
                if main_needs_change and main_at is None and all(main_state[k] == v for k, v in expected.items()): main_at = main_time
                if companion_needs_change and companion_at is None and all(companion_state[k] == v for k, v in expected.items()): companion_at = companion_time
                observations.append({'from_start_ms': round((now-start)*1000, 2), 'token_changed': token_at is not None, 'main': main_state, 'companion': companion_state})
                if completion is not None and token_at is not None and main_at is not None and companion_at is not None: break
                time.sleep(.03)
            waiter.join(timeout=5); assert finished, 'Owned Android package operation did not complete'
            actual_end, stdout, stderr, exit_code = finished[0]
            completion = actual_end
            assert exit_code == 0 and 'Success' in stdout, 'Owned fixture package operation failed'
            end = completion or time.monotonic()
            row = {'initial_main_state': initial_main, 'initial_companion_state': initial_companion, 'main_expected_transition': main_needs_change, 'companion_expected_transition': companion_needs_change, 'operation': name, 'android_process_start_monotonic': start, 'android_process_completion_observed_monotonic': end, 'broker_token_observed_monotonic': token_at, 'main_row_observed_monotonic': main_at, 'companion_row_observed_monotonic': companion_at, 'observations': observations, 'android_output': stdout.strip(), 'android_exit': child.returncode}
            for key, point in [('main', main_at), ('companion', companion_at)]:
                row[key+'_from_android_completion_ms'] = round((point-end)*1000, 2) if point is not None else None
                row[key+'_from_android_start_ms'] = round((point-start)*1000, 2) if point is not None else None
                row[key+'_from_broker_token_ms'] = round((point-token_at)*1000, 2) if point is not None and token_at is not None else None
            after_catalog = request('catalog', {'device_id': device, 'expected_trust_id': trust})
            row['catalog_before'] = before_catalog; row['catalog_after'] = after_catalog
            row['passed'] = all(t is not None for t in [token_at, main_at, companion_at]) and all(row[k] <= 2000 for k in ['main_from_android_completion_ms', 'companion_from_android_completion_ms', 'main_from_broker_token_ms', 'companion_from_broker_token_ms'])
            report['mutations'].append(row); save()
        report['passed'] = all(row['passed'] for row in report['mutations'])
        f.capture('automatic-companion-catalog.png'); f.capture('automatic-main-catalog.png', window='DroidBridge')
    finally:
        rpc.stdin.close()
        try: rpc.wait(timeout=3)
        except subprocess.TimeoutExpired: rpc.terminate(); rpc.wait(timeout=3)
        report['actions'] = f.events; save()
    print(json.dumps({'passed': report['passed'], 'results': [{k: r[k] for k in ['operation', 'passed', 'main_from_android_completion_ms', 'companion_from_android_completion_ms', 'main_from_broker_token_ms', 'companion_from_broker_token_ms']} for r in report['mutations']]}))
    if not report['passed']: raise SystemExit(1)

if __name__ == '__main__': main()
