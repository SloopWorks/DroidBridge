import pathlib,subprocess,xml.etree.ElementTree as E,time,re,json,socket,os
root=pathlib.Path(__file__).resolve().parent;manifest=json.loads((root/'candidate.json').read_text());adb=str(pathlib.Path(manifest['app_path'])/'Contents/Resources/Runtime/bin/adb');A=[adb,'-s','emulator-5580']
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
 raise RuntimeError('Missing Android control '+text)
run('shell','am','start','-W','-a','android.settings.APPLICATION_DEVELOPMENT_SETTINGS')
for _ in range(12):
 ns=nodes()
 if any(n.get('text')=='Use wireless debugging' for n in ns):break
 n=next((n for n in ns if n.get('text')=='Wireless debugging'),None)
 if n is not None:tap(n);break
 run('shell','input','swipe','540','1640','540','760','350')
else:raise RuntimeError('Wireless debugging entry absent')
click('Use wireless debugging');click('ALLOW',optional=True)
ns=nodes();connect=next((n.get('text') for n in ns if re.fullmatch(r'10\.0\.2\.16:\d+',n.get('text',''))),None);assert connect,'Wireless TLS listener missing';connectport=int(connect.rsplit(':',1)[1]);click('Pair device with pairing code')
ns=nodes();text='\n'.join(n.get('text','') for n in ns);code=re.search(r'(?m)^\d{6}$',text).group();pairport=int(re.search(r'10\.0\.2\.16:(\d+)',text).group(1))
ports=[]
for guest in [pairport,connectport]:
 s=socket.socket();s.bind(('127.0.0.1',0));port=s.getsockname()[1];s.close();run('emu','redir','add',f'tcp:{port}:{guest}');ports.append(port)
(root/'wireless-owned.json').write_text(json.dumps({'serial':'127.0.0.1:'+str(ports[1]),'host_ports':ports,'guest_ports':[pairport,connectport]}));os.chmod(root/'wireless-owned.json',0o600)
p=subprocess.run([adb,'pair','127.0.0.1:'+str(ports[0])],input=code+'\n',text=True,capture_output=True,timeout=25);assert p.returncode==0 and 'Successfully paired' in p.stdout,'Actual TLS pair failed'
p=subprocess.run([adb,'connect','127.0.0.1:'+str(ports[1])],text=True,capture_output=True,timeout=25);assert p.returncode==0 and 'connected to' in p.stdout,'Actual TLS connect failed'
usb=run('shell','getprop','ro.serialno').strip();w=subprocess.run([adb,'-s','127.0.0.1:'+str(ports[1]),'shell','getprop','ro.serialno'],capture_output=True,text=True,check=True,timeout=10).stdout.strip();assert usb==w
run('shell','am','start','-W','-n','dev.droidbridge.companion/.MainActivity');click('Start connection service');click('CONTINUE',optional=True);click('Allow',optional=True)
print('PASS actual Android adbd TLS pairing/connect; companion service started with phone consent. No code logged.')
