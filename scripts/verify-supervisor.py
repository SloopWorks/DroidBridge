#!/usr/bin/env python3
"""Actual child crash/signal tests; uses no Android device or shared daemon."""
import json, os, pathlib, signal, subprocess, sys, tempfile, time
root = pathlib.Path(__file__).resolve().parents[1]
helper = root / '.build/debug/DroidBridgeSupervisor'
if not helper.is_file():
    subprocess.run(['swift', 'build', '--product', 'DroidBridgeSupervisor'], cwd=root, check=True)
out = root / 'verification/supervisor'
out.mkdir(parents=True, exist_ok=True)
results = []
for mode in ('parent-crash', 'supervisor-terminate'):
    with tempfile.TemporaryDirectory(prefix='droidbridge-supervisor-') as temp:
        temp = pathlib.Path(temp)
        calls = temp / 'cleanup.jsonl'
        fake = temp / 'adb'
        fake.write_text('#!' + sys.executable + '\nimport json,sys\nwith open(' + repr(str(calls)) + ',"a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")\n')
        fake.chmod(0o755)
        log = temp / 'supervisor.log'
        code = '''import os,subprocess,sys,time
log=open(sys.argv[2],"w")
args=[sys.argv[1],"--parent",str(os.getpid()),"--adb",sys.argv[3],"--serial","emulator-test","--forward","tcp:12345","--remote","/data/local/tmp/owned.jar","--","/bin/sleep","60"]
p=subprocess.Popen(args,stdout=log,stderr=log)
print(p.pid,flush=True)
time.sleep(60)
'''
        parent = subprocess.Popen([sys.executable, '-c', code, str(helper), str(log), str(fake)], stdout=subprocess.PIPE, text=True)
        supervisor = int(parent.stdout.readline().strip())
        child = None
        try:
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                text = log.read_text() if log.exists() else ''
                first = next((json.loads(line) for line in text.splitlines() if 'supervisor_started' in line), None)
                if first:
                    child = first['child']; break
                time.sleep(.05)
            assert child is not None, 'supervisor failed to launch real child'
            started = time.monotonic()
            os.kill(parent.pid if mode == 'parent-crash' else supervisor, signal.SIGKILL if mode == 'parent-crash' else signal.SIGTERM)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and 'supervisor_stopped' not in log.read_text(): time.sleep(.05)
            assert 'supervisor_stopped' in log.read_text(), 'supervisor failed bounded teardown'
            try:
                os.kill(child, 0)
                raise AssertionError('owned child still exists')
            except ProcessLookupError:
                pass
            cleanup = [json.loads(line) for line in calls.read_text().splitlines()]
            assert cleanup == [['-s', 'emulator-test', 'forward', '--remove', 'tcp:12345'], ['-s', 'emulator-test', 'shell', 'rm', '-f', '/data/local/tmp/owned.jar']]
            results.append({'test': mode, 'passed': True, 'cleanup': cleanup, 'elapsed_seconds': round(time.monotonic()-started, 3)})
            (out / (mode + '.log')).write_text(log.read_text())
        finally:
            if parent.poll() is None: parent.kill()
            parent.wait(timeout=2)
            if 'supervisor_stopped' not in log.read_text():
                try: os.kill(supervisor, signal.SIGTERM)
                except ProcessLookupError: pass
# A GUI may die before the helper gets its first CPU slice. Cleanup still owns
# resources already allocated before spawn; no application child may be launched.
with tempfile.TemporaryDirectory(prefix='droidbridge-supervisor-late-') as temp:
    temp = pathlib.Path(temp)
    calls = temp / 'cleanup.jsonl'
    fake = temp / 'adb'
    fake.write_text('#!' + sys.executable + '\nimport json,sys\nwith open(' + repr(str(calls)) + ',"a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")\n')
    fake.chmod(0o755)
    result = subprocess.run([str(helper), '--parent', '2147483647', '--adb', str(fake), '--serial', 'emulator-test', '--forward', 'tcp:45678', '--remote', '/data/local/tmp/late.jar', '--', '/bin/sleep', '60'], capture_output=True, text=True, timeout=5)
    assert result.returncode == 75
    assert 'supervisor_started' not in result.stderr
    cleanup = [json.loads(line) for line in calls.read_text().splitlines()]
    assert len(cleanup) == 2 and cleanup[0][-1] == 'tcp:45678' and cleanup[1][-1] == '/data/local/tmp/late.jar'
    results.append({'test': 'parent-gone-before-helper-start', 'passed': True, 'cleanup': cleanup})
(out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
print(json.dumps(results, indent=2))
