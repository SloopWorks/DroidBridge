#!/usr/bin/env python3
"""Exercise installed ADB using an exact-owned server and only QA emulator5580.
Never stops the shared server, auto-discovers USB, or touches other emulators.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import uuid


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    adb = args.app.resolve(strict=True) / 'Contents/Resources/Runtime/bin/adb'
    subprocess.run(['codesign', '--verify', '--strict', str(adb)], check=True, capture_output=True)
    port = 5038
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', port))  # Refuse an occupied port, never replace it.
    repo = Path(__file__).resolve().parents[1]
    root = Path(tempfile.mkdtemp(prefix='installed-adb-qa35-', dir=repo/'.build'))
    os.chmod(root, 0o700)
    android_home = root/'android-home'; android_home.mkdir(mode=0o700)
    environment = dict(os.environ, PATH='/usr/bin:/bin', ADB_USB='0', ADB_MDNS='0',
                       ADB_LOCAL_TRANSPORT_MAX_PORT='0', ANDROID_USER_HOME=str(android_home),
                       ADB_SERVER_SOCKET=f'tcp:{port}')
    server_log = (root/'server.log').open('wb')
    # ADB's server socket spec accepts a port; without -a it binds loopback.
    # The client -H flag independently selects that exact loopback host.
    server = subprocess.Popen([str(adb), '-L', f'tcp:{port}', 'server', 'nodaemon'],
                              env=environment, stdout=server_log, stderr=subprocess.STDOUT)
    rows = []
    remote = '/data/local/tmp/droidbridge-packaged-adb-' + uuid.uuid4().hex + '.bin'
    serial = '127.0.0.1:5581'
    local = None
    connected = False
    complete = False

    def run(*arguments):
        result = subprocess.run([str(adb), '-H', '127.0.0.1', '-P', str(port), *arguments],
                                env=environment, capture_output=True, text=True, timeout=15)
        rows.append({'arguments': list(arguments), 'exit_code': result.returncode,
                     'stdout': result.stdout, 'stderr': result.stderr})
        require(result.returncode == 0, 'Owned ADB command failed: ' + repr(arguments))
        return result.stdout

    try:
        deadline = time.monotonic()+5
        while True:
            require(server.poll() is None, 'Owned ADB server exited before admission')
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=.1):
                    break
            except OSError:
                require(time.monotonic()<deadline, 'Owned ADB server did not listen')
                time.sleep(.02)
        owner = subprocess.check_output(['lsof', '-nP', '-a', '-p', str(server.pid),
                                         '-iTCP:'+str(port), '-sTCP:LISTEN'], text=True)
        require('127.0.0.1:'+str(port) in owner, 'Server does not own the exact loopback listener')
        require(run('devices', '-l').strip() == 'List of devices attached', 'Isolated server unexpectedly discovered a device')
        require('connected to '+serial in run('connect', serial), 'Owned emulator connection failed')
        connected = True
        devices = run('devices', '-l').splitlines()
        require(len([line for line in devices if ' device ' in line]) == 1 and any(line.startswith(serial+' ') for line in devices), 'ADB discovered an unexpected transport')
        require(run('-s', serial, 'shell', 'getprop', 'ro.build.version.sdk').strip() == '35', 'Owned emulator is not the expected API35 AVD')
        payload = bytes(range(256))*256
        source = root/'payload.bin'; source.write_bytes(payload)
        expected = hashlib.sha256(payload).hexdigest()
        run('-s', serial, 'push', str(source), remote)
        require(run('-s', serial, 'shell', 'sha256sum', remote).split()[0] == expected, 'Android payload hash differs')
        pulled = root/'pulled.bin'; run('-s', serial, 'pull', remote, str(pulled))
        require(pulled.read_bytes() == payload, 'ADB pull bytes differ')
        local = 'tcp:'+run('-s', serial, 'forward', '--no-rebind', 'tcp:0', 'tcp:37841').strip()
        require([serial, local, 'tcp:37841'] in [line.split() for line in run('forward', '--list').splitlines()], 'Owned forward not found')
        run('-s', serial, 'forward', '--remove', local); local = None
        run('-s', serial, 'shell', 'rm', remote)
        run('disconnect', serial); connected = False
        require(run('devices', '-l').strip() == 'List of devices attached', 'Isolated transport leaked')
        complete = True
    finally:
        if server.poll() is None:
            if connected:
                if local is not None:
                    try:
                        inventory = run('forward', '--list')
                        if [serial, local, 'tcp:37841'] in [line.split() for line in inventory.splitlines()]:
                            run('-s', serial, 'forward', '--remove', local)
                    except Exception:
                        pass
                try:
                    run('-s', serial, 'shell', 'rm', remote)
                    run('disconnect', serial)
                except Exception:
                    pass
            server.terminate()  # Exact Popen child; never adb kill-server.
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill(); server.wait(timeout=3)
        server_log.close()
        with socket.socket() as probe:
            require(probe.connect_ex(('127.0.0.1', port)) != 0, 'Owned listener did not close')
        report = {'passed': complete, 'scope': 'Installed signed ADB, isolated server5038, owned API35 emulator; no video, physical USB/Wi-Fi or GUI claim',
                  'app': str(args.app.resolve()), 'adb_sha256': hashlib.sha256(adb.read_bytes()).hexdigest(),
                  'server_pid': server.pid, 'server_exit_code': server.returncode, 'owned_listener_closed': True,
                  'environment': {key:environment[key] for key in ('ADB_USB','ADB_MDNS','ADB_LOCAL_TRANSPORT_MAX_PORT')}, 'tests': rows}
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2)+'\n')
    print('PASS installed ADB: isolated discovery, shell,64KiB verified push/pull, exact forward cleanup and server teardown')


if __name__ == '__main__':
    main()
