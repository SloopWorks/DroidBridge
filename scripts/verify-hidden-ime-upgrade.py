#!/usr/bin/env python3
"""Verify the installed GUI updates accepted copied wrappers before IME QA.

Requires exclusive Mac preferences/session and emulator-5580 ownership. Runs the
actual maintenance controller; never edits the managed catalog or launch pins.
"""
import hashlib,json,pathlib,plistlib,subprocess,time,urllib.parse
repo=pathlib.Path(__file__).resolve().parents[1]
app=pathlib.Path.home()/'Applications/DroidBridge.app'
out=repo/'verification/hidden-ime/upgrade';out.mkdir(parents=True,exist_ok=True)
support=pathlib.Path.home()/'Library/Application Support/DroidBridge'
catalog=support/'ManagedApps.noindex/catalog.json'
state=support/'sessions.json';prior=(state.read_bytes(),state.stat().st_mode&0o777) if state.exists() else None
metadata=plistlib.loads((app/'Contents/Info.plist').read_bytes())
def run(*args,timeout=45):return subprocess.check_output(list(map(str,args)),text=True,stderr=subprocess.STDOUT,timeout=timeout)
def records():return [r for r in json.loads(catalog.read_text())['records'].values() if r['deviceSerial']=='emulator-5580']
before=records();assert before,'This check requires accepted dedicated-emulator wrappers'
report={'passed':False,'installed_sha256':hashlib.sha256((app/'Contents/MacOS/DroidBridge').read_bytes()).hexdigest(),'version':metadata['CFBundleShortVersionString'],'build':metadata['CFBundleVersion'],'before':[{'package':r['packageName'],'version':r.get('sourceVersion'),'build':r.get('sourceBuild')} for r in before]}
stop_source=repo/'.build/hidden-ime-stop.swift';stop=repo/'.build/hidden-ime-stop'
stop_source.write_text('import AppKit\nlet pid=Int32(CommandLine.arguments[1])!\nguard let app=NSRunningApplication(processIdentifier:pid),app.terminate() else {exit(1)}\n')
run('swiftc',stop_source,'-o',stop)
child=None
try:
 with (out/'host.log').open('w') as handle:
  child=subprocess.Popen([str(app/'Contents/MacOS/DroidBridge'),'--serial','emulator-5580'],stdout=handle,stderr=handle)
  deadline=time.monotonic()+180
  while time.monotonic()<deadline:
   assert child.poll() is None,'Main app exited during managed maintenance'
   current=records()
   if len(current)==len(before) and all(r.get('sourceVersion')==report['version'] and r.get('sourceBuild')==report['build'] for r in current):break
   time.sleep(.3)
  else:raise AssertionError('Accepted copied wrappers did not update to installed release')
  run(stop,child.pid);child.wait(timeout=45);assert child.returncode==0
 probe=next(r for r in records() if r['packageName']=='dev.droidbridge.testapp')
 # Derive the accepted active URL from its record, never discover another
 # device's app by label or mutate catalog paths to make it launchable.
 location=urllib.parse.urlparse(probe['activeBundleURL'])
 assert location.scheme=='file' and location.netloc in ('','localhost')
 wrapper=pathlib.Path(urllib.parse.unquote(location.path)).resolve()
 assert wrapper.is_relative_to(pathlib.Path.home()/'Applications/DroidBridge Apps/Devices')
 run('codesign','--verify','--deep','--strict',wrapper)
 binary=wrapper/'Contents/MacOS/DroidBridge'
 assert 'display_ime_policy=hide' in run('strings',binary)
 assert '--display-ime-policy=hide' in run('strings',binary)
 report.update(updated=len(records()),wrapper_path=str(wrapper),wrapper_sha256=hashlib.sha256(binary.read_bytes()).hexdigest())
 run('python3',repo/'scripts/verify-hidden-ime-native.py','--app',wrapper,'--serial','emulator-5580','--policy','hide','--output',out/'managed-wrapper',timeout=240)
 result=json.loads((out/'managed-wrapper/result.json').read_text());assert result['passed']
 report.update(passed=True,managed_wrapper_result='managed-wrapper/result.json')
finally:
 if child and child.poll() is None:
  try:run(stop,child.pid);child.wait(timeout=45)
  except Exception:child.terminate();child.wait(timeout=15)
 if prior is None:state.unlink(missing_ok=True)
 else:state.write_bytes(prior[0]);state.chmod(prior[1])
 (out/'result.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
