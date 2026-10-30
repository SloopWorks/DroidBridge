#!/usr/bin/env python3
"""Public AppKit actions in the exact installed release; real emulator5580.

The test-only dylib never ships and unsets injection before launching children.
Locked desktops cannot establish physical keyboard focus/Spotlight behavior.
"""
import hashlib,json,os,pathlib,plistlib,subprocess,time
repo=pathlib.Path(__file__).resolve().parents[1]
app=pathlib.Path.home()/'Applications/DroidBridge.app'
out=repo/'verification/launcher-redesign/installed/gui'
if out.exists():
 archive=repo/'.build/launcher-gui-runs'/str(time.time_ns());archive.parent.mkdir(parents=True,exist_ok=True);out.rename(archive)
out.mkdir(parents=True,exist_ok=True)
adb=app/'Contents/Resources/Runtime/bin/adb';logs=pathlib.Path.home()/'Library/Logs/DroidBridge'
def run(*args):return subprocess.check_output(list(map(str,args)),text=True,stderr=subprocess.STDOUT,timeout=45)
def android(*args):return run(adb,'-s','emulator-5580',*args)
def resources():return {'displays':android('shell','cmd','display','get-displays').count('Display id '),'forwards':[x for x in run(adb,'forward','--list').splitlines() if x.startswith('emulator-5580 ')],'reverses':[x for x in android('reverse','--list').splitlines() if x.strip()]}
run('clang','-dynamiclib','-fobjc-arc','-framework','AppKit',repo/'verification/launcher-redesign/control-actions.m','-o',repo/'.build/launcher-control-actions.dylib')
assert android('shell','getprop','sys.boot_completed').strip()=='1'
support=pathlib.Path.home()/'Library/Application Support/DroidBridge'
snapshots={p:(p.read_bytes(),p.stat().st_mode&0o777) if p.exists() else None for p in (support/'sessions.json',support/'preferences.json')}
number=0;child=None;cases=[];initial=set(logs.glob('*.jsonl'));before=resources()
metadata=plistlib.loads((app/'Contents/Info.plist').read_bytes())
geometry={}
for package in ('dev.droidbridge.testapp','dev.droidbridge.testapp2'):
 key='NSWindow Frame AndroidApp.'+hashlib.sha256(('emulator-5580:'+package).encode()).hexdigest()
 try:geometry[key]=run('defaults','read',metadata['CFBundleIdentifier'],key).strip()
 except subprocess.CalledProcessError:geometry[key]=None
report={'passed':False,'app':str(app),'version':metadata['CFBundleShortVersionString'],'build':metadata['CFBundleVersion'],'executable_sha256':hashlib.sha256((app/'Contents/MacOS/DroidBridge').read_bytes()).hexdigest(),'instrumentation':'public AppKit actions in unmodified installed binary; real Android transport and video','physical_focus_verified':False,'cases':cases,'before':before}
def command(action,**kwargs):
 global number
 number+=1;path=out/f'receipt-{number}.json';path.unlink(missing_ok=True)
 temporary=out/'command.tmp';temporary.write_text(json.dumps(dict(id=number,action=action,**kwargs)));temporary.replace(out/'command.json')
 deadline=time.monotonic()+15
 while not path.exists() and time.monotonic()<deadline:
  assert child.poll() is None,'installed application exited'
  time.sleep(.05)
 assert path.exists(),f'no receipt {action}'
 data=json.loads(path.read_text());assert data['passed'],data;return data
def wait(label,predicate,timeout=60):
 deadline=time.monotonic()+timeout
 while time.monotonic()<deadline:
  value=predicate()
  if value:return value
  time.sleep(.2)
 raise AssertionError('timeout: '+label)
def new_events():
 result=[]
 for file in set(logs.glob('*.jsonl'))-initial:
  for line in file.read_text().splitlines():
   try:result.append(json.loads(line))
   except json.JSONDecodeError:pass
 return result
def launched(package,backend):
 command('search',query=package)
 wait('filtered package',lambda:command('status')['rows']>=1)
 command('launch',package=package,backend=backend)
 events=wait('running '+package,lambda:[e for e in new_events() if e.get('package')==package and e.get('backend')==backend and e.get('state')=='running'])
 session=events[-1]['session']
 if backend=='native':
  shown=wait('native presented',lambda:[e for e in new_events() if e.get('session')==session and e.get('event')=='loading_window_presented'])
  return int(shown[-1]['details']['window_number'])
 return session
try:
 # Do not offer restoration of unrelated persisted intents during the test.
 (support/'sessions.json').write_text('[]')
 env=os.environ.copy();env.update(PATH='/usr/bin:/bin',DYLD_INSERT_LIBRARIES=str(repo/'.build/launcher-control-actions.dylib'),DROIDBRIDGE_LAUNCHER_QA_ROOT=str(out))
 with (out/'host.log').open('w') as handle:
  child=subprocess.Popen([str(app/'Contents/MacOS/DroidBridge'),'--serial','emulator-5580'],env=env,stdout=handle,stderr=handle)
  ready=wait('ready actual launcher',lambda:(s if (s:=command('status'))['rows']>0 and 'emulator-5580' in s['device'] else None))
  assert ready['rows']>=3,ready
  command('capture',filename='launcher-ready.png')
  cases.append({'case':'installed_launcher_device_and_apps','apps':ready['rows'],'device':ready['device'],'passed':True})
  command('search',query='no-match-qa-987654')
  empty=command('status');assert empty['rows']==0 and not empty['launch_enabled']
  cases.append({'case':'real_catalog_no_match_disables_launch','passed':True})
  android('logcat','-c')
  for package in ('dev.droidbridge.testapp','dev.droidbridge.testapp2'):android('shell','am','force-stop',package)
  first=launched('dev.droidbridge.testapp','native')
  second=launched('dev.droidbridge.testapp2','native');assert first!=second
  # Restore state may contain a previous landscape geometry. Establish the
  # test's portrait720x1080 stream before using its known Android coordinates.
  for window in (first,second):command('resize',window=window,width=480,height=720)
  time.sleep(3)
  command('capture',window=first,filename='native-first-before.png');command('capture',window=second,filename='native-second.png')
  command('capture',filename='launcher-two-native.png')
  command('input',window=first,x=300/720,y=225/1080)
  command('input',window=first,x=260/720,y=295/1080,text='LauncherFirst')
  command('input',window=second,x=300/720,y=225/1080)
  command('input',window=second,x=260/720,y=295/1080,text='LauncherSecond')
  inputlog=wait('both Android text receipts',lambda:(log if 'text=LauncherFirst' in (log:=android('logcat','-d','-s','DroidBridgeProbe:I','*:S')) and 'text=LauncherSecond' in log else None),15)
  (out/'android-input.log').write_text(inputlog)
  assert 'text=LauncherFirst' in inputlog and 'text=LauncherSecond' in inputlog and inputlog.count('click=1')>=2,inputlog
  command('capture',window=first,filename='native-first-after.png')
  assert (out/'native-first-before.png').read_bytes()!=(out/'native-first-after.png').read_bytes()
  cases.append({'case':'two_native_windows_frames_and_independent_input','windows':[first,second],'passed':True})
  command('resize',window=first,width=640,height=440);time.sleep(2)
  command('capture',window=first,filename='native-first-resized.png')
  android('logcat','-c')
  command('input',window=first,x=400/960,y=225/656)
  time.sleep(.6)
  resize_log=android('logcat','-d','-s','DroidBridgeProbe:I','*:S');(out/'android-resized-input.log').write_text(resize_log)
  # Either retained or recreated Activities are valid. Require a NEW Android
  # receipt after clearing the log, independent of its counter's prior value.
  assert 'DroidBridgeProbe: click=' in resize_log,resize_log
  command('resize',window=next(w['number'] for w in command('status')['windows'] if w['title']=='DroidBridge'),width=920,height=640)
  command('capture',filename='launcher-minimum.png')
  command('close',window=first);time.sleep(.6)
  state=command('status');assert any(w['number']==second and w['visible'] for w in state['windows'])
  cases.append({'case':'resize_input_and_independent_close','passed':True})
  fallback=launched('com.android.settings','scrcpy');time.sleep(2)
  command('capture',filename='launcher-native-and-fallback.png')
  cases.append({'case':'backend_selector_actual_scrcpy_with_native_alive','session':fallback,'passed':True})
  command('close',window=second)
  # Exercise setup through the redesigned sidebar, including cancellation at
  # admission and an idempotent complete pass over the actual16-app catalog.
  wait('Spotlight admission enabled',lambda:command('status')['buttons'].get('Add Device Apps…'),120)
  command('button',title='Add Device Apps…');command('button',title='Cancel')
  wait('cancel drained',lambda:command('status')['buttons'].get('Add Device Apps…'),90)
  command('button',title='Add Device Apps…')
  finished=wait('all device apps processed',lambda:(s if (s:=command('status'))['buttons'].get('Add Device Apps…') and any('16/16' in text and '0 errors' in text and 'Finished' in text for text in s['texts']) else None),180)
  command('button',title='Details…');command('capture',filename='launcher-onboarding-complete.png');command('dismiss_sheet')
  catalog=json.loads((support/'ManagedApps.noindex/catalog.json').read_text())
  records=[r for r in catalog['records'].values() if r['deviceSerial']=='emulator-5580']
  assert len(records)==16 and all(r.get('sourceVersion')==report['version'] and r.get('sourceBuild')==report['build'] for r in records)
  (out/'onboarding-records.json').write_text(json.dumps(records,indent=2)+'\n')
  cases.append({'case':'sidebar_cancel_resume_actual16_apps_and_details','records':len(records),'summary':[t for t in finished['texts'] if '16/16' in t],'passed':True})
  command('search',query='dev.droidbridge.testapp2')
  wait('create wrapper enabled',lambda:command('status')['buttons'].get('Create / Update Mac App…'),60)
  wrapper=pathlib.Path.home()/'Applications/DroidBridge Apps/DroidBridge Test.app'
  assert not wrapper.exists(),'preserve existing user wrapper; choose dedicated test name before running'
  command('button',title='Create / Update Mac App…')
  wait('signed wrapper created by GUI',lambda:wrapper.exists() and any('Created or updated' in text for text in command('status')['texts']),90)
  run('codesign','--verify','--deep','--strict',wrapper)
  assert (wrapper/'Contents/Resources/AndroidApp.icns').stat().st_size>0
  # Re-signing an independent bundle changes its embedded signature bytes.
  # Compare executable instructions, not the identity-dependent signature.
  code=lambda binary:'\n'.join(run('otool','-s','__TEXT','__text',binary).splitlines()[1:])
  assert code(wrapper/'Contents/MacOS/DroidBridge')==code(app/'Contents/MacOS/DroidBridge')
  cases.append({'case':'create_mac_app_button_actual_signed_bundle_android_icon','path':str(wrapper),'passed':True})
  # This is our new test bundle, not a user's wrapper. Keep it for inspection
  # outside Applications without publishing another permanent app identity.
  saved=repo/'.build/launcher-created-wrapper';saved.mkdir(exist_ok=True)
  if (saved/wrapper.name).exists():(saved/wrapper.name).rename(saved/(str(time.time_ns())+'-'+wrapper.name))
  wrapper.rename(saved/wrapper.name)
  command('quit');child.wait(timeout=40);assert child.returncode==0
 wait('resource cleanup',lambda:resources()==before,25)
 cases.append({'case':'installed_graceful_shutdown_resources','passed':True})
 report['passed']=True
finally:
 if child and child.poll() is None:
  try:command('quit')
  except Exception:child.terminate()
  try:child.wait(timeout=40)
  except subprocess.TimeoutExpired:child.kill();child.wait(timeout=5)
 for p,snapshot in snapshots.items():
  if snapshot is None:p.unlink(missing_ok=True)
  else:p.write_bytes(snapshot[0]);p.chmod(snapshot[1])
 for key,value in geometry.items():
  if value is None:subprocess.run(['defaults','delete',metadata['CFBundleIdentifier'],key],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  else:run('defaults','write',metadata['CFBundleIdentifier'],key,'-string',value)
 for file in set(logs.glob('*.jsonl'))-initial:
  (out/file.name).write_bytes(file.read_bytes());raw=file.with_suffix('')
  if raw.exists():(out/raw.name).write_bytes(raw.read_bytes())
 deadline=time.monotonic()+25
 while resources()!=before and time.monotonic()<deadline:time.sleep(.2)
 report['after']=resources();report['state_restored']=True
 (out/'result.json').write_text(json.dumps(report,indent=2)+'\n')
 # Polls are diagnostic state observations, not individual test claims.
 # Retain action receipts and one final status rather than hundreds of copies.
 for file in out.glob('receipt-*.json'):
  if json.loads(file.read_text()).get('action')=='status':
   (out/'last-status.json').write_bytes(file.read_bytes());file.unlink()
print(json.dumps(report,indent=2))
