#!/usr/bin/env python3
"""Actual installed AppKit menu/checkbox actions. Does not claim physical focus.
Run only under an exclusive reservation for supplied task-owned emulators and
DroidBridge preferences/session intents. No external app/user device is touched.
"""
import argparse,hashlib,json,os,pathlib,plistlib,re,subprocess,time
p=argparse.ArgumentParser();p.add_argument('--app',type=pathlib.Path,default=pathlib.Path.home()/'Applications/DroidBridge.app');p.add_argument('--serial',default='emulator-5580');p.add_argument('--other-serial');p.add_argument('--inject-on-failure',action='store_true');p.add_argument('--sha256',required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
assert a.serial in ('emulator-5580','emulator-5582') and (not a.other_serial or a.other_serial in ('emulator-5580','emulator-5582') and a.other_serial!=a.serial)
repo=pathlib.Path(__file__).resolve().parents[3];app=a.app.resolve();out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
exe=app/'Contents/MacOS/DroidBridge';assert hashlib.sha256(exe.read_bytes()).hexdigest()==a.sha256,'Wrong installed candidate'
assert plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']=='0.1.4','Expected screen-control release'
adb=app/'Contents/Resources/Runtime/bin/adb'
if not adb.exists():adb=next((app/'Contents/Resources').rglob('adb'))
support=pathlib.Path.home()/'Library/Application Support/DroidBridge';prefs=support/'preferences.json';intent=support/'sessions.json';logs=pathlib.Path.home()/'Library/Logs/DroidBridge'
snapshot={f:f.read_bytes() if f.exists() else None for f in (prefs,intent)};modes={f:f.stat().st_mode & 0o777 for f in snapshot if f.exists()};initial_logs=set(logs.glob('*.jsonl'));owned=None;actions=[];number=0

def run(*cmd):return subprocess.check_output(list(map(str,cmd)),text=True,stderr=subprocess.STDOUT,timeout=15)
def shell(serial,*args):return run(adb,'-s',serial,'shell',*args)
def wait(label,condition,timeout=35):
 began=time.monotonic()
 while time.monotonic()-began<timeout:
  value=condition()
  if value:return value
  time.sleep(.15)
 raise AssertionError('Timed out: '+label)
def state(serial):
 text=shell(serial,'cmd','display','get-displays');lines=[x for x in text.splitlines() if re.match(r'^\s*Display id 0:\s',x)]
 assert len(lines)==1 and 'type INTERNAL' in lines[0],text
 match=re.search(r'(?:^|[\s,{])state\s+([A-Z_]+)(?=[\s,}])',lines[0]);assert match,text
 return match[1]
def flag(serial):return serial in json.loads(prefs.read_text()).get('screenOffDeviceSerials',[])
def events():
 result=[]
 for f in set(logs.glob('*.jsonl'))-initial_logs:
  for line in f.read_text().splitlines():
   try:result.append(json.loads(line))
   except json.JSONDecodeError:pass
 return result
def own_events():return [e for e in events() if e.get('device')==a.serial and e.get('package')=='dev.droidbridge.testapp']
def action(command,**kwargs):
 global number
 number+=1;file=out/f'receipt-{number}.json';file.unlink(missing_ok=True)
 temp=out/'command.tmp';temp.write_text(json.dumps(dict(id=number,action=command,**kwargs)));temp.replace(out/'command.json')
 receipt=wait(command,lambda:json.loads(file.read_text()) if file.exists() else None)
 actions.append(receipt);assert receipt['passed'],receipt
 return receipt
def capture(name):
 action('capture',filename=name);data=(out/name).read_bytes();return hashlib.sha256(data).hexdigest()
def baseline():
 return dict(forwards=[x for x in run(adb,'forward','--list').splitlines() if x.split() and x.split()[0]==a.serial],displays=shell(a.serial,'cmd','display','get-displays').count('Display id '))

assert shell(a.serial,'getprop','sys.boot_completed').strip()=='1';other_panel=state(a.other_serial) if a.other_serial else None;before=baseline();shim=repo/'.build/qa-phone-controls.dylib'
run('clang','-dynamiclib','-fobjc-arc','-framework','AppKit',repo/'verification/screen-off/qa/control-actions.m','-o',shim)
(out/'command.json').unlink(missing_ok=True)
env=os.environ.copy()
if a.inject_on_failure:
 proxy=out/'adb-fail-once.py'
 proxy.write_text("#!/usr/bin/python3\nimport os,pathlib,sys\nmarker=pathlib.Path("+repr(str(out/'fail-next-on'))+")\na=sys.argv[1:]\nif a[:2]==['-s',"+repr(a.serial)+"] and a[2:] in (['shell','cmd','display','power-on','0'],['shell','cmd','display','power-reset','0']) and marker.exists():\n marker.unlink();print('QA injected one explicit ON transport failure',file=sys.stderr);sys.exit(1)\nos.execv("+repr(str(adb))+",["+repr(str(adb))+"]+a)\n")
 proxy.chmod(0o755);env['DROIDBRIDGE_ADB']=str(proxy)
env['DYLD_INSERT_LIBRARIES']=str(shim);env['DROIDBRIDGE_QA_POWER_ROOT']=str(out)
report={'passed':False,'installed_sha256':a.sha256,'serial':a.serial,'physical_focus_verified':False,'injected_single_on_failure':a.inject_on_failure,'instrumentation':'Public AppKit menu performAction and checkbox performClick in exact installed binary'}
try:
 with (out/'host.log').open('w') as logfile:
  owned=subprocess.Popen([str(exe),'--serial',a.serial],env=env,stdout=logfile,stderr=logfile)
  action('ready');action('menu_on');wait('initial ON',lambda:state(a.serial)=='ON' and not flag(a.serial))
  action('launch',package='dev.droidbridge.testapp');wait('actual native first frame',lambda:any(e.get('state')=='running' for e in own_events()))
  before_frame=capture('before-off.png')
  action('checkbox_on');wait('checkbox physical OFF',lambda:state(a.serial)=='OFF' and flag(a.serial))
  first_off=capture('off-first.png');time.sleep(1.3);second_off=capture('off-second.png')
  assert first_off!=second_off,'Animated Android content stopped updating with primary display OFF'
  assert not any(e.get('state') in ('failed','stopping','stopped') for e in own_events()),'Power action terminated session'
  if a.inject_on_failure:(out/'fail-next-on').touch()
  action('menu_on')
  if a.inject_on_failure:
   wait('ON error retained intent clear and panel OFF',lambda:not (out/'fail-next-on').exists() and not flag(a.serial) and state(a.serial)=='OFF',timeout=12)
   retry=action('status');assert any('will retry' in x for x in retry['phone_messages']),'No visible retry diagnostic'
  wait('menu ON and intent clear',lambda:state(a.serial)=='ON' and not flag(a.serial))
  action('menu_off');wait('menu OFF and intent saved',lambda:state(a.serial)=='OFF' and flag(a.serial))
  action('checkbox_off');wait('checkbox ON and intent clear',lambda:state(a.serial)=='ON' and not flag(a.serial))
  if a.other_serial:
   other_flag=flag(a.other_serial);selected=action('select_device',serial=a.other_serial)
   assert selected['checkbox_state']==int(other_flag),'Selection did not show per-device preference'
   action('select_device',serial=a.serial)
   action('checkbox_on');wait('first OFF per-device isolation',lambda:state(a.serial)=='OFF' and flag(a.serial))
   other=action('select_device',serial=a.other_serial)
   assert other['checkbox_state']==int(other_flag) and flag(a.other_serial)==other_flag,'First device changed second preference'
   assert state(a.other_serial)==other_panel,'First device action changed second physical panel'
   action('select_device',serial=a.serial);action('menu_on');wait('restore first ON',lambda:state(a.serial)=='ON' and not flag(a.serial))
  action('quit');owned.wait(timeout=20);assert owned.returncode==0
  wait('exact display/forward cleanup',lambda:baseline()==before)
  report.update(passed=True,other_panel_unchanged=(state(a.other_serial)==other_panel if a.other_serial else None),app_exit=owned.returncode,baseline=before,after=baseline(),frame_hashes={'before':before_frame,'off_first':first_off,'off_second':second_off},actions=actions)
finally:
 if owned and owned.poll() is None:
  try:action('menu_on');wait('cleanup ON',lambda:state(a.serial)=='ON',timeout=12);action('quit');owned.wait(timeout=15)
  except Exception:
   owned.terminate()
   try:owned.wait(timeout=5)
   except subprocess.TimeoutExpired:owned.kill();owned.wait(timeout=5)
 for file,data in snapshot.items():
  if data is None:file.unlink(missing_ok=True)
  else:
   tmp=file.with_suffix('.qa-restore');tmp.write_bytes(data);os.chmod(tmp,modes[file]);tmp.replace(file)
 for f in set(logs.glob('*.jsonl'))-initial_logs:(out/f.name).write_bytes(f.read_bytes())
 report['actions']=actions
 (out/'result.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
