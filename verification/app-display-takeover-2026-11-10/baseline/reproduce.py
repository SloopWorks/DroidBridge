import hashlib, json, os, pathlib, plistlib, re, shutil, subprocess, tempfile, time
app = pathlib.Path.home()/'Applications/DroidBridge.app'
out = pathlib.Path('verification/app-display-takeover-2026-11-10/baseline').resolve(); out.mkdir(parents=True,exist_ok=True)
adb = pathlib.Path.home()/'Library/Android/sdk/platform-tools/adb'
serial = 'emulator-5580'; package = 'dev.droidbridge.testapp7'
def run(*args, **kw):
    return subprocess.run([str(a) for a in args],capture_output=True,text=True,timeout=15,check=True,**kw).stdout

def android(*args):
    return run(adb,'-s',serial,*args)

assert android('emu','avd','name').splitlines()[0] == 'DroidBridge_API35'
assert android('shell','getprop','sys.boot_completed').strip() == '1'
android('shell','input','-d','0','keyevent','224'); android('shell','wm','dismiss-keyguard')
with tempfile.TemporaryDirectory(prefix='droidbridge-takeover-',dir='/private/tmp') as base:
    base = pathlib.Path(base)
    (base/'quit.swift').write_text('import AppKit\nif !NSRunningApplication(processIdentifier:Int32(CommandLine.arguments[1])!)!.terminate() {exit(1)}\n')
    run('swiftc',base/'quit.swift','-o',base/'quit')
    for backend in ('native','scrcpy'):
        d=out/backend;d.mkdir(exist_ok=True)
        root=base/backend;root.mkdir(mode=0o700)
        (root/'preferences.json').write_text(json.dumps({'bulkWrapperOnboardingEnabled':False,'deviceAudioRoutes':{serial:'phone'}}))
        cmd=[app/'Contents/MacOS/DroidBridge','--companion-qa-root',root,'--serial',serial,'--launch',package,'--name','Display Move Probe','--backend',backend,'--companion-launch-trace']
        (d/'command.json').write_text(json.dumps([str(a) for a in cmd],indent=2))
        with (d/'host.log').open('w') as f:
            proc=subprocess.Popen(cmd,stdout=f,stderr=f)
            try:
                deadline=time.monotonic()+40
                while time.monotonic()<deadline:
                    if proc.poll() is not None: raise RuntimeError('Host exited')
                    logs=list((root/'Logs').glob('session-*.log.jsonl'))
                    if logs and '"state":"running"' in logs[0].read_text() and (backend=='scrcpy' or 'native_content_presented' in logs[0].read_text()):break
                    time.sleep(.1)
                else: raise RuntimeError('No video')
                txt=logs[0].with_suffix('').read_text(); match=re.search(r'Starting app .*\['+re.escape(package)+r'\] on display (\d+)',txt)
                display=int(match[1]);assert display>0
                def snapshot(label):
                    # Collect only dedicated AVD activity data; use full hierarchy to distinguish the displays.
                    activities=android('shell','dumpsys','activity','activities');(d/(label+'.txt')).write_text(activities)
                    current='?'
                    for line in activities.splitlines():
                        m=re.match(r'Display #(\d+)',line)
                        if m:current=m[1]
                        if 'Hist ' in line and package in line:print(backend,label,'display',current,line.strip(),flush=True)
                snapshot('mac-first')
                generic=android('shell','am','start','-W','-a','android.intent.action.MAIN','-c','android.intent.category.LAUNCHER','-n',package+'/.MainActivity')
                (d/'adb-default-launch.txt').write_text(generic); time.sleep(1); snapshot('adb-default')
                forced=android('shell','am','start','-W','--display','0','-a','android.intent.action.MAIN','-c','android.intent.category.LAUNCHER','-n',package+'/.MainActivity')
                (d/'adb-display-0-launch.txt').write_text(forced);time.sleep(5);snapshot('adb-display-0')
                print(backend,'host_alive',proc.poll() is None,'running_last', [json.loads(x).get('state') for x in logs[0].read_text().splitlines() if '"state"' in x][-1], 'adb_state',android('get-state').strip(),flush=True)
                restored=android('shell','am','start','-W','--display',str(display),'-a','android.intent.action.MAIN','-c','android.intent.category.LAUNCHER','-n',package+'/.MainActivity')
                (d/'adb-return-launch.txt').write_text(restored);time.sleep(1);snapshot('adb-return')
            finally:
                if proc.poll() is None:
                    run(base/'quit',proc.pid)
                    try:proc.wait(25)
                    except subprocess.TimeoutExpired:proc.kill();proc.wait(5)
                for log in (root/'Logs').glob('*'):
                    if log.is_file(): shutil.copy2(log,d/log.name)
                suffix=hashlib.sha256(str(root).encode()).hexdigest()[:12];label=f'dev.droidbridge.companion.broker.qa.{suffix}'
                plist=pathlib.Path.home()/'Library/LaunchAgents'/f'{label}.plist'
                if plist.exists():
                    data=plistlib.loads(plist.read_bytes());assert data['Label']==label and data['ProgramArguments'][0].startswith(str(root)+'/')
                    subprocess.run(['/bin/launchctl','bootout',f'gui/{os.getuid()}/{label}'],capture_output=True,timeout=10);plist.unlink()
