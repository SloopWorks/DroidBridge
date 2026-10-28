#!/usr/bin/env python3
"""Actual dedicated-emulator shutdown/reboot and installed-app reconnection.
Never kills an ADB server or accesses emulator5554. Ends with fresh emulator live.
"""
import argparse, json, os, pathlib, subprocess, tempfile, time
p=argparse.ArgumentParser();p.add_argument('app',type=pathlib.Path);p.add_argument('--output',type=pathlib.Path,default=pathlib.Path('verification/review/reconnect'));args=p.parse_args()
app=args.app.resolve();exe=app/'Contents/MacOS/DroidBridge';adb=app/'Contents/Resources/Runtime/bin/adb';out=args.output;out.mkdir(parents=True,exist_ok=True)
emulator=pathlib.Path.home()/'Library/Android/sdk/emulator/emulator';serial='emulator-5580';logs=pathlib.Path.home()/'Library/Logs/DroidBridge';results=[]
def android(*cmd): return subprocess.check_output([str(adb),'-s',serial,*cmd],text=True,stderr=subprocess.STDOUT,timeout=10)
def connected():
    try:return android('get-state').strip()=='device'
    except (subprocess.CalledProcessError,subprocess.TimeoutExpired):return False
def running(existing,backend):
    for file in set(logs.glob('*.jsonl'))-existing:
        records=[json.loads(line) for line in file.read_text().splitlines() if line.startswith('{')]
        if any(r.get('state')=='running' and r.get('device')==serial and r.get('backend')==backend for r in records):return file
    return None
with tempfile.TemporaryDirectory(prefix='droidbridge-reconnect-') as temp:
    temp=pathlib.Path(temp);source=temp/'quit.swift';quitter=temp/'quit'
    source.write_text('import AppKit\nlet app=NSRunningApplication(processIdentifier:Int32(CommandLine.arguments[1])!)!\nif !app.terminate() { exit(1) }\n')
    subprocess.run(['swiftc',str(source),'-o',str(quitter)],check=True)
    for backend in ('native','scrcpy'):
        print(f'START actual emulator shutdown/reconnect {backend}',flush=True)
        assert connected(),'dedicated emulator must be initially running'
        previous=set(logs.glob('*.jsonl'));env=os.environ.copy();env['PATH']='/usr/bin:/bin'
        with (out/f'{backend}-host.log').open('w') as hostlog:
            host=subprocess.Popen([str(exe),'--launch','dev.droidbridge.testapp','--serial',serial,'--backend',backend,'--name','Reconnect QA'],env=env,stdout=hostlog,stderr=hostlog)
            try:
                deadline=time.monotonic()+30;first=None
                while time.monotonic()<deadline:
                    assert host.poll() is None,'host exited before initial session'
                    first=running(previous,backend)
                    if first is not None and android('shell','dumpsys','display').count('DisplayDeviceInfo{')>1:break
                    time.sleep(.2)
                assert first is not None,'initial session did not run'
                android('emu','kill')
                deadline=time.monotonic()+10
                while connected() and time.monotonic()<deadline:time.sleep(.2)
                assert not connected(),'emulator did not disconnect'
                print(f'{backend}: emulator absent; checking host survival',flush=True)
                time.sleep(6) # exceeds four-second discovery polling cadence
                assert host.poll() is None,'host crashed while emulator absent'
                before_restore=set(logs.glob('*.jsonl'))
                emulatorlog=(out/f'{backend}-emulator.log').open('w')
                boot=subprocess.Popen([str(emulator),'-avd','DroidBridge_API35','-port','5580','-no-window','-no-audio','-no-snapshot','-gpu','auto'],stdout=emulatorlog,stderr=emulatorlog,start_new_session=True)
                deadline=time.monotonic()+90
                while time.monotonic()<deadline:
                    assert boot.poll() is None,'dedicated AVD failed to boot'
                    try:
                        if android('shell','getprop','sys.boot_completed').strip()=='1':break
                    except (subprocess.CalledProcessError,subprocess.TimeoutExpired):pass
                    time.sleep(.5)
                assert android('shell','getprop','sys.boot_completed').strip()=='1','boot timed out'
                deadline=time.monotonic()+35;restored=None
                while time.monotonic()<deadline:
                    assert host.poll() is None,'host crashed during reconnection'
                    restored=running(before_restore,backend)
                    if restored is not None:break
                    time.sleep(.2)
                if restored is None:
                    for file in set(logs.glob('*.jsonl'))-previous:(out/('failed-'+backend+'-'+file.name)).write_text(file.read_text())
                assert restored is not None,'automatic session restoration did not produce successor running session'
                print(f'PASS {backend}: same host PID {host.pid} automatically restored successor {restored.name}',flush=True)
                first_events=first.read_text();restored_events=restored.read_text()
                (out/f'{backend}-original.jsonl').write_text(first_events);(out/f'{backend}-restored.jsonl').write_text(restored_events)
                subprocess.run([str(quitter),str(host.pid)],check=True);host.wait(timeout=25)
                results.append({'backend':backend,'passed':True,'same_host_pid':host.pid,'original_session':first.name,'restored_session':restored.name,'new_emulator_pid':boot.pid,'host_survived_disconnect':True,'automatic_successor_session':True})
                (out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
            finally:
                if host.poll() is None:host.kill();host.wait(timeout=5)
print(json.dumps(results,indent=2))
