import pathlib,subprocess,xml.etree.ElementTree as E,time,re,json
root=pathlib.Path(__file__).resolve().parent;c=json.loads((root/'candidate.json').read_text());adb=str(pathlib.Path(c['app_path'])/'Contents/Resources/Runtime/bin/adb');A=[adb,'-s','emulator-5580']
def run(*args):return subprocess.run(A+list(args),capture_output=True,text=True,check=True,timeout=25).stdout
def nodes():
 run('shell','uiautomator','dump','/sdcard/droidbridge-final5-systems.xml');return list(E.fromstring(run('shell','cat','/sdcard/droidbridge-final5-systems.xml')).iter('node'))
def tap(n):
 a=list(map(int,re.findall(r'\d+',n.get('bounds',''))));run('shell','input','tap',str((a[0]+a[2])//2),str((a[1]+a[3])//2))
def click(text,optional=False):
 for _ in range(7):
  for n in nodes():
   if n.get('text','').casefold()==text.casefold():tap(n);return True
  if optional:return False
  time.sleep(.15)
 raise RuntimeError('Missing phone control '+text)
click('Cancel pairing',optional=True);click('Settings')
ns=nodes();forget=[n for n in ns if n.get('text','').startswith('Forget ') and n.get('clickable')=='true'];assert len(forget)<=1,'Cannot unambiguously remove test trust via name-only UI'
if forget:tap(forget[0]);click('Forget Mac');time.sleep(.4)
ns=nodes();assert any(n.get('text','')=='No trusted Macs. Pair from Home.' for n in ns),'Trust cleanup not reflected'
click('Home');click('Stop connection service');click('Stop service')
for _ in range(20):
 if 'ServiceRecord{' not in run('shell','dumpsys','activity','services','dev.droidbridge.companion'):break
 time.sleep(.1)
else:raise RuntimeError('Service still running')
own=json.loads((root/'wireless-owned.json').read_text());
if own['serial'].startswith('127.0.0.1:'):subprocess.run([adb,'disconnect',own['serial']],check=True,capture_output=True)
listing=run('emu','redir','list');removed=[]
for host,guest in zip(own['host_ports'],own['guest_ports']):
 if any(str(host) in line and str(guest) in line for line in listing.splitlines()):run('emu','redir','del','tcp:'+str(host));removed.append(host)
run('shell','settings','put','global','adb_wifi_enabled','0')
settings={k:run('shell','settings','get','global',k).strip() for k in ['development_settings_enabled','adb_enabled','adb_wifi_enabled']};assert settings=={'development_settings_enabled':'1','adb_enabled':'1','adb_wifi_enabled':'0'}
assert run('shell','settings','get','system','font_scale').strip()=='1.0';assert run('shell','wm','density').strip()=='Physical density: 420'
run('shell','rm','-f','/sdcard/droidbridge-final5-systems.xml')
report={'remaining_test_trust_removed_via_Forget_if_present':bool(forget),'no_other_phone_trust_present':True,'service_restored_off':True,'exact_owned_wireless_alias_disconnected':True,'exact_owned_redirects_removed':removed,'settings_preserved':settings,'font_scale_preserved':'1.0','density_preserved':420,'private_pairing_material_deleted':True}
for name in ['private-link','private-qr.png','read-private-qr.swift']:(root/name).unlink(missing_ok=True)
pathlib.Path('verification/companion/code10-recovery/cleanup.json').write_text(json.dumps(report,indent=2)+'\n');print('PASS exact failed-test trust and wireless cleanup; developer/ADB1 and serviceOFF preserved')
