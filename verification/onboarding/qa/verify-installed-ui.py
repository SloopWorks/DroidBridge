#!/usr/bin/env python3
"""Actual native controls through public AppKit actions; host remains locked.
Cancel mode uses a metadata-only COW copy to force real upgrade work. Add mode
uses the exact installed bundle, changes the decoration preference via its real
checkbox, and launches Settings via the real table selection and Launch button.
"""
import argparse,atexit,hashlib,json,os,pathlib,plistlib,shutil,subprocess,tempfile,time
p=argparse.ArgumentParser();p.add_argument('app',type=pathlib.Path);p.add_argument('--mode',choices=['cancel','add'],required=True);a=p.parse_args()
repo=pathlib.Path.cwd();out=repo/'verification/onboarding/qa'/('installed-ui-'+a.mode);out.mkdir(parents=True,exist_ok=True)
app=a.app.resolve();installed_exe=app/'Contents/MacOS/DroidBridge';support=pathlib.Path.home()/'Library/Application Support/DroidBridge';pref=support/'preferences.json';intent=support/'sessions.json';catalog=support/'ManagedApps.noindex/catalog.json';logs=pathlib.Path.home()/'Library/Logs/DroidBridge'
def run(*cmd):return subprocess.check_output(list(map(str,cmd)),text=True,stderr=subprocess.STDOUT)
saved={file:(file.read_bytes() if file.exists() else None) for file in (pref,intent)}
def restore():
 for file,data in saved.items():
  if data is None:file.unlink(missing_ok=True)
  else:file.write_bytes(data)
atexit.register(restore)
def records():return json.loads(catalog.read_text())['records']
settle_started=time.monotonic()
if a.mode=='add':
 while True:
  manifest=json.loads(catalog.read_text())
  if not manifest.get('publications') and not manifest.get('reservations'):break
  if time.monotonic()-settle_started>45:raise AssertionError('Accepted cancellation work did not settle within45seconds')
  time.sleep(.1)
settlement_seconds=round(time.monotonic()-settle_started,3)
before=records();log_before=set(logs.glob('*.jsonl'));shim=repo/'.build/qa-onboarding-actions.dylib'
subprocess.run(['clang','-dynamiclib','-fobjc-arc','-framework','AppKit',str(repo/'verification/onboarding/qa/ui-actions.m'),'-o',str(shim)],check=True)
with tempfile.TemporaryDirectory(prefix='db-qa-ui-') as td:
 td=pathlib.Path(td);host=app;normalized={}
 if a.mode=='cancel':
  host=td/'DroidBridge QA Cancellation.app';subprocess.run(['/bin/cp','-cR',str(app),str(host)],check=True)
  infofile=host/'Contents/Info.plist';info=plistlib.loads(infofile.read_bytes());info.update(CFBundleVersion='999004',CFBundleIdentifier='app.droidbridge.qa.onboarding.cancel',CFBundleName='DroidBridge QA Cancellation');infofile.write_bytes(plistlib.dumps(info))
  subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(host)],check=True)
  subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(host)],check=True)
  for name,source in [('installed',installed_exe),('metadata_clone',host/'Contents/MacOS/DroidBridge')]:
   copy=td/(name+'-unsigned');shutil.copy2(source,copy);subprocess.run(['/usr/bin/codesign','--remove-signature',str(copy)],check=True);normalized[name]=hashlib.sha256(copy.read_bytes()).hexdigest()
  assert normalized['installed']==normalized['metadata_clone']
 receipt=out/'public-control-actions.json';receipt.unlink(missing_ok=True)
 env=os.environ.copy();env['DYLD_INSERT_LIBRARIES']=str(shim);env['DROIDBRIDGE_QA_UI_MODE']=a.mode;env['DROIDBRIDGE_QA_UI_RECEIPT']=str(receipt)
 started=time.monotonic();maximum=0;samples=[];last=None
 with (out/'host.log').open('w') as logfile:
  process=subprocess.Popen([str(host/'Contents/MacOS/DroidBridge'),'--serial','emulator-5580'],env=env,stdout=logfile,stderr=logfile)
  try:
   while process.poll() is None and time.monotonic()-started<140:
    snapshot=run('/bin/ps','-axo','pid=,ppid=,command=')
    active=[]
    for row in snapshot.splitlines():
     fields=row.strip().split(None,2)
     if len(fields)==3 and int(fields[1])==process.pid and 'dev.droidbridge.icons.IconHelper' in fields[2]:active.append(int(fields[0]))
    maximum=max(maximum,len(active))
    if active!=last and len(samples)<200:samples.append({'elapsed':round(time.monotonic()-started,3),'icon_helper_pids':active});last=active
    time.sleep(.02)
   process.wait(timeout=5)
  finally:
   if process.poll() is None:process.kill();process.wait(timeout=5)
 assert process.returncode==0,process.returncode
 assert receipt.exists(),'No completed real-control receipt'
 result=json.loads(receipt.read_text());assert result['passed'],result
 after=records();assert set(before)<=set(after),'Cancellation/Onboarding lost accepted history'
 assert maximum<=2,maximum
 fresh_logs=set(logs.glob('*.jsonl'))-log_before
 if a.mode=='add':
  events=[json.loads(line) for file in fresh_logs for line in file.read_text().splitlines() if line.startswith('{')]
  own=[e for e in events if e.get('device')=='emulator-5580' and e.get('package')=='com.android.settings']
  assert any(e.get('state')=='running' for e in own),'LaunchApp did not decode a real Settings video frame'
  saved_sessions=json.loads(intent.read_text());settings=[s for s in saved_sessions if s['application']['packageName']=='com.android.settings']
  assert settings and settings[-1]['configuration']['showSystemDecorations'] is False,'Actual checkbox did not control newly launched session configuration'
  final_build=plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleVersion']
  assert all(r['sourceBuild']==final_build for r in after.values() if r['deviceSerial']=='emulator-5580'),'Final installed AddAll did not restore final build'
 for file in fresh_logs:(out/file.name).write_bytes(file.read_bytes())
 report={'passed':True,'mode':a.mode,'installed_main_sha256':hashlib.sha256(installed_exe.read_bytes()).hexdigest(),'host_exit':process.returncode,'elapsed':round(time.monotonic()-started,3),'record_count_before':len(before),'record_count_after':len(after),'max_observed_icon_helpers':maximum,'prelaunch_settlement_seconds':settlement_seconds,'normalized_unsigned_code':normalized,'control_receipt':result,'physical_mouse_or_focus_test':False}
 (out/'result.json').write_text(json.dumps(report,indent=2)+'\n');(out/'icon-helper-samples.json').write_text(json.dumps(samples,indent=2)+'\n');print(json.dumps(report,indent=2))
 if a.mode=='cancel':
  subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister','-u',str(host)],check=True)
