#!/usr/bin/env python3
"""Drive the compiled actual alias runtime harness in one private owned QA root.

Requires the coordinated exclusive emulator-5580 handoff, wireless-owned.json
from actual Android TLS pairing, and `runtime` built from the sibling Swift
harness. Does not relax shipping authentication or touch other devices.
"""
import subprocess,pathlib,os,time,re,json,sys,stat,shutil,xml.etree.ElementTree as E
root=pathlib.Path(sys.argv[1]).resolve(strict=True)
assert root.stat().st_uid==os.getuid() and stat.S_IMODE(root.stat().st_mode)==0o700

candidate=json.loads((root/'candidate.json').read_text());tools=pathlib.Path(candidate['app_path'])/'Contents/Resources/Runtime';A=[str(tools/'bin/adb'),'-s','emulator-5580']
def adb(*p,binary=False):
 r=subprocess.run(A+list(p),capture_output=True,check=True,timeout=25);return r.stdout if binary else r.stdout.decode()
def nodes():
 adb('shell','uiautomator','dump','/sdcard/droidbridge-final5-systems.xml');return list(E.fromstring(adb('shell','cat','/sdcard/droidbridge-final5-systems.xml')).iter('node'))
def click(text):
 for _ in range(8):
  for n in nodes():
   if n.get('text','').casefold()==text.casefold() and n.get('clickable')=='true':
    a=list(map(int,re.findall(r'\d+',n.get('bounds'))));adb('shell','input','tap',str((a[0]+a[2])//2),str((a[1]+a[3])//2));return
  time.sleep(.2)
 raise RuntimeError('Missing actual phone control '+text)
def start_companion():
 adb('shell','am','start','-W','-n','dev.droidbridge.companion/.MainActivity')
 ns=nodes()
 if any(n.get('text','')=='Start connection service' for n in ns):click('Start connection service')
 for text in ['Continue','Allow']:
  if any(n.get('text','').casefold()==text.casefold() for n in nodes()):click(text)
def display_ids():return sorted(set(re.findall(r'mDisplayId=(\d+)',adb('shell','dumpsys','display'))))
for marker in ['engine-pending.json','crash-ready','private-link','recovery-restart-request','recovery-phone-proof-request','recovery-phone-proof.json']:(root/marker).unlink(missing_ok=True)
before=display_ids();log=(root/'runtime.log').open('wb');env=os.environ.copy();env['DROIDBRIDGE_ADB']=str(tools/'bin/adb');env['DROIDBRIDGE_SUPERVISOR']=str(tools/'bin/DroidBridgeSupervisor')
p=subprocess.Popen([str(root/'runtime'),'--companion-qa-root',str(root),'--serial','emulator-5580','--companion-recovery'],env=env,stdout=log,stderr=subprocess.STDOUT)
(root/'runtime.pid').write_text(str(p.pid));reader=root/'read-private-qr.swift';qr=root/'private-qr.png';link=root/'private-link'
try:
 start_companion();click('Pair a new Mac');time.sleep(.4)
 reader.write_text('''import Foundation
import Vision
let r=VNDetectBarcodesRequest();r.symbologies=[.qr]
try VNImageRequestHandler(url:URL(fileURLWithPath:CommandLine.arguments[1])).perform([r])
guard let link=r.results?.compactMap({$0.payloadStringValue}).first(where:{$0.hasPrefix("droidbridge://pair?")}) else {exit(2)}
try Data(link.utf8).write(to:URL(fileURLWithPath:CommandLine.arguments[2]),options:.atomic)
''');os.chmod(reader,0o600)
 for _ in range(5):
  qr.write_bytes(adb('exec-out','screencap','-p',binary=True));os.chmod(qr,0o600)
  r=subprocess.run(['/usr/bin/swift',str(reader),str(qr),str(link)],capture_output=True,timeout=30)
  if r.returncode==0:break
  time.sleep(.3)
 else:raise RuntimeError('Actual QR was unreadable')
 if link.exists():os.chmod(link,0o600)
 pending=root/'engine-pending.json';deadline=time.monotonic()+20
 while not pending.exists():
  if p.poll() is not None:raise RuntimeError('Runtime stopped before pair request')
  if time.monotonic()>deadline:raise RuntimeError('No real pair request')
  time.sleep(.1)
 code=json.loads(pending.read_text())['comparison_code'];deadline=time.monotonic()+15
 while code not in '\n'.join(n.get('text','') for n in nodes()):
  if time.monotonic()>deadline:raise RuntimeError('Comparison code mismatch')
  time.sleep(.1)
 click('Trust Mac');print('Actual phone comparison matched and Trust Mac approved',flush=True)
 # QR dialog may cover the real Settings virtual display; dismiss only phone UI.
 adb('shell','input','keyevent','4')
 samples=[];deadline=time.monotonic()+210;service_restarted=False;phone_proven=False
 while p.poll() is None:
  if time.monotonic()>deadline:raise RuntimeError('Finite runtime deadline exceeded')
  if (root/'recovery-restart-request').exists() and not service_restarted:
   start_companion();service_restarted=True;print('Owned Android companion restarted through its explicit service button',flush=True)
  if (root/'recovery-phone-proof-request').exists() and not phone_proven:
   ns=nodes();labels=[n for n in ns if n.get('text','').startswith('Recovery native verification ·')];connected=any(n.get('text','').startswith('Connected to ') for n in ns)
   if len(labels)==1 and connected:
    (root/'recovery-phone-proof.json').write_text(json.dumps({'session_label_count':len(labels),'connected':True}));phone_proven=True;print('Phone UI confirmed exactly one recovered running session',flush=True)
  observation=subprocess.run(['/bin/ps','-p',str(p.pid),'-o','%cpu=,rss='],capture_output=True,text=True)
  if observation.returncode==0:
   values=observation.stdout.split()
   if len(values)==2:samples.append({'monotonic':time.monotonic(),'cpu_percent':float(values[0]),'rss_kib':int(values[1])})
  time.sleep(.5)
 status=p.wait(timeout=1);log.flush();assert status==0,'Runtime harness failed; inspect private runtime.log'
 (root/'resource-samples.json').write_text(json.dumps({'samples':samples,'not_a_quiet_performance_benchmark':True},indent=2)+'\n')
 time.sleep(.5);after=display_ids();assert before==after,'Android display leak after actual teardown'
 report=root/'recovery-report.json';v=json.loads(report.read_text());v['android_display_ids_before']=before;v['android_display_ids_after']=after;v['no_android_display_leak']=True;report.write_text(json.dumps(v,indent=2,sort_keys=True)+'\n');print('PASS actual runtime and Android display cleanup')
finally:
 if p.poll() is None:
  p.terminate()
  try:p.wait(timeout=6)
  except subprocess.TimeoutExpired:p.kill();p.wait(timeout=3)
 for f in [reader,qr,link]:f.unlink(missing_ok=True)
 log.close()
