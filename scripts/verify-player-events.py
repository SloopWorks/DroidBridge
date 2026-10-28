#!/usr/bin/env python3
"""Two real bundled Players; test-only public Cocoa events, Android receipts.
This proves Cocoa/SDL input routing, not OS focus behavior under a locked host.
"""
import argparse,json,os,pathlib,re,subprocess,time
p=argparse.ArgumentParser();p.add_argument('app',type=pathlib.Path);p.add_argument('--output',type=pathlib.Path,default=pathlib.Path('verification/review/player-events'));args=p.parse_args()
root=pathlib.Path(__file__).resolve().parents[1];out=args.output;out.mkdir(parents=True,exist_ok=True);runtime=args.app.resolve()/'Contents/Resources/Runtime';adb=runtime/'bin/adb';player=runtime/'Player.app/Contents/MacOS/scrcpy';shim=root/'.build/qa-player-events.dylib'
subprocess.run(['clang','-dynamiclib','-fobjc-arc','-framework','AppKit',str(root/'scripts/verify-player-events.m'),'-o',str(shim)],check=True)
def android(*cmd):return subprocess.check_output([str(adb),'-s','emulator-5580',*cmd],text=True,stderr=subprocess.STDOUT,timeout=10)
android('logcat','-c');baseline_forward=android('forward','--list');baseline_reverse=android('reverse','--list');baseline_display=android('shell','dumpsys','display').count('DisplayDeviceInfo{');processes=[]
try:
 for index,word in enumerate(('CocoaOne','CocoaTwo')):
  env=os.environ.copy();env['PATH']='/usr/bin:/bin';env['ADB']=str(adb);env['SCRCPY_SERVER_PATH']=str(runtime/'share/scrcpy/scrcpy-server');env['DYLD_INSERT_LIBRARIES']=str(shim);env['DROIDBRIDGE_QA_WORD']=word
  log=(out/f'player-{index}.log').open('w');pkg='dev.droidbridge.testapp'+('2' if index else '')
  command=[str(player),'--serial','emulator-5580','--new-display=720x1080/240','--flex-display','--no-audio','--start-app='+pkg,'--window-title=QA Player '+str(index),'--time-limit=16','--record='+str(out.resolve()/f'player-{index}.mkv')]
  process=subprocess.Popen(command,env=env,stdout=log,stderr=log);processes.append((process,log,pkg,word))
 time.sleep(10)
 receipt=android('logcat','-d','-s','DroidBridgeProbe:I','*:S');(out/'android-input.log').write_text(receipt)
 results=[]
 for index,(process,log,pkg,word) in enumerate(processes):
  text=(out/f'player-{index}.log').read_text();match=re.search(r'Starting app .* on display (\d+)',text);assert match,'no real display launch'
  display=match[1]
  assert any('click=1' in line and 'display='+display in line for line in receipt.splitlines()),f'no Cocoa mouse receipt for display {display}'
  assert any('text='+word+' display='+display in line for line in receipt.splitlines()),f'no Cocoa keyboard receipt for display {display}'
  results.append({'package':pkg,'word':word,'display':int(display),'player_pid':process.pid,'mouse_received':True,'keyboard_received':True,'input_evidence':'public Cocoa events in exact owned Player process'})
 assert len({result['display'] for result in results})==2
 (out/'results.json').write_text(json.dumps(results,indent=2)+'\n');print(json.dumps(results,indent=2))
finally:
 for process,log,_,_ in processes:
  if process.poll() is None:process.terminate()
  try:process.wait(timeout=5)
  except subprocess.TimeoutExpired:process.kill();process.wait()
  log.close()
 time.sleep(1)
 assert android('forward','--list')==baseline_forward
 assert android('reverse','--list')==baseline_reverse
 assert android('shell','dumpsys','display').count('DisplayDeviceInfo{')==baseline_display
