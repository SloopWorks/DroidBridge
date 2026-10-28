#!/usr/bin/env python3
"""Actual installed Mach-O as an independent QA wrapper; public NSWindow close.
Test-only DYLD shim schedules performClose, production termination is unchanged.
"""
import argparse, json, os, pathlib, plistlib, shutil, subprocess, tempfile, time
p=argparse.ArgumentParser();p.add_argument('app',type=pathlib.Path);p.add_argument('--output',type=pathlib.Path,default=pathlib.Path('verification/review/wrapper'));args=p.parse_args()
root=pathlib.Path(__file__).resolve().parents[1];out=args.output;out.mkdir(parents=True,exist_ok=True);app=args.app.resolve();adb=app/'Contents/Resources/Runtime/bin/adb';logs=pathlib.Path.home()/'Library/Logs/DroidBridge'
def run(*cmd):return subprocess.check_output(list(map(str,cmd)),text=True,stderr=subprocess.STDOUT)
def android(*cmd):return run(adb,'-s','emulator-5580',*cmd)
shim=root/'.build/qa-wrapper-close.dylib'
subprocess.run(['clang','-dynamiclib','-fobjc-arc','-framework','AppKit',str(root/'scripts/verify-wrapper-close.m'),'-o',str(shim)],check=True)
baseline=android('forward','--list');display_count=android('shell','dumpsys','display').count('DisplayDeviceInfo{');existing=set(logs.glob('*.jsonl'))
with tempfile.TemporaryDirectory(prefix='droidbridge-wrapper-') as temp:
    wrapper=pathlib.Path(temp)/'QA Settings.app';contents=wrapper/'Contents';macos=contents/'MacOS';resources=contents/'Resources';macos.mkdir(parents=True);resources.mkdir()
    shutil.copy2(app/'Contents/MacOS/DroidBridge',macos/'DroidBridge')
    shutil.copytree(app/'Contents/Resources/Runtime',resources/'Runtime',symlinks=True)
    (resources/'launch.json').write_text(json.dumps({'package':'com.android.settings','name':'QA Settings','serial':'emulator-5580','backend':'native'}))
    with (contents/'Info.plist').open('wb') as f:plistlib.dump({'CFBundleIdentifier':'app.droidbridge.qa.wrapperclose','CFBundleName':'QA Settings','CFBundleExecutable':'DroidBridge','CFBundlePackageType':'APPL','LSMinimumSystemVersion':'26.0'},f)
    subprocess.run(['codesign','--force','--sign','-',str(wrapper)],check=True)
    subprocess.run(['codesign','--verify','--deep','--strict',str(wrapper)],check=True)
    marker=out.resolve()/'close-action.txt';marker.unlink(missing_ok=True)
    env=os.environ.copy();env['PATH']='/usr/bin:/bin';env['DYLD_INSERT_LIBRARIES']=str(shim);env['DROIDBRIDGE_QA_WRAPPER_CLOSE_RECEIPT']=str(marker)
    with (out/'host.log').open('w') as log:
        process=subprocess.Popen([str(macos/'DroidBridge')],env=env,stdout=log,stderr=log);started=time.monotonic()
        try:status=process.wait(timeout=25)
        finally:
            if process.poll() is None:process.kill();process.wait(timeout=5)
    assert status==0,f'wrapper exited {status}'
    assert marker.exists(),'public NSWindow performClose did not occur'
    session_logs=set(logs.glob('*.jsonl'))-existing
    events=[json.loads(line) for file in session_logs for line in file.read_text().splitlines() if line.startswith('{')]
    assert any(e.get('state')=='running' and e.get('package')=='com.android.settings' and e.get('device')=='emulator-5580' for e in events),'wrapper never decoded live Android frame'
    assert any(e.get('event')=='session_close' and e.get('details',{}).get('reason')=='window_close' for e in events),'native window close cause not recorded'
    assert any(e.get('event')=='session_stop_requested' and e.get('reason')=='window_close' for e in events),'backend stop caller not recorded'
    for file in session_logs:(out/file.name).write_text(file.read_text())
    assert android('forward','--list')==baseline,'wrapper leaked ADB forward'
    assert android('shell','dumpsys','display').count('DisplayDeviceInfo{')==display_count,'wrapper leaked virtual display'
    report={'passed':True,'exit_status':status,'elapsed_seconds':round(time.monotonic()-started,3),'window_close_action':marker.read_text(),'live_frame_before_close':True,'forward_display_cleanup':True,'host_binary_sha256':run('shasum','-a','256',app/'Contents/MacOS/DroidBridge').split()[0]}
    (out/'results.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
