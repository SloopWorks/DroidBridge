#!/usr/bin/env python3
"""Real factory wrappers from installed host; public AppKit observation only.
Preserves exact QA wrapper intent and its sole NSWindow geometry preference.
Only emulator5580 is used. No Player instrumentation or fake Android transport.
"""
import argparse,hashlib,json,os,pathlib,plistlib,subprocess,time
repo=pathlib.Path(__file__).resolve().parents[1]
app=pathlib.Path.home()/'Applications/DroidBridge.app'
parser=argparse.ArgumentParser();parser.add_argument('--output',type=pathlib.Path,default=repo/'verification/launch-ux/installed');args=parser.parse_args()
out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
adb=app/'Contents/Resources/Runtime/bin/adb'
def run(*args):return subprocess.check_output(list(map(str,args)),text=True,stderr=subprocess.STDOUT,timeout=45)
def android(*args):return run(adb,'-s','emulator-5580',*args)
def resources():return {'displays':android('shell','cmd','display','get-displays').count('Display id '),'forwards':[x for x in run(adb,'forward','--list').splitlines() if x.startswith('emulator-5580 ')],'reverses':[x for x in android('reverse','--list').splitlines() if x.strip()]}
assert android('shell','getprop','sys.boot_completed').strip()=='1'
binpath=run('swift','build','--show-bin-path').strip()
objects=list(pathlib.Path(binpath).glob('DroidBridgeCore.build/*.o'))
run('swiftc','-parse-as-library','-I',binpath+'/Modules',repo/'Sources/DroidBridge/MacAppWrapper.swift',repo/'verification/launch-ux/MakeWrapper.swift',*objects,'-o',repo/'.build/qa-launch-make-wrapper')
wrapper=pathlib.Path(run(repo/'.build/qa-launch-make-wrapper',app,repo/'.build/launch-ux-wrappers').strip())
run('codesign','--verify','--deep','--strict',wrapper)
run('clang','-dynamiclib','-fobjc-arc','-framework','AppKit',repo/'verification/launch-ux/installed/observe.m','-o',repo/'.build/qa-launch-ux-observe.dylib')
identifier='app.droidbridge.wrapper.dev.droidbridge.testapp'
key='NSWindow Frame AndroidApp.'+hashlib.sha256(b'emulator-5580:dev.droidbridge.testapp').hexdigest()
try:prior_geometry=run('defaults','read',identifier,key).strip()
except subprocess.CalledProcessError:prior_geometry=None
intent=pathlib.Path.home()/'Library/Application Support/DroidBridge'/('sessions-'+identifier+'.json')
prior=intent.read_bytes() if intent.exists() else None;mode=intent.stat().st_mode&0o777 if intent.exists() else None
logs=pathlib.Path.home()/'Library/Logs/DroidBridge'
before=resources();child=None;cases=[]
metadata=plistlib.loads((app/'Contents/Info.plist').read_bytes())
report={'passed':False,'installed_path':str(app),'version':metadata['CFBundleShortVersionString'],'build':metadata['CFBundleVersion'],'installed_sha256':hashlib.sha256((app/'Contents/MacOS/DroidBridge').read_bytes()).hexdigest(),'wrapper_path':str(wrapper),'real_android_icon_png_sha256':hashlib.sha256((wrapper/'Contents/Resources/AndroidApp.png').read_bytes()).hexdigest(),'public_appkit_instrumentation':True,'player_instrumentation':False,'physical_spotlight_focus_verified':False,'cases':cases}
try:
 for index,backend in enumerate(('native','native','scrcpy','scrcpy','native')):
  case=out/f'{index+1}-{backend}';case.mkdir(exist_ok=True);(case/'ui.json').unlink(missing_ok=True)
  initial=set(logs.glob('*.jsonl'));env=os.environ.copy();env.update(PATH='/usr/bin:/bin',DYLD_INSERT_LIBRARIES=str(repo/'.build/qa-launch-ux-observe.dylib'),DROIDBRIDGE_LAUNCH_UX_OUT=str(case),DROIDBRIDGE_LAUNCH_UX_BACKEND=backend,DROIDBRIDGE_LAUNCH_UX_RESIZE='1' if index==0 else '0')
  with (case/'host.log').open('w') as handle:
   command=[str(wrapper/'Contents/MacOS/DroidBridge'),'--backend',backend]
   if index==4:
    command=['/usr/bin/open','-n','-W']
    for name in ('DYLD_INSERT_LIBRARIES','DROIDBRIDGE_LAUNCH_UX_OUT','DROIDBRIDGE_LAUNCH_UX_BACKEND','DROIDBRIDGE_LAUNCH_UX_RESIZE'):command+=['--env',name+'='+env[name]]
    command += [str(wrapper),'--args','--backend',backend]
   child=subprocess.Popen(command,env=env if index!=4 else os.environ.copy(),stdout=handle,stderr=handle)
   child.wait(timeout=40)
  assert child.returncode==0,child.returncode
  ui=json.loads((case/'ui.json').read_text());assert ui['passed'] and not ui['launcher_visible_during_launch'],ui
  assert ui['first_window_seconds']<2,ui
  assert ui['loading_accessibility']=='Loading Launch UX Probe',ui
  if backend=='native':
   assert ui['first_window_number']==ui['live_window_number'],ui
   assert (case/'live-stable.png').exists()
   # Shipping view only labels the app live once visible decoded content exists.
   assert ui['live_seconds']>=ui['first_window_seconds']
  if index>0:assert abs(ui['initial_content_width']-420)<2 and abs(ui['initial_content_height']-560)<2,ui
  events=[]
  for file in set(logs.glob('*.jsonl'))-initial:
   scoped=[json.loads(x) for x in file.read_text().splitlines()]
   scoped=[e for e in scoped if e.get('device')=='emulator-5580' and e.get('backend')==backend and e.get('package')=='dev.droidbridge.testapp']
   if not scoped:continue
   (case/file.name).write_text('\n'.join(json.dumps(e,sort_keys=True) for e in scoped)+'\n')
   raw=file.with_suffix('')
   if raw.exists():(case/raw.name).write_bytes(raw.read_bytes())
   events += scoped
  if backend=='native':assert any(e.get('event')=='native_content_presented' for e in events),events
  assert any(e.get('state')=='running' and e.get('backend')==backend and e.get('package')=='dev.droidbridge.testapp' for e in events)
  assert not any(e.get('state')=='failed' for e in events),events
  deadline=time.monotonic()+12
  while time.monotonic()<deadline and resources()!=before:time.sleep(.15)
  assert resources()==before,'Owned resources leaked'
  cases.append(dict(index=index+1,backend=backend,launch_services=index==4,ui=ui,app_exit=child.returncode,resources_restored=True))
  (out/'result.json').write_text(json.dumps(report,indent=2)+'\n')
 report['passed']=True
finally:
 if child and child.poll() is None:
  child.terminate()
  try:child.wait(timeout=20)
  except subprocess.TimeoutExpired:child.kill();child.wait(timeout=5)
 if prior is None:intent.unlink(missing_ok=True)
 else:intent.write_bytes(prior);intent.chmod(mode)
 if prior_geometry is None:
  subprocess.run(['defaults','delete',identifier,key],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 else:run('defaults','write',identifier,key,'-string',prior_geometry)
 report['after']=resources();report['before']=before
 (out/'result.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
