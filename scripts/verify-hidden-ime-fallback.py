#!/usr/bin/env python3
"""Installed fallback host + unchanged bundled Player, public Cocoa input.

Coordinate exclusive emulator/prefs ownership before running. Recording adds only
--record to the production-generated client argv. Cocoa events prove the client
input path, not OS focus under a locked desktop. IME checks are sampled, never a
claim of mathematical continuous invisibility. No global Android settings change.
"""
import argparse,fcntl,hashlib,importlib.util,json,os,pathlib,plistlib,re,shutil,subprocess,time,uuid
repo=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--app',type=pathlib.Path,default=pathlib.Path.home()/'Applications/DroidBridge.app')
p.add_argument('--serial',choices=['emulator-5580','emulator-5582'],default='emulator-5580')
p.add_argument('--output',type=pathlib.Path,required=True)
p.add_argument('--version',default='0.1.7');p.add_argument('--build',default='12')
p.add_argument('--diagnostic-no-mouse-hover',action='store_true',help='Test-only mitigation control; never final acceptance');p.add_argument('--input-method',choices=['cocoa','sdl'],default='cocoa');p.add_argument('--decorations',choices=['both','on','off'],default='both');args=p.parse_args()
app=args.app.resolve();out=args.output.resolve()
assert not out.exists() or not any(out.iterdir()),'Use a fresh evidence directory; prior commands/results must not be replayed or overwritten'
out.mkdir(parents=True,exist_ok=True)
info=plistlib.loads((app/'Contents/Info.plist').read_bytes());assert info['CFBundleShortVersionString']==args.version and info['CFBundleVersion']==args.build,info
runtime=app/'Contents/Resources/Runtime';adb=runtime/'bin/adb';binary=app/'Contents/MacOS/DroidBridge';player=runtime/'Player.app/Contents/MacOS/scrcpy';package='dev.droidbridge.testapp';logs=pathlib.Path.home()/'Library/Logs/DroidBridge'
def run(*cmd,timeout=20):return subprocess.check_output(list(map(str,cmd)),text=True,stderr=subprocess.STDOUT,timeout=timeout)
def android(*cmd):return run(adb,'-s',args.serial,*cmd)
def wait(label,predicate,seconds=30):
 end=time.monotonic()+seconds
 while time.monotonic()<end:
  result=predicate()
  if result:return result
  time.sleep(.12)
 raise AssertionError('Timeout '+label)
def resources():return {'displays':android('shell','cmd','display','get-displays').count('Display id '),'forwards':[line for line in run(adb,'forward','--list').splitlines() if line.startswith(args.serial+' ')],'reverses':android('reverse','--list')}
def android_settings():
 return {namespace+'.'+key:android('shell','settings','get',namespace,key).strip() for namespace,key in [('secure','show_ime_with_hard_keyboard'),('secure','default_input_method'),('secure','enabled_input_methods'),('global','stay_on_while_plugged_in'),('system','screen_off_timeout')]}
def physical():
 value=android('shell','cmd','display','get-displays');match=re.search(r'^Display id 0: .*?\bstate (ON|OFF)\b',value,re.M)
 assert match,'Unknown physical state';return match[1]
def snapshot_file(path):return (path.read_bytes(),path.stat().st_mode&0o777) if path.exists() else None
def restore_file(path,prior):
 if prior:
  temp=path.with_name(path.name+'.restore-'+uuid.uuid4().hex);temp.write_bytes(prior[0]);temp.chmod(prior[1]);temp.replace(path)
 else:path.unlink(missing_ok=True)
support=pathlib.Path.home()/'Library/Application Support/DroidBridge';prefs=support/'preferences.json';state=support/('sessions-'+info['CFBundleIdentifier']+'.json');prior_prefs=snapshot_file(prefs);prior_state=snapshot_file(state)
geometry_key='NSWindow Frame AndroidApp.'+hashlib.sha256((args.serial+':'+package).encode()).hexdigest()
try:prior_geometry=run('defaults','read',info['CFBundleIdentifier'],geometry_key).strip()
except subprocess.CalledProcessError:prior_geometry=None
initial=set(logs.glob('*.jsonl'));baseline=resources();android_api=int(android('shell','getprop','ro.build.version.sdk').strip());baseline_settings=android_settings();baseline_health={'system_server_pid':android('shell','pidof','system_server').strip(),'uptime':android('shell','cat','/proc/uptime').strip(),'boot_complete':android('shell','getprop','sys.boot_completed').strip()};baseline_panel=physical();child=None;report={'passed':False,'version':args.version,'build':args.build,'serial':args.serial,'android_api':android_api,'host_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'player_sha256':hashlib.sha256(player.read_bytes()).hexdigest(),'physical_focus_verified':False,'input_path':args.input_method,'diagnostic_no_mouse_hover':args.diagnostic_no_mouse_hover,'acceptance':not args.diagnostic_no_mouse_hover,'test_record_flag_added':True,'cases':[],'before':baseline,'before_android_settings':baseline_settings,'before_health':baseline_health};case=None;counter=0;session=None
spec=importlib.util.spec_from_file_location('ime_oracle',repo/'scripts/verify-hidden-ime-state.py');oracle=importlib.util.module_from_spec(spec);spec.loader.exec_module(oracle)
def preference_change(decorations):
 support.mkdir(parents=True,exist_ok=True)
 with prefs.with_suffix('.json.lock').open('a') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX)
  value=json.loads(prefs.read_text()) if prefs.exists() else {};value['showAndroidSystemDecorations']=decorations
  temp=prefs.with_suffix('.fallback-test.tmp');temp.write_text(json.dumps(value));temp.chmod(0o600);temp.replace(prefs)
def command(role,action,**kw):
 global counter
 counter+=1;receipt=case/f'{role}-receipt-{counter}.json';receipt.unlink(missing_ok=True);temp=case/f'{role}-command.tmp';temp.write_text(json.dumps(dict(id=counter,action=action,**kw)));temp.replace(case/f'{role}-command.json')
 wait(role+' '+action+' receipt',receipt.exists,15);result=json.loads(receipt.read_text());assert result['passed'],result;return result
def events():
 records=[]
 for path in set(logs.glob('*.jsonl'))-initial:
  for line in path.read_text().splitlines():
   try:value=json.loads(line)
   except json.JSONDecodeError:continue
   if value.get('device')==args.serial and value.get('package')==package and value.get('backend')=='scrcpy':records.append(value)
 return records
def input_log():return android('logcat','-d','-s','DroidBridgeProbe:I','*:S')
def wait_text(display,word):
 def received():
  text=input_log()
  return text if any(word in line and f' display={display}' in line for line in text.splitlines()) else None
 text=wait('display-specific text '+word,received,15)
 (case/'input.log').write_text(text);return text

def samples(display,label,count=4):
 result=[]
 for index in range(count):
  displays=android('shell','dumpsys','window','displays');windows=android('shell','dumpsys','window','windows')
  prefix=case/f'{label}-{index}';prefix.with_suffix('.displays.txt').write_text(displays);prefix.with_suffix('.windows.txt').write_text(windows);prefix.with_suffix('.input-method.txt').write_text(android('shell','dumpsys','input_method'))
  value=oracle.inspect(displays,windows,{display:package});result.append(value);time.sleep(.15)
 return result

def frame_size(log):
 text=re.sub(r'\x1b\][^\x07]*(?:\x07|\x1b\\)','',log.read_text());sizes=re.findall(r'^INFO: Texture(?: \(VideoToolbox\))?: (\d+)x(\d+)$',text,re.M);assert sizes,text;return tuple(map(int,sizes[-1]))
def edit(display,log,label):
 width,height=frame_size(log)
 before=sum('click=' in line and f'display={display}' in line for line in input_log().splitlines())
 command('player','click',x=300/width,y=225/height)
 wait('new counter click on exact display',lambda:sum('click=' in line and f'display={display}' in line for line in input_log().splitlines())>before,10)
 command('player','click',x=300/width,y=295/height);time.sleep(.5)
 word='1'+label+'Text';command('player','text',text=word);wait_text(display,word)
 command('player','raw_key',characters='k',keycode=40);wait_text(display,word+'k')
 pasted='Paste'+label;command('player','paste',text=pasted);wait_text(display,word+'k'+pasted);restored_clipboard=command('player','restore_clipboard')
 command('player','capture',filename=label+'.png')
 return {'word':word,'raw_key_suffix':'k','paste':pasted,'clipboard_restored':restored_clipboard['passed'],'frame_size':[width,height],'samples':samples(display,label)}

try:
 shim=repo/'.build/hidden-ime-fallback-actions.dylib';run('clang','-dynamiclib','-fobjc-arc','-framework','AppKit','-I/opt/homebrew/include',repo/'scripts/verify-hidden-ime-fallback.m','-o',shim)
 injected=str(shim)
 if args.input_method=='sdl':
  pump=repo/'.build/hidden-ime-fallback-sdl.dylib';run('clang','-dynamiclib','-I/opt/homebrew/include',repo/'scripts/verify-hidden-ime-fallback-sdl.c',runtime/'lib/libSDL3.0.dylib','-Wl,-rpath,'+str(runtime/'lib'),'-Wl,-headerpad_max_install_names','-o',pump);run('install_name_tool','-change','@loader_path/libSDL3.0.dylib',runtime/'lib/libSDL3.0.dylib',pump);run('codesign','--force','--sign','-',pump);injected+=':'+str(pump)
 choices=[True,False] if args.decorations=='both' else [args.decorations=='on']
 for decorations in choices:
  case=out/('decorations-on' if decorations else 'decorations-off');case.mkdir(exist_ok=True);print('START decorations='+str(decorations)+' input='+args.input_method,flush=True)
  preference_change(decorations);android('shell','am','force-stop',package);android('logcat','-c')
  proxy=case/'record-player';proxy.write_text('#!/usr/bin/python3\nimport json,os,pathlib,sys\nreal='+repr(str(player))+'\nargs=sys.argv[1:]\nif any(arg.startswith("--start-app=") for arg in args):\n pathlib.Path('+repr(str(case/'production-argv.json'))+').write_text(json.dumps(args,indent=2))\n args.append('+repr('--record='+str(case/'player.mkv'))+')\n'+(' args.append("--no-mouse-hover")\n' if args.diagnostic_no_mouse_hover else '')+' pathlib.Path('+repr(str(case/'launched-argv.json'))+').write_text(json.dumps(args,indent=2))\nenv=os.environ.copy();env.pop("DYLD_INSERT_LIBRARIES",None)\nif any(arg.startswith("--start-app=") for arg in args):env["DYLD_INSERT_LIBRARIES"]='+repr(injected)+'\nos.execve(real,[real,*args],env)\n');proxy.chmod(0o755)
  env=os.environ.copy();env.update(PATH='/usr/bin:/bin',DYLD_INSERT_LIBRARIES=str(shim),DROIDBRIDGE_HIDDEN_IME_QA=str(case),DROIDBRIDGE_HIDDEN_INPUT=args.input_method,DROIDBRIDGE_SCRCPY=str(proxy),DROIDBRIDGE_ADB=str(adb),DROIDBRIDGE_SERVER=str(runtime/'share/scrcpy/scrcpy-server'),DROIDBRIDGE_SUPERVISOR=str(runtime/'bin/DroidBridgeSupervisor'))
  initial_session_ids={event.get('session') for event in events()}
  with (case/'host.log').open('w') as output:
   child=subprocess.Popen([str(binary),'--wrapper','--launch',package,'--serial',args.serial,'--backend','scrcpy'],env=env,stdout=output,stderr=output)
   event=wait('fallback app and actual renderer',lambda:next((event for event in events() if event.get('state')=='running' and event.get('session') not in initial_session_ids),None),50);session=event['session'];log=logs/f'session-{session}.log'
   launched=re.search(r'Starting app .*?\['+re.escape(package)+r'\] on display (\d+)\.\.\.',log.read_text());assert launched;display=int(launched[1])
   production=json.loads((case/'production-argv.json').read_text());launched_args=json.loads((case/'launched-argv.json').read_text());assert '--display-ime-policy=hide' in production,production;assert ('--no-vd-system-decorations' not in production)==decorations
   assert launched_args[:len(production)]==production,'Test proxy changed production arguments'
   expected_extra=['--record='+str(case/'player.mkv')]+(['--no-mouse-hover'] if args.diagnostic_no_mouse_hover else [])
   assert launched_args[len(production):]==expected_extra,'Unexpected test proxy additions'
   if args.diagnostic_no_mouse_hover:assert '--no-mouse-hover' not in production and '--no-mouse-hover' in launched_args
   else:assert ('--no-mouse-hover' in production)==(android_api==35),'Production hover policy does not match exact Android version'
   player_status=command('player','status');command('player','resize',width=720,height=1080);time.sleep(3)
   command('host','menu',title='Turn Phone Screen On');wait('panel ON',lambda:physical()=='ON',20)
   on=edit(display,log,'PanelOn');print('PASS panel ON editing',flush=True)
   command('host','menu',title='Turn Phone Screen Off');wait('panel OFF',lambda:physical()=='OFF',20);time.sleep(3)
   off=edit(display,log,'PanelOff');assert physical()=='OFF';print('PASS panel OFF editing',flush=True)
   command('player','resize',width=900,height=1200);time.sleep(3)
   resized=edit(display,log,'ResizedOff');assert physical()=='OFF';print('PASS resized OFF editing',flush=True)
   command('host','menu',title='Turn Phone Screen On' if baseline_panel=='ON' else 'Turn Phone Screen Off');wait('original panel state',lambda:physical()==baseline_panel,20)
   command('host','quit');child.wait(timeout=35);assert child.returncode==0;child=None
   wait('exact display/tunnel cleanup',lambda:resources()==baseline,25)
   ffmpeg=shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
   hashes=[]
   for index,second in enumerate([2,5]):
    image=case/f'recorded-frame-{index}.png';run(ffmpeg,'-y','-ss',str(second),'-i',case/'player.mkv','-frames:v','1',image);hashes.append(hashlib.sha256(image.read_bytes()).hexdigest())
   assert len(set(hashes))==2,'Real recorded frames did not change'
   report['cases'].append({'decorations':decorations,'session':session,'display':display,'player_pid':player_status['pid'],'production_no_mouse_hover':'--no-mouse-hover' in production,'on':on,'off':off,'resized_off':resized,'recorded_frame_sha256':hashes,'exact_cleanup':True})
 assert hashlib.sha256(player.read_bytes()).hexdigest()==report['player_sha256'],'Installed Player bytes changed'
 report['passed']=True
except Exception as error:
 report['failure']=str(error)
 raise
finally:
 if child and child.poll() is None:
  try:command('player','restore_clipboard')
  except Exception:pass
  try:
   command('host','menu',title='Turn Phone Screen On' if baseline_panel=='ON' else 'Turn Phone Screen Off');wait('restore panel',lambda:physical()==baseline_panel,20)
   command('host','quit')
  except Exception:child.terminate()
  try:child.wait(timeout=35)
  except subprocess.TimeoutExpired:child.kill();child.wait(timeout=5)
 restore_file(state,prior_state)
 with prefs.with_suffix('.json.lock').open('a') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX);restore_file(prefs,prior_prefs)
 if prior_geometry is None:subprocess.run(['defaults','delete',info['CFBundleIdentifier'],geometry_key],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 else:run('defaults','write',info['CFBundleIdentifier'],geometry_key,'-string',prior_geometry)
 for path in set(logs.glob('*.jsonl'))-initial:
  (out/path.name).write_bytes(path.read_bytes());raw=path.with_suffix('')
  if raw.exists():(out/raw.name).write_bytes(raw.read_bytes())
 try:wait('final exact resources',lambda:resources()==baseline,25);report['after']=resources()
 except Exception as error:report['cleanup_error']=str(error);report['passed']=False
 try:
  report['after_host_sha256']=hashlib.sha256(binary.read_bytes()).hexdigest();report['after_player_sha256']=hashlib.sha256(player.read_bytes()).hexdigest()
  if report['after_host_sha256']!=report['host_sha256'] or report['after_player_sha256']!=report['player_sha256']:report['installed_bytes_changed']=True;report['passed']=False
  report['after_health']={'system_server_pid':android('shell','pidof','system_server').strip(),'uptime':android('shell','cat','/proc/uptime').strip(),'boot_complete':android('shell','getprop','sys.boot_completed').strip()}
  if report['after_health']['system_server_pid']!=baseline_health['system_server_pid']:report['android_system_server_restarted']=True;report['passed']=False
  report['preferences_restored']=snapshot_file(prefs)==prior_prefs;report['session_intents_restored']=snapshot_file(state)==prior_state
  if not report['preferences_restored'] or not report['session_intents_restored']:report['passed']=False
  (out/'android-system-tail.txt').write_text(android('logcat','-b','system','-d','-t','500'));(out/'android-crash-buffer.txt').write_text(android('logcat','-b','crash','-d','-t','300'))
  report['after_android_settings']=android_settings()
  if report['after_android_settings']!=baseline_settings:report['settings_changed']=True;report['passed']=False
  if case:(case/'final-input.log').write_text(input_log())
 except Exception as error:report['final_snapshot_error']=str(error);report['passed']=False
 (out/'result.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
assert report['passed'],report
