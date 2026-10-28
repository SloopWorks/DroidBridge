#!/usr/bin/env python3
"""Kill exact installed host after its icon push, then prove successor recovery.
The test-only ADB adapter delays returning a successful real icon push. All other
commands use the actual bundled ADB. No shared server or unrelated device is killed.
"""
import argparse, atexit, hashlib, json, os, pathlib, re, signal, subprocess, sys, tempfile, time
p=argparse.ArgumentParser(); p.add_argument('app',type=pathlib.Path); p.add_argument('--output',type=pathlib.Path,default=pathlib.Path('verification/launcher-fix/qa/icon-crash-recovery')); args=p.parse_args()
app=args.app.resolve(); exe=app/'Contents/MacOS/DroidBridge'; adb=app/'Contents/Resources/Runtime/bin/adb'; out=args.output.resolve(); out.mkdir(parents=True,exist_ok=True)
serial='emulator-5580'; receipts=pathlib.Path.home()/'Library/Application Support/DroidBridge/icon-receipts'
intent=pathlib.Path.home()/'Library/Application Support/DroidBridge/sessions.json'; prior=intent.read_bytes() if intent.exists() else None
atexit.register(lambda: intent.write_bytes(prior) if prior is not None else intent.unlink(missing_ok=True))
def run(*cmd): return subprocess.check_output(list(map(str,cmd)),text=True,stderr=subprocess.STDOUT)
def android(*cmd): return run(adb,'-s',serial,*cmd)
def icon_files(): return set(android('shell','find','/data/local/tmp','-maxdepth','1','-name','droidbridge-icon-*').splitlines())
def wait_for(condition,timeout=30):
    until=time.monotonic()+timeout
    while time.monotonic()<until:
        value=condition()
        if value:return value
        time.sleep(.1)
    raise AssertionError('Timed out at exact icon staging/recovery boundary')
baseline=icon_files(); original_receipts=set(receipts.glob('*.json'))
assert android('shell','getprop','sys.boot_completed').strip()=='1'
with tempfile.TemporaryDirectory(prefix='droidbridge-icon-crash-') as temp:
    temp=pathlib.Path(temp); marker=temp/'pushed.json'; adapter=temp/'adb'; quitter=temp/'quit'; source=temp/'quit.swift'
    adapter.write_text('#!'+sys.executable+'\n'+'''import json, os, pathlib, re, subprocess, sys, time
args=sys.argv[1:]
real=os.environ['DROIDBRIDGE_QA_REAL_ADB']
is_icon_push=args[:3]==['-s','emulator-5580','push'] and re.fullmatch(r'/data/local/tmp/droidbridge-icon-[a-f0-9-]+\\.jar',args[-1])
if is_icon_push:
    identity=args[-1].split('droidbridge-icon-')[-1][:-4]
    receipt=pathlib.Path.home()/'Library/Application Support/DroidBridge/icon-receipts'/(identity+'.json')
    assert json.loads(receipt.read_text())['ownerPID']==os.getppid(), 'No durable owned receipt before remote write'
status=subprocess.call([real]+args)
if status==0 and is_icon_push:
    marker=pathlib.Path(os.environ['DROIDBRIDGE_QA_ICON_MARKER'])
    pending=marker.with_suffix('.'+str(os.getpid())+'.pending')
    pending.write_text(json.dumps({'ownerPID':os.getppid(),'adapterPID':os.getpid(),'remoteJar':args[-1],'receiptPresentBeforePush':True}))
    try: os.link(pending,marker)
    except FileExistsError: pass
    pending.unlink()
    time.sleep(2)
sys.exit(status)
'''); adapter.chmod(0o755)
    source.write_text('import AppKit\nlet p=Int32(CommandLine.arguments[1])!\nguard let a=NSRunningApplication(processIdentifier:p),a.terminate() else { exit(1) }\n')
    subprocess.run(['swiftc',str(source),'-o',str(quitter)],check=True)
    env=os.environ.copy(); env.update(PATH='/usr/bin:/bin',DROIDBRIDGE_ADB=str(adapter),DROIDBRIDGE_QA_REAL_ADB=str(adb),DROIDBRIDGE_QA_ICON_MARKER=str(marker))
    owner=None; successor=None
    try:
        with (out/'owner.log').open('w') as log:
            owner=subprocess.Popen([str(exe),'--serial',serial],env=env,stdout=log,stderr=log)
            wait_for(marker.exists)
            staged=json.loads(marker.read_text()); assert staged['ownerPID']==owner.pid and staged['receiptPresentBeforePush'],staged
            jar=staged['remoteJar']; identity=re.fullmatch(r'/data/local/tmp/droidbridge-icon-([a-f0-9-]+)\.jar',jar)[1]; png=jar[:-4]+'.png'
            assert subprocess.call([str(adb),'-s',serial,'shell','test','-f',jar])==0,'marker lacked real pushed JAR'
            def owned_receipt():
                for path in receipts.glob('*.json'):
                    try:
                        data=json.loads(path.read_text())
                        if data.get('ownerPID')==owner.pid and identity in path.read_text().lower(): return path
                    except (OSError,ValueError):pass
                return None
            receipt=wait_for(owned_receipt,timeout=5)
            (out/'staged-receipt.json').write_bytes(receipt.read_bytes())
            owner.kill(); owner.wait(timeout=5)
        assert receipt.exists(),'receipt disappeared on owner death before recovery'
        assert jar in icon_files(),'staged JAR disappeared before successor could recover'
        time.sleep(2.2)  # Let the exact already-admitted test adapter retire; no late writer remains.
        clean_env=os.environ.copy(); clean_env['PATH']='/usr/bin:/bin'; clean_env.pop('DROIDBRIDGE_ADB',None)
        with (out/'successor.log').open('w') as log:
            successor=subprocess.Popen([str(exe),'--serial',serial],env=clean_env,stdout=log,stderr=log)
            wait_for(lambda: not receipt.exists() and not ({jar,png}&icon_files()))
            assert successor.poll() is None,'successor died during receipt recovery'
            subprocess.run([str(quitter),str(successor.pid)],check=True); successor.wait(timeout=25)
        # Every receipt admitted by either exact test owner must be gone after
        # graceful successor shutdown; historical unrelated files are preserved.
        added_files=icon_files()-baseline
        assert not added_files,sorted(added_files)
        new_receipts=set(receipts.glob('*.json'))-original_receipts
        assert not new_receipts,sorted(map(str,new_receipts))
        report={'passed':True,'host_binary_sha256':hashlib.sha256(exe.read_bytes()).hexdigest(),'owner_exit_status':owner.returncode,'staged_remote_jar':jar,'staged_receipt':str(receipt),'successor_exit_status':successor.returncode,'exact_jar_and_png_absent':True,'new_receipts_after_shutdown':[],'new_remote_icon_files_after_shutdown':[],'historical_baseline_count':len(baseline)}
        (out/'results.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
    finally:
        for process in (owner,successor):
            if process and process.poll() is None:
                subprocess.run([str(quitter),str(process.pid)],check=False)
                try:process.wait(timeout=25)
                except subprocess.TimeoutExpired:process.kill();process.wait(timeout=5)
