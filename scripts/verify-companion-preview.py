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
    p.add_argument('--samples-per-cohort', type=int, default=5)
    args = p.parse_args()
    if not 5 <= args.samples_per_cohort <= 20:
        p.error('--samples-per-cohort must be between 5 and 20')
    root = args.qa_root.resolve(strict=True)
    assert root.stat().st_uid == os.getuid() and root.stat().st_mode & 0o777 == 0o700
    args.output.mkdir(parents=True, exist_ok=False)
    observer = root/'preview-observer.dylib'
    repo = Path(__file__).resolve().parents[1]
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit', str(repo/'scripts/verify-companion-window-observer.m'), '-o', str(observer)], check=True, capture_output=True)
    def request(operation, payload=None):
        result = subprocess.run([str(args.broker_probe.resolve()), '--companion-qa-root', str(root), '--serial', args.serial], input=json.dumps({'operation': operation, 'payload': payload or {}}), text=True, check=True, capture_output=True, timeout=20)
        return json.loads(result.stdout)['data']
    def child_processes(pid):
        result = subprocess.run(['/usr/bin/pgrep', '-P', str(pid)], capture_output=True, text=True, timeout=3)
        if result.returncode not in (0, 1):
            raise RuntimeError('Cannot inspect the exact benchmark child process tree')
        return [int(value) for value in result.stdout.split()]
    def process_identity(pid):
        result = subprocess.run(['/bin/ps', '-ww', '-p', str(pid), '-o', 'lstart=,command='], capture_output=True, text=True, timeout=3)
        if result.returncode not in (0, 1):
            raise RuntimeError('Cannot inspect an owned benchmark process identity')
        return result.stdout.strip()
    def supervisor_events(path):
        if path.stat().st_size > 1_048_576:
            raise RuntimeError('Benchmark session log exceeds its bounded metadata inspection')
        events = []
        for line in path.read_text(errors='replace').splitlines():
            if not line.startswith('{'):
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict) and str(value.get('event', '')).startswith('supervisor_'):
                events.append(value)
        return events
    phones = request('status')['devices']
    device = next(d for d in phones if d['serial'] == args.serial and d['connected'] and d['paired'])
    if device.get('profile') != 'balanced':
        raise RuntimeError('Select Balanced before comparing connected and disconnected startup; both cohorts must use the same video ceiling')
    rows = []
    saved_sessions = (root/'sessions.json').read_bytes() if (root/'sessions.json').exists() else None
    try:
        cohorts = [(connected, index) for index in range(args.samples_per_cohort)
                   for connected in ([True, False] if index % 2 == 0 else [False, True])]
        for connected, index in cohorts:
            request('connect', {'serial': args.serial}) if connected else request('disconnect', {'device_id': device['device_id']})
            actual = next(d for d in request('status')['devices'] if d['device_id'] == device['device_id'])
            if actual.get('connected') is not connected or actual.get('paired') is not True or actual.get('profile') != 'balanced':
                raise RuntimeError('Broker status did not confirm the requested connection cohort and Balanced profile')
            name = 'Settings Performance'
            observation = root/'preview-observation.json'
            observation.unlink(missing_ok=True)
            environment = os.environ.copy()
            environment.update(DYLD_INSERT_LIBRARIES=str(observer), DROIDBRIDGE_PREVIEW_OBSERVATIONS=str(observation), DROIDBRIDGE_PREVIEW_TITLE=name)
            log = (root/'preview-child.log').open('wb')
            prior_logs = set((root/'Logs').glob('session-*.log'))
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
                if value.get('pid') != child.pid:
                    raise RuntimeError('Window observation does not belong to the exact benchmark child')
                assert 0 <= value['constructor_uptime'] - began < 5, 'Observer and parent clock boundaries differ'
                after_video = next(d for d in request('status')['devices'] if d['device_id'] == device['device_id'])
                if after_video.get('connected') is not connected or after_video.get('paired') is not True or after_video.get('profile') != 'balanced':
                    raise RuntimeError('The confirmed broker connection cohort changed before first video')
                rows.append({'companion_connected': connected, 'actual_broker_connected': actual['connected'], 'after_video_broker_connected': after_video['connected'], 'actual_broker_paired': actual['paired'], 'profile': actual['profile'], 'sample': index + 1, 'local_preview_ms': (value['first_visible_window_uptime'] - began) * 1000, 'first_presented_video_ms': (value['first_presented_video_uptime'] - began) * 1000, 'constructor_to_preview_ms': (value['first_visible_window_uptime'] - value['constructor_uptime']) * 1000, 'load_average_1_5_15_min': os.getloadavg()})
                trace = root/f'launch-trace-{child.pid}.jsonl'
                if args.trace and trace.exists():
                    events = [json.loads(line) for line in trace.read_text().splitlines()]
                    rows[-1]['launch_trace_ms'] = {e['phase']: (e['uptime'] - began) * 1000 for e in events if e['uptime'] >= began}
            finally:
                owned, session_logs, inspection_error = {}, [], None
                forced_termination = False
                try:
                    owned = {pid: process_identity(pid) for pid in child_processes(child.pid)} if child.poll() is None else {}
                    for path in set((root/'Logs').glob('session-*.log')) - prior_logs:
                        if any(event.get('event') == 'supervisor_started' and event.get('parent') == child.pid for event in supervisor_events(path)):
                            session_logs.append(path)
                except Exception as error:
                    inspection_error = error
                finally:
                    try:
                        if child.poll() is None:
                            child.terminate()
                        try:
                            child.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            forced_termination = True
                            child.kill()
                            child.wait(timeout=5)
                    finally:
                        log.close()
                if inspection_error is not None:
                    raise RuntimeError('Benchmark child was reaped after cleanup inspection failed') from inspection_error
                cleanup_began = time.monotonic()
                deadline = cleanup_began + 20
                while True:
                    live = [pid for pid, identity in owned.items() if identity and process_identity(pid) == identity]
                    events = [supervisor_events(path) for path in session_logs]
                    failed = any(event.get('event') == 'supervisor_cleanup_failed' for group in events for event in group)
                    if failed:
                        raise RuntimeError('Exact benchmark supervisor reported resource cleanup failure')
                    stopped = bool(events) and all(any(event.get('event') == 'supervisor_stopped' for event in group) for group in events)
                    if not live and stopped:
                        break
                    if time.monotonic() >= deadline:
                        raise RuntimeError('Exact benchmark supervisor did not confirm bounded cleanup before the next sample')
                    time.sleep(.05)
                if rows and rows[-1].get('sample') == index + 1 and rows[-1].get('companion_connected') == connected:
                    rows[-1]['cleanup'] = {'seconds': time.monotonic() - cleanup_began, 'owned_process_identities_drained': len(owned), 'supervisor_logs_stopped_without_cleanup_failure': len(session_logs)}
                if forced_termination:
                    raise RuntimeError('Exact benchmark child exceeded SIGTERM reap; bounded SIGKILL and supervisor drain completed')
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
    connected_video = groups['connected']['first_presented_video_ms']['p95']
    disconnected_video = groups['disconnected']['first_presented_video_ms']['p95']
    video_delta = connected_video - disconnected_video
    video_ratio = connected_video / disconnected_video
    preview_passed = all(group['local_preview_ms']['p95'] <= 100 for group in groups.values())
    video_passed = video_delta <= 200 and video_ratio <= 1.1
    result = {'passed': preview_passed and video_passed, 'host_context': args.host_context, 'execution_passed': True, 'cold_preview_target_ms': 100, 'cold_preview_target_passed': preview_passed, 'video_connection_regression': {'p95_delta_ms': video_delta, 'p95_ratio': video_ratio, 'maximum_delta_ms': 200, 'maximum_ratio': 1.1, 'passed': video_passed}, 'ordering': f'interleaved ABBA connected/disconnected, {args.samples_per_cohort} per cohort', 'scope': 'Same installed executable --wrapper path; Balanced profile in both cohorts, paired saved trust with companion connected vs deliberately disconnected; no separate bundle identity or WindowServer paint/focus claim', 'sampling': '10 ms public NSWindow/accessibility observer; process spawn includes dyld; first video may contain Android system decorations before app content', 'rows': rows, 'groups': groups}
    (args.output/'results.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(groups), flush=True)

if __name__ == '__main__':
    main()
