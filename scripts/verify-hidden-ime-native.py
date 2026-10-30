#!/usr/bin/env python3
"""Actual installed native-window IME probe; public AppKit input, real Android.

Coordinate exclusive emulator ownership before running. LOCAL is a positive bug
control; HIDE acceptance uses display/window state plus display-bound input.
"""
import argparse,hashlib,importlib.util,json,os,pathlib,plistlib,re,subprocess,time
repo=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--app',type=pathlib.Path,default=pathlib.Path.home()/'Applications/DroidBridge.app');p.add_argument('--serial',choices=['emulator-5580','emulator-5582'],default='emulator-5580');p.add_argument('--policy',choices=['local','hide'],required=True);p.add_argument('--decorations',choices=['on','off'],default='on');p.add_argument('--output',type=pathlib.Path,required=True);args=p.parse_args()
app=args.app.resolve();out=args.output.resolve();out.mkdir(parents=True,exist_ok=True);(out/'result.json').unlink(missing_ok=True);(out/'command.json').unlink(missing_ok=True)
adb=app/'Contents/Resources/Runtime/bin/adb';binary=app/'Contents/MacOS/DroidBridge';metadata=plistlib.loads((app/'Contents/Info.plist').read_bytes());package='dev.droidbridge.testapp';logs=pathlib.Path.home()/'Library/Logs/DroidBridge'
def run(*argv):return subprocess.check_output(list(map(str,argv)),text=True,stderr=subprocess.STDOUT,timeout=20)
def android(*argv):return run(adb,'-s',args.serial,*argv)
def resources():return {'display_count':android('shell','cmd','display','get-displays').count('Display id '),'forwards':[l for l in run(adb,'forward','--list').splitlines() if l.startswith(args.serial+' ')],'reverses':android('reverse','--list')}
def wait(label,predicate,seconds=30):
 end=time.monotonic()+seconds
 while time.monotonic()<end:
  value=predicate()
  if value:return value
  time.sleep(.12)
 raise AssertionError('Timeout '+label)
support=pathlib.Path.home()/'Library/Application Support/DroidBridge';state=support/('sessions-'+metadata['CFBundleIdentifier']+'.json');prior=(state.read_bytes(),state.stat().st_mode&0o777) if state.exists() else None
prefs=support/'preferences.json';prior_prefs=(prefs.read_bytes(),prefs.stat().st_mode&0o777) if prefs.exists() else None
key='NSWindow Frame AndroidApp.'+hashlib.sha256((args.serial+':'+package).encode()).hexdigest()
try:geometry=run('defaults','read',metadata['CFBundleIdentifier'],key).strip()
except subprocess.CalledProcessError:geometry=None
initial=set(logs.glob('*.jsonl'));baseline=resources();child=None;
def panel():
 text=android('shell','cmd','display','get-displays');line=next(l for l in text.splitlines() if l.startswith('Display id 0:'));return re.search(r'\bstate ([A-Z_]+)',line).group(1)
original_panel=panel();assert original_panel in ('ON','OFF');api=int(android('shell','getprop','ro.build.version.sdk').strip())
def set_panel(wanted):
 if wanted=='OFF':android('shell','cmd','display','power-off','0')
 elif api>=37:
  android('shell','cmd','display','power-reset','0')
  if panel()!='ON':android('shell','cmd','power','wakeup','--display-id','0')
 else:android('shell','cmd','display','power-on','0')
 wait('physical panel '+wanted,lambda:panel()==wanted,10)
def global_settings():return {key:android('shell','settings','get',scope,key) for scope,key in [('secure','show_ime_with_hard_keyboard'),('secure','default_input_method'),('secure','enabled_input_methods'),('global','stay_on_while_plugged_in'),('system','screen_off_timeout')]}
settings_before=global_settings();(out/'settings-before.json').write_text(json.dumps(settings_before,indent=2)+'\n')
number=0;session=None;report={'passed':False,'version':metadata['CFBundleShortVersionString'],'build':metadata['CFBundleVersion'],'policy':args.policy,'decorations':args.decorations,'installed_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'physical_focus_verified':False,'before':baseline}
spec=importlib.util.spec_from_file_location('hidden_oracle',repo/'scripts/verify-hidden-ime-state.py');oracle=importlib.util.module_from_spec(spec);spec.loader.exec_module(oracle)
def command(action,**kw):
 global number
 number+=1;receipt=out/f'receipt-{number}.json';receipt.unlink(missing_ok=True);temp=out/'command.tmp';temp.write_text(json.dumps(dict(id=number,action=action,**kw)));temp.replace(out/'command.json')
 wait('receipt '+action,receipt.exists,15);result=json.loads(receipt.read_text());assert result['passed'],result;return result
def events():
 result=[]
 for f in set(logs.glob('*.jsonl'))-initial:
  for line in f.read_text().splitlines():
   try:e=json.loads(line)
   except json.JSONDecodeError:continue
   if e.get('device')==args.serial and e.get('package')==package and e.get('backend')=='native':result.append(e)
 return result
try:
 pref_value=json.loads(prior_prefs[0]) if prior_prefs else {};pref_value['showAndroidSystemDecorations']=args.decorations=='on';pref_value['screenOffDeviceSerials']=[s for s in pref_value.get('screenOffDeviceSerials',[]) if s!=args.serial]
 pref_temp=prefs.with_suffix('.qa-'+str(os.getpid()));pref_temp.write_text(json.dumps(pref_value));pref_temp.chmod(prior_prefs[1] if prior_prefs else 0o600);pref_temp.replace(prefs)
 ocr=repo/'.build/qa-hidden-ime-ocr';ocr_source=repo/'verification/hidden-ime/qa/recognize-frame.swift'
 if not ocr.exists() or ocr.stat().st_mtime<ocr_source.stat().st_mtime:run('swiftc',ocr_source,'-o',ocr)
 shim=repo/'.build/hidden-ime-native-actions.dylib';run('clang','-dynamiclib','-fobjc-arc','-framework','AppKit',repo/'verification/hidden-ime/qa/native-actions.m','-o',shim)
 android('shell','am','force-stop',package);android('logcat','-c')
 env=os.environ.copy();env.update(PATH='/usr/bin:/bin',DYLD_INSERT_LIBRARIES=str(shim),DROIDBRIDGE_LAUNCHER_QA_ROOT=str(out))
 with (out/'host.log').open('w') as log:
  child=subprocess.Popen([str(binary),'--wrapper','--serial',args.serial,'--launch',package,'--backend','native','--name','Hidden IME QA'],env=env,stdout=log,stderr=log)
  running=wait('real native decoded frame',lambda:next((e for e in events() if e.get('state')=='running'),None),45);session=running['session']
  receipt=wait('native host',lambda:next((e for e in events() if e.get('session')==session and e.get('event')=='loading_window_presented'),None))
  window=int(receipt['details']['window_number']);session_log=logs/f'session-{session}.log'
  display=int(wait('display-specific launch',lambda:(m.group(1) if (m:=re.search(r'Starting app .* on display (\d+)',session_log.read_text())) else None)))
  argv=run('/bin/ps','-ww','-axo','pid=,command=')
  server_lines=[l for l in argv.splitlines() if 'app_process / com.genymobile.scrcpy.Server' in l and f' -s {args.serial} ' in l]
  (out/'processes.txt').write_text('\n'.join(server_lines)+'\n')
  assert any(f'display_ime_policy={args.policy}' in l and f'vd_system_decorations={str(args.decorations=="on").lower()}' in l for l in server_lines),server_lines
  command('resize',window=window,width=480,height=720);time.sleep(2)
  snapshots=[];phases=[]
  for phase in (['positive-local'] if args.policy=='local' else ['panel-on','panel-off','resized-panel-off']):
   set_panel('OFF' if 'off' in phase else 'ON')
   if phase=='resized-panel-off':command('resize',window=window,width=600,height=900);time.sleep(2)
   display_dump=android('shell','dumpsys','window','displays')
   block=next(block for match,block in oracle.chunks(display_dump,r'^\s{0,4}Display: mDisplayId=(\d+)\b') if int(match.group(1))==display)
   width,height=map(int,re.search(r'\bcur=(\d+)x(\d+)',block).groups())
   frame_samples=[]
   def rendered_ready():
    command('capture',window=window,filename=phase+'-before-input.png');facts=json.loads(run(ocr,out/(phase+'-before-input.png')));frame_samples.append(facts)
    return facts if len(frame_samples)>=2 and all(f.get('dimensions')==[width,height] and f.get('editorPoint') for f in frame_samples[-2:]) else None
   frame=wait('actual rendered dimensions and editor geometry stable',rendered_ready,25);(out/(phase+'-frame-wait.json')).write_text(json.dumps(frame_samples,indent=2)+'\n')
   word='HiddenIme'+phase.replace('-','')
   command('input',window=window,**frame['editorPoint'])
   command('raw_key',window=window,keycode=0,characters='a',command=True)
   command('raw_key',window=window,keycode=0,characters=word)
   text=wait('Mac text reached exact display',lambda:(t if f'text={word} display={display}' in (t:=android('logcat','-d','-s','DroidBridgeProbe:I','*:S')) else None),15)
   short_marker=f'text={word[:-1]} display={display}';full_marker=f'text={word} display={display}'
   prior_short=text.count(short_marker);prior_full=text.count(full_marker)
   command('raw_key',window=window,keycode=51,characters='\x7f')
   wait('NEW Mac raw Backspace receipt on exact display',lambda:android('logcat','-d','-s','DroidBridgeProbe:I','*:S').count(short_marker)>prior_short,15)
   command('raw_key',window=window,keycode=0,characters=word[-1])
   text=wait('NEW Mac text restored receipt',lambda:(t if (t:=android('logcat','-d','-s','DroidBridgeProbe:I','*:S')).count(full_marker)>prior_full else None),15);(out/(phase+'-input.log')).write_text(text)
   paste='Paste'+phase.replace('-','');command('paste',window=window,text=paste)
   text=wait('Mac CmdV paste reached exact display',lambda:(t if f'text={word+paste} display={display}' in (t:=android('logcat','-d','-s','DroidBridgeProbe:I','*:S')) else None),15);(out/(phase+'-paste-input.log')).write_text(text)
   phase_samples=[]
   for index in range(8):
    displays=android('shell','dumpsys','window','displays');windows=android('shell','dumpsys','window','windows');ime=android('shell','dumpsys','input_method')
    (out/f'{phase}-{index}-displays.txt').write_text(displays);(out/f'{phase}-{index}-windows.txt').write_text(windows);(out/f'{phase}-{index}-input-method.txt').write_text(ime)
    try:state_result=oracle.inspect(displays,windows,{display:package})
    except ValueError as error:state_result={'passed':False,'reason':str(error)}
    phase_samples.append(state_result);time.sleep(.12)
   snapshots.extend(phase_samples);command('capture',window=window,filename=phase+'-editing.png')
   assert panel()==('OFF' if 'off' in phase else 'ON')
   phases.append(dict(phase=phase,text=True,rawBackspace=True,clipboardPaste=True,display=display,dimensions=[width,height],samples=len(phase_samples)))
  if args.policy=='local':assert any(not item['passed'] and ('Visible IME inset' in item['reason'] or 'IME surface/presentation' in item['reason']) for item in snapshots),'LOCAL did not show a software keyboard; positive control not established'
  else:assert all(item['passed'] for item in snapshots),snapshots
  command('restore_pasteboard');report['macPasteboardAllFlavorsRestored']=True
  command('quit');child.wait(timeout=35);assert child.returncode==0
  wait('exact resource baseline',lambda:resources()==baseline,25)
  report.update(passed=True,display=display,session=session,snapshots=snapshots,phases=phases,text_delivery=True,raw_backspace_delivery=True,clipboard_paste_delivery=True,positive_local_keyboard_observed=args.policy=='local',sampled_hide_check=args.policy=='hide')
except Exception as error:
 report['failure']=str(error)
 for name,args_ in [('displays',['shell','dumpsys','window','displays']),('windows',['shell','dumpsys','window','windows']),('input-method',['shell','dumpsys','input_method']),('input-log',['logcat','-d','-s','DroidBridgeProbe:I','*:S'])]:
  try:(out/('failed-'+name+'.txt')).write_text(android(*args_))
  except Exception:pass
 if child and child.poll() is None:
  try:command('capture',window=window,filename='failed-frame.png')
  except Exception:pass
 raise
finally:
 if child and child.poll() is None:
  try:command('quit')
  except Exception:child.terminate()
  try:child.wait(timeout=35)
  except subprocess.TimeoutExpired:child.kill();child.wait(timeout=5)
 if prior_prefs:prefs.write_bytes(prior_prefs[0]);prefs.chmod(prior_prefs[1])
 else:prefs.unlink(missing_ok=True)
 if prior:state.write_bytes(prior[0]);state.chmod(prior[1])
 else:state.unlink(missing_ok=True)
 if geometry is None:subprocess.run(['defaults','delete',metadata['CFBundleIdentifier'],key],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 else:run('defaults','write',metadata['CFBundleIdentifier'],key,'-string',geometry)
 for f in set(logs.glob('*.jsonl'))-initial:
  (out/f.name).write_bytes(f.read_bytes());raw=f.with_suffix('')
  if raw.exists():(out/raw.name).write_bytes(raw.read_bytes())
 set_panel(original_panel);settings_after=global_settings();assert settings_after==settings_before;report['globalSettingsUnchanged']=True;(out/'settings-after.json').write_text(json.dumps(settings_after,indent=2)+'\n')
 wait('final exact resource baseline',lambda:resources()==baseline,25);report['after']=resources();(out/'result.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
