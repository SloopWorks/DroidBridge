#!/usr/bin/env python3
"""No-device bounded child fixtures for the shipping-launcher regression."""
import json, os, pathlib, socket, struct, subprocess, sys, time
if len(sys.argv) > 1 and sys.argv[1] == 'serve':
    ready = pathlib.Path(sys.argv[2])
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0)); listener.listen(2); listener.settimeout(4)
        ready.write_text(str(listener.getsockname()[1]))
        video, _ = listener.accept()
        with video:
            video.sendall(b'\0')
            control, _ = listener.accept()
            with control:
                video.sendall(bytes(64) + b'h264')
                time.sleep(.3)
                if sys.argv[3] == 'native-present':
                    packet = pathlib.Path(os.environ['DROIDBRIDGE_QA_H264']).read_bytes()
                    for frame in range(25):
                        video.sendall(struct.pack('>QI', frame * 100_000, len(packet)) + packet)
                        time.sleep(.1)
                    sys.exit(0)
                # Valid transport handshake followed by a specific invalid size:
                # invokes production onFailure while startup awaits first frame.
                video.sendall(struct.pack('>QI', 0, 16_777_217))
                time.sleep(.5)
    sys.exit(0)
args = sys.argv[1:]
mode = pathlib.Path(os.environ['DROIDBRIDGE_QA_MODE']).read_text()
with open(os.environ['DROIDBRIDGE_QA_MODE'] + '.calls', 'a') as log:
    log.write(json.dumps(sys.argv) + '\n')
if pathlib.Path(sys.argv[0]).name == 'scrcpy':
    if '--version' in args: print('scrcpy 5.0.1')
    else: time.sleep(.25)
    sys.exit(0)
if args[:2] == ['forward', '--list']: sys.exit(0)
if args[:1] == ['devices']:
    pathlib.Path(os.environ['DROIDBRIDGE_QA_MODE'] + '.refresh-started').write_text('started')
    time.sleep(1.5 if mode == 'icons-slow' else 0)
    print('List of devices attached\nqa-no-device device model:QA')
    sys.exit(0)
args = args[2:]
if args and args[0] == 'push' and mode == 'icons-slow': time.sleep(.6)
elif args[:3] == ['shell', 'rm', '-f'] and mode == 'icons-slow':
    time.sleep(.15)
    with open(os.environ['DROIDBRIDGE_QA_MODE'] + '.cleaned', 'a') as log: log.write(json.dumps(args) + '\n')
elif args[:2] == ['shell', 'getprop']: print(1)
elif args[:4] == ['shell', 'cmd', 'package', 'resolve-activity']: print('dev.droidbridge.testapp/.MainActivity')
elif args[:4] == ['shell', 'cmd', 'package', 'path']: print('package:/system/framework/framework-res.apk')
elif args[:2] == ['forward', 'tcp:0']:
    if mode in ('native-fault', 'native-present'):
        ready = pathlib.Path(os.environ['DROIDBRIDGE_QA_MODE'] + '.port')
        ready.unlink(missing_ok=True)
        subprocess.Popen([sys.executable, str(pathlib.Path(__file__).resolve()), 'serve', str(ready), mode], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True)
        until = time.monotonic() + 3
        while not ready.exists() and time.monotonic() < until: time.sleep(.01)
        print(ready.read_text())
    else:
        with socket.socket() as s:
            s.bind(('127.0.0.1', 0)); print(s.getsockname()[1])
elif args and args[0] == 'shell' and 'app_process' in args:
    time.sleep(8 if mode == 'native-present' else 2 if mode == 'native-fault' else .25)
sys.exit(0)
