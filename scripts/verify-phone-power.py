#!/usr/bin/env python3
"""Real Core power commands and concurrent process intent, dedicated AVDs only."""
import argparse,json,pathlib,re,subprocess,time
p=argparse.ArgumentParser();p.add_argument('--serial',choices=['emulator-5580','emulator-5582'],required=True);a=p.parse_args()
root=pathlib.Path.cwd();adb=str(pathlib.Path.home()/'Library/Android/sdk/platform-tools/adb');out=root/'verification/screen-off/core-real'/a.serial;out.mkdir(parents=True,exist_ok=True)
state_root=pathlib.Path.home()/'Library/Application Support/DroidBridge'/('PowerTest-'+a.serial+'.noindex')
binary=root/'.build/verify-phone-power'
def shell(*args):return subprocess.check_output([adb,'-s',a.serial,'shell',*args],text=True,stderr=subprocess.STDOUT,timeout=15)
def state():
 text=shell('cmd','display','get-displays');line=next(x for x in text.splitlines() if x.startswith('Display id 0:'));return re.search(r'\bstate ([A-Z_]+)',line)[1]
def command(mode):return [str(binary),mode,a.serial,str(state_root),adb,'Dedicated power test']
def power(mode):return json.loads(subprocess.check_output(command(mode),text=True,stderr=subprocess.STDOUT,timeout=30))
def settings():return [shell('settings','get','global','stay_on_while_plugged_in'),shell('settings','get','system','screen_off_timeout')]
original=state();assert original=='ON',original
initial=settings();report={'serial':a.serial,'initial_state':original,'commands':[],'races':[]}
try:
 report['commands'].append(power('off'));assert state()=='OFF'
 time.sleep(.4);assert state()=='OFF','Core process exit must not implicitly wake panel'
 report['commands'].append(power('on'));assert state()=='ON'
 for first,last in [('off','on'),('on','off')]*3:
  left=subprocess.Popen(command(first),stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
  time.sleep(.03);right=subprocess.Popen(command(last),stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
  lo,_=left.communicate(timeout=30);ro,_=right.communicate(timeout=30)
  assert left.returncode==right.returncode==0,(lo,ro)
  intent=a.serial in json.loads((state_root/'preferences.json').read_text())['screenOffDeviceSerials']
  actual=state();assert actual==('OFF' if intent else 'ON'),(intent,actual,lo,ro)
  report['races'].append({'first':first,'last_started':last,'left':json.loads(lo),'right':json.loads(ro),'latest_saved_off':intent,'verified_state':actual})
 if a.serial=='emulator-5582':
  power('on');shell('cmd','power','sleep','--display-id','0')
  end=time.monotonic()+8
  while state()!='OFF' and time.monotonic()<end:time.sleep(.1)
  assert state()=='OFF';report['asleep_on']=power('on');assert state()=='ON'
 report.update(passed=True,settings_unchanged=settings()==initial)
 assert report['settings_unchanged']
finally:
 report['cleanup']=power('on');report['final_state']=state();assert state()=='ON'
 (out/'result.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
