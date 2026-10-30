#!/usr/bin/env python3
"""Bounded, explicit no-device transport/readiness fixture for launch UX QA."""
import json,os,pathlib,socket,struct,subprocess,sys,threading,time
modepath=pathlib.Path(os.environ['DROIDBRIDGE_QA_MODE'])
if len(sys.argv)>1 and sys.argv[1]=='serve':
 ready=pathlib.Path(str(modepath)+'.port');pathlib.Path(str(modepath)+'.listener-pid').write_text(str(os.getpid()))
 with open(str(modepath)+'.listener-pids','a') as ids:ids.write(str(os.getpid())+'\n')
 with socket.socket() as listener:
  listener.bind(('127.0.0.1',0));listener.listen(2);listener.settimeout(5);ready.write_text(str(listener.getsockname()[1]))
  video,_=listener.accept()
  with video:
   video.sendall(b'\0');control,_=listener.accept()
   with control:
    control.settimeout(.1);done=threading.Event();capture=pathlib.Path(str(modepath)+'.controls');capture.write_bytes(b'')
    def receive():
     while not done.is_set():
      try:
       data=control.recv(4096)
       if not data:return
       with capture.open('ab') as file:file.write(data)
      except socket.timeout:pass
      except OSError:return
    reader=threading.Thread(target=receive,daemon=True);reader.start()
    video.sendall(bytes(64)+b'h264');pathlib.Path(str(modepath)+'.handshake').touch()
    until=time.monotonic()+5
    while not pathlib.Path(str(modepath)+'.allow-frame').exists() and time.monotonic()<until:time.sleep(.01)
    packet=pathlib.Path(os.environ['DROIDBRIDGE_QA_H264']).read_bytes()
    black=pathlib.Path(os.environ['DROIDBRIDGE_QA_BLACK_H264']).read_bytes()
    video.sendall(struct.pack('>QI',0,len(black))+black)
    pathlib.Path(str(modepath)+'.black-sent').touch()
    until=time.monotonic()+8
    while not pathlib.Path(str(modepath)+'.allow-visible').exists() and time.monotonic()<until:time.sleep(.01)
    try:
     for frame in range(40):video.sendall(struct.pack('>QI',(frame+1)*100_000,len(packet))+packet);time.sleep(.1)
    except (BrokenPipeError,ConnectionResetError):pass
    finally:done.set();reader.join(timeout=.3)
 sys.exit(0)
args=sys.argv[1:];mode=modepath.read_text()
with open(str(modepath)+'.calls','a') as file:file.write(json.dumps(sys.argv)+'\n')
if pathlib.Path(sys.argv[0]).name=='scrcpy':print('scrcpy 5.0.1');sys.exit(0)
if args[:1]==['devices']:print('List of devices attached\nqa-no-device device model:QA');sys.exit(0)
if args[:2]==['forward','--list']:sys.exit(0)
args=args[2:]
if args[:3]==['shell','getprop','ro.build.version.sdk']:print(35)
elif args[:2]==['shell','getprop']:
 if mode=='delayed-readiness':pathlib.Path(str(modepath)+'.readiness').touch();time.sleep(.5)
 print(1)
elif args[:4]==['shell','cmd','package','path']:print('package:/system/framework/framework-res.apk')
elif args[:4]==['shell','cmd','package','resolve-activity']:print('dev.droidbridge.testapp/.MainActivity')
elif args[:2]==['forward','tcp:0']:
 ready=pathlib.Path(str(modepath)+'.port');ready.unlink(missing_ok=True)
 subprocess.Popen([sys.executable,str(pathlib.Path(__file__).resolve()),'serve',str(modepath)],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,close_fds=True)
 until=time.monotonic()+4
 while not ready.exists() and time.monotonic()<until:time.sleep(.01)
 print(ready.read_text())
elif args[:1]==['shell'] and 'app_process' in args:time.sleep(8)
sys.exit(0)
