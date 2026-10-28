#!/usr/bin/env python3
"""Exercise running-session parent death, child failure, and graceful AppKit termination.
Requires exclusive DroidBridge UI on the dedicated emulator, never emulator5554.
"""
import argparse, json, os, pathlib, re, signal, subprocess, tempfile, time
p=argparse.ArgumentParser(); p.add_argument('app',type=pathlib.Path); p.add_argument('--serial',default='emulator-5580'); p.add_argument('--output',type=pathlib.Path,default=pathlib.Path('verification/review/installed')); args=p.parse_args()
assert args.serial=='emulator-5580','only dedicated test emulator is authorized'
app=args.app.resolve(); exe=app/'Contents/MacOS/DroidBridge'; runtime=app/'Contents/Resources/Runtime'; adb=runtime/'bin/adb'; out=args.output; out.mkdir(parents=True,exist_ok=True)
def run(*command): return subprocess.check_output(list(map(str,command)),text=True,stderr=subprocess.STDOUT)
def android(*command): return run(adb,'-s',args.serial,*command)
def forwards(): return set(android('forward','--list').splitlines())
def reverses(): return set(android('reverse','--list').splitlines())
def displays(): return android('shell','dumpsys','display').count('DisplayDeviceInfo{')
def processes():
    rows={}
    for line in run('/bin/ps','-axo','pid,ppid,state,pcpu,rss,command').splitlines()[1:]:
        parts=line.strip().split(None,5)
        if len(parts)==6: rows[int(parts[0])]={'parent':int(parts[1]),'state':parts[2],'cpu_percent':float(parts[3]),'rss_kib':int(parts[4]),'command':parts[5]}
    return rows
assert not any(r['command'].startswith(str(exe)+' ') or r['command']==str(exe) for r in processes().values()),'close installed DroidBridge before QA'
assert android('shell','getprop','sys.boot_completed').strip()=='1'
logs=pathlib.Path.home()/'Library/Logs/DroidBridge'; results=[]
with tempfile.TemporaryDirectory(prefix='droidbridge-quit-') as temporary:
    temporary=pathlib.Path(temporary); source=temporary/'quit.swift'; quitter=temporary/'quit'
    source.write_text('import AppKit\nlet pid = Int32(CommandLine.arguments[1])!\nguard let app = NSRunningApplication(processIdentifier:pid), app.terminate() else { exit(1) }\n')
    subprocess.run(['swiftc',str(source),'-o',str(quitter)],check=True)
    for backend in ('native','scrcpy'):
        for mode in ('crash','quit','child-crash'):
            print(f'START installed {backend} {mode}',flush=True)
            before_forwards=forwards(); before_reverses=reverses(); before_displays=displays(); existing=set(logs.glob('*.jsonl'))
            env=os.environ.copy(); env['PATH']='/usr/bin:/bin'
            with (out/f'{backend}-{mode}-host.log').open('w') as host_log:
                process=subprocess.Popen([str(exe),'--launch','dev.droidbridge.testapp','--serial',args.serial,'--backend',backend,'--name','Installed QA'],env=env,stdout=host_log,stderr=host_log)
                owned=set(); session_log=None
                try:
                    deadline=time.monotonic()+30
                    while time.monotonic()<deadline:
                        assert process.poll() is None,'installed app exited before live session'
                        rows=processes(); parents={process.pid}
                        for _ in range(4): parents|={pid for pid,row in rows.items() if row['parent'] in parents}
                        owned|=parents-{process.pid}
                        for candidate in set(logs.glob('*.jsonl'))-existing:
                            records=[json.loads(line) for line in candidate.read_text().splitlines() if line.startswith('{')]
                            if any(r.get('state')=='running' and r.get('device')==args.serial and r.get('backend')==backend for r in records): session_log=candidate
                        if session_log is not None and displays()>before_displays: break
                        time.sleep(.2)
                    assert session_log is not None and displays()>before_displays,'no real live virtual display within30sec'
                    time.sleep(1)
                    owned_forwards=forwards()-before_forwards
                    owned_reverses=reverses()-before_reverses
                    resource_rows=processes()
                    resource_sample={str(pid):resource_rows[pid] for pid in owned|{process.pid} if pid in resource_rows}
                    started=time.monotonic()
                    if mode=='crash': process.kill()
                    elif mode=='child-crash':
                        raw=session_log.with_suffix('')
                        started_event=next(json.loads(line) for line in raw.read_text().splitlines() if '"event":"supervisor_started"' in line)
                        os.kill(started_event['child'],signal.SIGKILL)
                        state_deadline=time.monotonic()+12
                        while time.monotonic()<state_deadline:
                            states=[json.loads(line).get('state') for line in session_log.read_text().splitlines() if line.startswith('{')]
                            if 'failed' in states or 'stopped' in states: break
                            time.sleep(.1)
                        assert process.poll() is None,'child failure crashed host'
                        assert 'failed' in states or 'stopped' in states,'child failure not reflected in session state'
                    else: subprocess.run([str(quitter),str(process.pid)],check=True)
                    if mode!='child-crash': process.wait(timeout=25)
                    deadline=time.monotonic()+12
                    while time.monotonic()<deadline:
                        rows=processes(); survivors={pid for pid in owned if pid in rows and not rows[pid]['state'].startswith('Z')}
                        if not survivors and not owned_forwards.intersection(forwards()) and not owned_reverses.intersection(reverses()) and displays()==before_displays: break
                        time.sleep(.2)
                    assert not survivors,f'orphan owned processes {survivors}'
                    assert not owned_forwards.intersection(forwards()),'orphan owned ADB forward'
                    assert not owned_reverses.intersection(reverses()),'orphan owned ADB reverse'
                    assert displays()==before_displays,'orphan virtual display'
                    if mode=='child-crash':
                        assert process.poll() is None,'host died during failed session cleanup'
                        subprocess.run([str(quitter),str(process.pid)],check=True)
                        process.wait(timeout=25)
                    (out/f'{backend}-{mode}-session.jsonl').write_text(session_log.read_text())
                    raw=session_log.with_suffix('')
                    if raw.exists(): (out/f'{backend}-{mode}-server.log').write_text(raw.read_text())
                    results.append({'backend':backend,'mode':mode,'passed':True,'host_pid':process.pid,'owned_pids':sorted(owned),'active_resource_sample':resource_sample,'owned_forwards':sorted(owned_forwards),'owned_reverses':sorted(owned_reverses),'elapsed_seconds':round(time.monotonic()-started,3),'before_display_count':before_displays,'after_display_count':displays()})
                    (out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
                    print(f'PASS installed {backend} {mode}: cleanup {results[-1]["elapsed_seconds"]}s',flush=True)
                finally:
                    if process.poll() is None: process.kill(); process.wait(timeout=5)
print(json.dumps([{key:r[key] for key in ('backend','mode','passed','elapsed_seconds')} for r in results],indent=2))
