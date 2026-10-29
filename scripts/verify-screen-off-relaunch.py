#!/usr/bin/env python3
"""Exact installed app, saved per-device OFF intent across graceful relaunch."""
import hashlib,json,os,pathlib,re,subprocess,time
home=pathlib.Path.home();app=home/'Applications/DroidBridge.app';exe=app/'Contents/MacOS/DroidBridge';adb=str(app/'Contents/Resources/Runtime/bin/adb')
out=pathlib.Path('verification/screen-off/relaunch');out.mkdir(parents=True,exist_ok=True)
support=home/'Library/Application Support/DroidBridge';prefs=support/'preferences.json';intent=support/'sessions.json';logs=home/'Library/Logs/DroidBridge'
snapshot={p:(p.read_bytes(),p.stat().st_mode&0o777) if p.exists() else None for p in (prefs,intent)}
prior=set(logs.glob('*.log.jsonl'));children=[];report={'passed':False,'installed_sha256':hashlib.sha256(exe.read_bytes()).hexdigest(),'launches':[]}
def run(*args):return subprocess.check_output(args,text=True,stderr=subprocess.STDOUT,timeout=20)
def shell(*args):return run(adb,'-s','emulator-5580','shell',*args)
def state():
 line=next(x for x in shell('cmd','display','get-displays').splitlines() if x.startswith('Display id 0:'));return re.search(r'\bstate ([A-Z_]+)',line)[1]
def resources():return {'displays':shell('cmd','display','get-displays').count('Display id '),'forwards':[x for x in run(adb,'forward','--list').splitlines() if x.startswith('emulator-5580 ')]}
def wait(test,seconds=35):
 end=time.monotonic()+seconds
 while time.monotonic()<end:
  if test():return
  time.sleep(.2)
 raise AssertionError('Bounded wait failed')
def quit(child):
 run('/usr/bin/swift','-e','import AppKit; if let app = NSRunningApplication(processIdentifier:Int32(CommandLine.arguments[1])!) { _ = app.terminate() }',str(child.pid));child.wait(timeout=25);assert child.returncode==0
baseline=resources();assert state()=='ON' and baseline['displays']==1
try:
 data=json.loads(snapshot[prefs][0]) if snapshot[prefs] else {};data['screenOffDeviceSerials']=sorted(set(data.get('screenOffDeviceSerials',[]))|{'emulator-5580'})
 tmp=prefs.with_suffix('.relaunch-test');tmp.write_text(json.dumps(data));os.replace(tmp,prefs)
 for index in range(2):
  if index:shell('cmd','display','power-on','0');wait(lambda:state()=='ON')
  before=set(logs.glob('*.log.jsonl'));handle=(out/f'host-{index}.log').open('w')
  child=subprocess.Popen([str(exe),'--serial','emulator-5580','--launch','dev.droidbridge.testapp','--backend','native'],stdout=handle,stderr=subprocess.STDOUT);children.append(child)
  wait(lambda:state()=='OFF' and resources()['displays']==2)
  def running():return any(json.loads(line).get('state')=='running' for f in set(logs.glob('*.log.jsonl'))-before for line in f.read_text().splitlines() if line.startswith('{'))
  wait(running)
  time.sleep(28 if index==0 else 2)
  assert state()=='OFF' and child.poll() is None
  quit(child);handle.close();wait(lambda:resources()==baseline)
  assert state()=='OFF','Quit must not implicitly wake phone'
  assert 'emulator-5580' in json.loads(prefs.read_text())['screenOffDeviceSerials']
  report['launches'].append({'cycle':index+1,'automatic_off_verified':True,'decoded_native_running':True,'graceful_exit':child.returncode,'close_kept_panel_off':True,'resource_baseline_restored':True})
 report['passed']=True
finally:
 for child in children:
  if child.poll() is None:quit(child)
 shell('cmd','display','power-on','0');wait(lambda:state()=='ON')
 for p,value in snapshot.items():
  if value is None:p.unlink(missing_ok=True)
  else:p.write_bytes(value[0]);p.chmod(value[1])
 for f in set(logs.glob('*.log.jsonl'))-prior:(out/f.name).write_bytes(f.read_bytes())
 (out/'result.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
