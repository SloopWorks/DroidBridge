#!/usr/bin/env python3
"""Observe the installed executable's real --wrapper path, with and without
the optional companion connection. The passive public-AppKit observer records
local NSWindow visibility separately from native presented video. Exact child
SIGTERM deliberately exercises supervisor cleanup. No separate bundle-identity
or WindowServer paint/focus claim is made by this benchmark.
"""
import argparse
import json
import math
import os
from pathlib import Path
import subprocess
import time

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--app', type=Path, required=True)
    p.add_argument('--qa-root', type=Path, required=True)
    p.add_argument('--serial', choices=['emulator-5582', 'emulator-5580'], required=True)
    p.add_argument('--broker-probe', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--trace', action='store_true')
    p.add_argument('--host-context', default='unspecified')
    args = p.parse_args()
    root = args.qa_root.resolve(strict=True)
    assert root.stat().st_uid == os.getuid() and root.stat().st_mode & 0o777 == 0o700
    args.output.mkdir(parents=True, exist_ok=False)
    observer = root/'preview-observer.dylib'
    repo = Path(__file__).resolve().parents[1]
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit', str(repo/'scripts/verify-companion-window-observer.m'), '-o', str(observer)], check=True, capture_output=True)
    def request(operation, payload=None):
        result = subprocess.run([str(args.broker_probe.resolve()), '--companion-qa-root', str(root), '--serial', args.serial], input=json.dumps({'operation': operation, 'payload': payload or {}}), text=True, check=True, capture_output=True, timeout=20)
        return json.loads(result.stdout)['data']
    phones = request('status')['devices']
    device = next(d for d in phones if d['serial'] == args.serial and d['connected'] and d['paired'])
    rows = []
    saved_sessions = (root/'sessions.json').read_bytes() if (root/'sessions.json').exists() else None
    try:
        cohorts = [(True, 0), (False, 0), (False, 1), (True, 1), (True, 2), (False, 2), (False, 3), (True, 3), (True, 4), (False, 4)]
        for connected, index in cohorts:
            request('connect', {'serial': args.serial}) if connected else request('disconnect', {'device_id': device['device_id']})
            name = 'Settings Performance'
            observation = root/'preview-observation.json'
            observation.unlink(missing_ok=True)
            environment = os.environ.copy()
            environment.update(DYLD_INSERT_LIBRARIES=str(observer), DROIDBRIDGE_PREVIEW_OBSERVATIONS=str(observation), DROIDBRIDGE_PREVIEW_TITLE=name)
            log = (root/'preview-child.log').open('wb')
            began = time.monotonic()
            child = subprocess.Popen([str(args.app/'Contents/MacOS/DroidBridge'), '--wrapper', '--launch', 'com.android.settings', '--name', name, '--backend', 'native', '--serial', args.serial, '--companion-qa-root', str(root)] + (['--companion-launch-trace'] if args.trace else []), env=environment, stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 25
                while time.monotonic() < deadline:
                    if observation.exists():
                        value = json.loads(observation.read_text())
                        if value.get('first_presented_video_uptime') is not None:
                            break
                    if child.poll() is not None:
                        raise RuntimeError('The exact wrapper sample exited before video readiness')
                    time.sleep(.01)
                else:
                    raise RuntimeError('The exact wrapper sample did not present video within its bound')
                assert 0 <= value['constructor_uptime'] - began < 5, 'Observer and parent clock boundaries differ'
                rows.append({'companion_connected': connected, 'sample': index + 1, 'local_preview_ms': (value['first_visible_window_uptime'] - began) * 1000, 'first_presented_video_ms': (value['first_presented_video_uptime'] - began) * 1000, 'constructor_to_preview_ms': (value['first_visible_window_uptime'] - value['constructor_uptime']) * 1000, 'load_average_1_5_15_min': os.getloadavg()})
                trace = root/f'launch-trace-{child.pid}.jsonl'
                if args.trace and trace.exists():
                    events = [json.loads(line) for line in trace.read_text().splitlines()]
                    rows[-1]['launch_trace_ms'] = {e['phase']: (e['uptime'] - began) * 1000 for e in events if e['uptime'] >= began}
            finally:
                if child.poll() is None:
                    child.terminate()
                child.wait(timeout=10)
                log.close()
                # Allow the surviving exact-parent supervisor to clean up.
                time.sleep(1)
    except Exception as error:
        (args.output/'results.json').write_text(json.dumps({'passed': False, 'error': str(error), 'rows': rows}, indent=2))
        raise
    finally:
        request('connect', {'serial': args.serial})
        if saved_sessions is not None:
            (root/'sessions.json').write_bytes(saved_sessions)
    groups = {}
    for connected in [True, False]:
        group = [x for x in rows if x['companion_connected'] == connected]
        groups['connected' if connected else 'disconnected'] = {}
        for boundary in ['local_preview_ms', 'first_presented_video_ms']:
            values = sorted(x[boundary] for x in group)
            groups['connected' if connected else 'disconnected'][boundary] = {'n': len(values), 'p50': values[math.ceil(len(values)*.5)-1], 'p95': values[math.ceil(len(values)*.95)-1]}
    result = {'passed': all(x['local_preview_ms'] <= 100 for x in rows), 'host_context': args.host_context, 'execution_passed': True, 'cold_preview_target_ms': 100, 'cold_preview_target_passed': all(x['local_preview_ms'] <= 100 for x in rows), 'ordering': 'interleaved ABBA connected/disconnected, five per cohort', 'scope': 'Same installed executable --wrapper path; paired saved trust with companion connected vs deliberately disconnected; no separate bundle identity or WindowServer paint/focus claim', 'sampling': '10 ms public NSWindow/accessibility observer; process spawn includes dyld; first video may contain Android system decorations before app content', 'rows': rows, 'groups': groups}
    (args.output/'results.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(groups), flush=True)

if __name__ == '__main__':
    main()
