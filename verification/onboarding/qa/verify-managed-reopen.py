#!/usr/bin/env python3
"""Final managed Mach-O: denied flagoff -> public delegate Reopen -> native frame.
Only the owned availability job is briefly SIGSTOPed to retain its current public
path for a denied launch. It is always resumed and exact preferences restored.
"""
import hashlib,json,os,pathlib,plistlib,re,signal,subprocess,time,tempfile,shutil
root=pathlib.Path.cwd();out=root/'verification/onboarding/qa/managed-reopen';out.mkdir(parents=True,exist_ok=True)
support=pathlib.Path.home()/'Library/Application Support/DroidBridge';pref=support/'preferences.json';catalog=support/'ManagedApps.noindex/catalog.json';logs=pathlib.Path.home()/'Library/Logs/DroidBridge';oldlogs=set(logs.glob('*.jsonl'));prior=pref.read_bytes() if pref.exists() else None
service=f'gui/{os.getuid()}/app.droidbridge.availability';text=subprocess.check_output(['/bin/launchctl','print',service],text=True);helper=int(re.search(r'\n\s*pid = (\d+)',text).group(1));command=subprocess.check_output(['/bin/ps','-p',str(helper),'-o','command='],text=True);assert 'DroidBridge' in command and 'DroidBridgeAvailability' in command
candidates=[r for r in json.loads(catalog.read_text())['records'].values() if r['deviceSerial']=='emulator-5580' and r['backend']=='native' and r['location']=='active'];record=sorted(candidates,key=lambda r:r['packageName']!='com.android.settings')[0]
from urllib.parse import urlparse,unquote
bundle=pathlib.Path(unquote(urlparse(record['activeBundleURL']).path));exe=bundle/'Contents/MacOS/DroidBridge';host=pathlib.Path.home()/'Applications/DroidBridge.app/Contents/MacOS/DroidBridge';state=support/('sessions-'+record['bundleIdentifier']+'.json');oldstate=state.read_bytes() if state.exists() else None
subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(bundle)],check=True)
normalized={}
with tempfile.TemporaryDirectory(prefix='qa-reopen-code-') as temp:
 for name,source in [('installed',host),('managed',exe)]:
  copy=pathlib.Path(temp)/name;shutil.copy2(source,copy);subprocess.run(['/usr/bin/codesign','--remove-signature',str(copy)],check=True);normalized[name]=hashlib.sha256(copy.read_bytes()).hexdigest()
 assert normalized['installed']==normalized['managed'],normalized
shim=root/'.build/qa-reopen-actions.dylib';subprocess.run(['clang','-dynamiclib','-fobjc-arc','-framework','AppKit',str(root/'verification/onboarding/qa/reopen-actions.m'),'-o',str(shim)],check=True)
for path in out.glob('*.trigger'):path.unlink()
for path in out.glob('*.json'):path.unlink()
def writepref(enabled):
 data=json.loads(prior) if prior else {};data['bulkWrapperOnboardingEnabled']=enabled;temp=pref.with_suffix('.qa-tmp');temp.write_text(json.dumps(data));os.replace(temp,pref)
def wait(condition,seconds=40):
 end=time.monotonic()+seconds
 while time.monotonic()<end:
  value=condition()
  if value:return value
  if process.poll() is not None:raise AssertionError(('Host exited',process.returncode))
  time.sleep(.1)
 raise AssertionError('Bounded condition did not complete')
def events():return [json.loads(l) for f in set(logs.glob('*.jsonl'))-oldlogs for l in f.read_text().splitlines() if l.startswith('{')]
adb=pathlib.Path.home()/'Applications/DroidBridge.app/Contents/Resources/Runtime/bin/adb'
def resources():
 forwards=subprocess.check_output([str(adb),'-s','emulator-5580','forward','--list'],text=True)
 reverse=subprocess.check_output([str(adb),'-s','emulator-5580','reverse','--list'],text=True)
 displays=subprocess.check_output([str(adb),'-s','emulator-5580','shell','dumpsys','display'],text=True)
 return {'forwards':sorted(l for l in forwards.splitlines() if l.startswith('emulator-5580 ')),'reverse':sorted(reverse.splitlines()),'display_count':displays.count('DisplayDeviceInfo{')}
baseline=resources()
process=None;paused=False
try:
 os.kill(helper,signal.SIGSTOP);paused=True;writepref(False)
 env=os.environ.copy();env.update(DYLD_INSERT_LIBRARIES=str(shim),DROIDBRIDGE_QA_REOPEN_ROOT=str(out))
 with (out/'host.log').open('w') as log:
  process=subprocess.Popen([str(exe)],env=env,stdout=log,stderr=log)
  wait(lambda:(out/'denied.json').exists());assert not any(e.get('state')=='starting' for e in events()),'Flagoff wrapper launched Android'
  writepref(True);os.kill(helper,signal.SIGCONT);paused=False;(out/'first.trigger').touch()
  wait(lambda:any(e.get('state')=='running' for e in events()))
  (out/'second.trigger').touch();process.wait(timeout=20)
 assert process.returncode==0 and (out/'finished.json').exists()
 after=resources()
 deadline=time.monotonic()+10
 while after!=baseline and time.monotonic()<deadline:time.sleep(.1);after=resources()
 assert after==baseline,(baseline,after)
 recorded=events();ids={e['session'] for e in recorded if e.get('state')=='starting'};assert len(ids)==1,ids
 presented=[e for e in recorded if e.get('event')=='native_window_presented'];assert any(e.get('details',{}).get('reason')=='application_reopen' for e in presented),presented
 identity=json.loads((out/'finished.json').read_text());assert identity['android_icns_mean_error']<4 and identity['running_platform_mean_error']<4 and identity['generic_host_difference']>10,identity
 assert identity['bundle_id']==record['bundleIdentifier'] and identity['name']==record['name'] and identity['activation_policy']==0 and identity['icon_valid'],identity
 for file in set(logs.glob('*.jsonl'))-oldlogs:(out/file.name).write_bytes(file.read_bytes())
 (out/'result.json').write_text(json.dumps({'passed':True,'installed_main_sha256':hashlib.sha256(host.read_bytes()).hexdigest(),'managed_name':record['name'],'managed_source_build':record['sourceBuild'],'normalized_unsigned_code':normalized,'single_android_session':list(ids),'native_presentation_events':presented,'identity':identity,'helper_paused_only_for_denied_launch':True,'resource_baseline':baseline,'resources_after':after,'physical_focus_verified':False},indent=2)+'\n');print((out/'result.json').read_text())
finally:
 if paused:os.kill(helper,signal.SIGCONT)
 if process and process.poll() is None:process.terminate();process.wait(timeout=20)
 for path,data in [(pref,prior),(state,oldstate)]:
  if data is None:path.unlink(missing_ok=True)
  else:path.write_bytes(data)
