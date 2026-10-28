#!/usr/bin/env python3
"""Real three-display emulator smoke test. Never controls an unscoped device."""
import json, os, pathlib, re, subprocess, time
ROOT=pathlib.Path(__file__).resolve().parent.parent
OUT=ROOT/'verification/android'; OUT.mkdir(parents=True,exist_ok=True)
ADB=os.environ.get('DROIDBRIDGE_ADB',str(pathlib.Path.home()/'Library/Android/sdk/platform-tools/adb'))
SCRCPY=os.environ.get('DROIDBRIDGE_SCRCPY','/opt/homebrew/bin/scrcpy')
SERIAL=os.environ.get('DROIDBRIDGE_TEST_SERIAL','emulator-5580')
def adb(*args):
 r=subprocess.run([ADB,'-s',SERIAL,*args],capture_output=True,text=True,timeout=20)
 if r.returncode: raise RuntimeError(r.stdout+r.stderr)
 return r.stdout
assert adb('shell','getprop','sys.boot_completed').strip()=='1'
adb('shell','logcat','-c')
apps=['com.android.settings','org.chromium.webview_shell','dev.droidbridge.testapp']
processes=[]
try:
 for i,pkg in enumerate(apps):
  log=open(OUT/f'backend-a-{i}.log','w')
  args=[SCRCPY,'--serial',SERIAL,'--new-display=720x1080/240','--flex-display','--no-audio','--start-app='+pkg,'--window-title=DroidBridge Android Verify '+pkg,'--window-x='+str(i*400),'--window-y=60','--time-limit=35','--record='+str(OUT/f'backend-a-{i}.mp4')]
  (OUT/f'backend-a-{i}-command.json').write_text(json.dumps(args,indent=2))
  processes.append((subprocess.Popen(args,stdout=log,stderr=subprocess.STDOUT),log))
  time.sleep(2)
 time.sleep(5)
 displays=adb('shell','dumpsys','display'); (OUT/'concurrent-displays.txt').write_text(displays)
 tasks=adb('shell','dumpsys','activity','activities'); (OUT/'concurrent-tasks.txt').write_text(tasks)
 for pkg in apps: assert pkg in tasks, pkg+' missing from tasks'
 ids=[]
 for i in range(3):
  log=(OUT/f'backend-a-{i}.log').read_text()
  match=re.search(r'Starting app .* on display (\d+)',log)
  assert match, 'No display-targeted app launch: '+log
  ids.append(int(match[1]))
 assert len(set(ids))==3
 probe=str(ids[2])
 # SDK input paths are display targeted; native transport is verified separately.
 adb('shell','input','-d',probe,'tap','300','225')
 adb('shell','input','-d',probe,'tap','260','295')
 adb('shell','input','-d',probe,'text','DroidBridgeInput')
 time.sleep(1)
 log=adb('shell','logcat','-d','-s','DroidBridgeProbe:I'); (OUT/'probe-input.log').write_text(log)
 assert 'click=1 display='+probe in log, 'display-targeted click failed'
 assert 'text=DroidBridgeInput display='+probe in log, 'display-targeted typing failed'
 # Save host pixels when Screen Recording permission permits.
 subprocess.run(['/usr/sbin/screencapture','-x',str(OUT/'host-screenshot-unverified.png')],capture_output=True)
 before=adb('shell','wm','size','-d',probe)
 resized=adb('shell','wm','size','900x1200','-d',probe)
 time.sleep(2)
 after=adb('shell','wm','size','-d',probe)
 (OUT/'display-resize.txt').write_text(before+'\n'+resized+'\n'+after)
 assert '900x1200' in after
 for proc,_ in processes: assert proc.poll() is None, 'scrcpy exited early'
 (OUT/'core-result.json').write_text(json.dumps({'serial':SERIAL,'packages':apps,'displayIDs':ids,'concurrent':True,'adbDisplayInputLog':log,'displayResize':True,'note':'ADB input and wm resize exercise Android platform, GUI/control injection verified separately.'},indent=2))
finally:
 for proc,log in processes:
  if proc.poll() is None: proc.terminate()
 for proc,log in processes:
  try: proc.wait(timeout=10)
  except subprocess.TimeoutExpired: proc.kill();proc.wait()
  log.close()
 time.sleep(2)
 (OUT/'after-stop-displays.txt').write_text(adb('shell','dumpsys','display'))
 (OUT/'after-stop-forwards.txt').write_text(adb('forward','--list'))

# Generate a truthful decoded-stream contact sheet (not a host screenshot).
subprocess.run(["ffmpeg","-y","-ss","1","-i",str(OUT/"backend-a-0.mp4"),"-ss","1","-i",str(OUT/"backend-a-1.mp4"),"-ss","1","-i",str(OUT/"backend-a-2.mp4"),"-filter_complex","[0:v]scale=720:1080[a];[1:v]scale=720:1080[b];[2:v]scale=720:1080[c];[a][b][c]hstack=inputs=3","-frames:v","1",str(OUT/"concurrent-streams-contact-sheet.png")],capture_output=True,check=True)
