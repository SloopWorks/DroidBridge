#!/usr/bin/env python3
"""Exact installed clean-name wrappers: real Spotlight, decoded frame and cleanup.
Requires exclusive dedicated emulator-5580 ownership; preserves emulator-5554.
"""
import hashlib, json, pathlib, subprocess, time
from urllib.parse import unquote, urlparse

home=pathlib.Path.home(); app=home/'Applications/DroidBridge.app'
root=home/'Library/Application Support/DroidBridge/ManagedApps.noindex'
logs=home/'Library/Logs/DroidBridge'; out=pathlib.Path('verification/clean-app-names'); out.mkdir(parents=True,exist_ok=True)
adb=str(app/'Contents/Resources/Runtime/bin/adb')
def run(*args):return subprocess.check_output(args,text=True,stderr=subprocess.STDOUT,timeout=20)
def device(*args):return run(adb,'-s','emulator-5580',*args)
def wait(test,seconds=45):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        result=test()
        if result:return result
        time.sleep(.2)
    raise AssertionError('Bounded condition timed out')
def rows():return list(json.loads((root/'catalog.json').read_text())['records'].values())
def public(r):return pathlib.Path(unquote(urlparse(r['activeBundleURL']).path))
wait(lambda:rows() and all(r['location']=='active' for r in rows()),75)
records=rows(); expected={str(public(r)) for r in records}
assert all(r['deviceSerial']=='emulator-5580' for r in records)
query=' || '.join("kMDItemCFBundleIdentifier == '"+r['bundleIdentifier']+"'" for r in records)
for r in records:run('/usr/bin/mdimport',str(public(r)))
wait(lambda:set(run('/usr/bin/mdfind',query).splitlines())==expected)
metadata={r['packageName']:run('/usr/bin/mdls','-raw','-name','kMDItemDisplayName',str(public(r))) for r in records}
assert all('-'+hashlib.sha256(r['packageName'].encode()).hexdigest()[:16] not in metadata[r['packageName']] for r in records)
record=next(r for r in records if r['packageName']=='com.android.settings')
def resources():return {'displays':device('shell','dumpsys','display').count('DisplayDeviceInfo{'),'forwards':[l for l in device('forward','--list').splitlines() if l.startswith('emulator-5580 ')],'reverse':device('reverse','--list')}
baseline=resources(); prior=set(logs.glob('*.log.jsonl'))
def events():return [json.loads(line) for f in set(logs.glob('*.log.jsonl'))-prior for line in f.read_text().splitlines() if line.startswith('{')]
handle=(out/'clean-settings-host.log').open('w');child=subprocess.Popen([str(public(record)/'Contents/MacOS/DroidBridge')],stdout=handle,stderr=subprocess.STDOUT)
try:
    wait(lambda:any(e.get('state')=='running' for e in events()))
    wait(lambda:any(e.get('event')=='native_window_presented' for e in events()))
    facts=events()
    assert resources()['displays']==baseline['displays']+1
    run('/usr/bin/swift','-e','import AppKit; if let app = NSRunningApplication(processIdentifier: Int32(CommandLine.arguments[1])!) { _ = app.terminate() }',str(child.pid))
    child.wait(timeout=25);assert child.returncode==0
    wait(lambda:resources()==baseline)
    for file in set(logs.glob('*.log.jsonl'))-prior:(out/file.name).write_bytes(file.read_bytes())
    report={'passed':True,'installed_main_sha256':hashlib.sha256((app/'Contents/MacOS/DroidBridge').read_bytes()).hexdigest(),'spotlight_exact_paths':sorted(expected),'spotlight_display_names':metadata,'wrapper_filename':record['bundleFilename'],'native_frame_events':[e for e in facts if e.get('event')=='native_window_presented'],'resource_baseline':baseline,'resource_after':resources(),'main_panel_and_physical_focus_unverified':True}
    (out/'launch-result.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
finally:
    if child.poll() is None:child.terminate();child.wait(timeout=20)
    handle.close()
