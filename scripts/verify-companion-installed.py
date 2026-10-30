#!/usr/bin/env python3
"""Real installed AppKit -> pinned Android companion pairing and native launch.

Requires an explicit coordinated handoff of emulator-5580/5582. Public AppKit
controls are driven through the test-only injected observer. Android actions use
visible UI nodes. Pairing QR/secret material stays only in a mode700 ignored QA
root, and never enters argv, stdout or committed evidence. No physical phone or
other emulator is touched. This runner is not a mock-transport acceptance test.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import time
import xml.etree.ElementTree as ET

REPO = Path(__file__).resolve().parents[1]
PACKAGE = 'dev.droidbridge.companion'
FIXTURE = 'dev.droidbridge.companionfixture'

class InstalledFlow:
    def __init__(self, args):
        self.args = args
        self.root = args.qa_root.resolve(strict=True)
        mode = self.root.stat()
        assert stat.S_ISDIR(mode.st_mode) and mode.st_uid == os.getuid() and stat.S_IMODE(mode.st_mode) == 0o700
        self.output = args.output.resolve()
        self.output.mkdir(parents=True, exist_ok=False)
        self.sequence = 0
        self.events = []
        self.process = None
        self.launch_started_at = None
        self.root.mkdir(mode=0o700, exist_ok=True)
    def adb(self, *parts, binary=False, timeout=20):
        result = subprocess.run([str(self.args.adb), '-s', self.args.serial, *parts], check=True, capture_output=True, timeout=timeout)
        return result.stdout if binary else result.stdout.decode('utf-8', 'strict')
    def nodes(self):
        self.adb('shell', 'uiautomator', 'dump', '/sdcard/droidbridge-installed-flow.xml')
        xml = self.adb('shell', 'cat', '/sdcard/droidbridge-installed-flow.xml')
        # The QR screen has an ImageView, not a textual secret. Still retain no
        # raw hierarchy: only exact matching nodes are consumed in memory.
        return list(ET.fromstring(xml).iter('node'))
    def phone_click(self, text, timeout=12, optional=False):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for n in self.nodes():
                if n.get('text', '').casefold() == text.casefold() and n.get('clickable') == 'true' and n.get('enabled') == 'true':
                    p = list(map(int, re.findall(r'\d+', n.get('bounds', ''))))
                    if len(p) == 4:
                        self.adb('shell', 'input', 'tap', str((p[0]+p[2])//2), str((p[1]+p[3])//2))
                        self.events.append({'kind': 'android_ui_action', 'action': text, 'monotonic': time.monotonic()})
                        return True
            if optional:
                return False
            time.sleep(.15)
        raise RuntimeError(f'Android UI action unavailable: {text}')
    def action(self, action, **fields):
        self.sequence += 1
        command = {'id': self.sequence, 'action': action, **fields}
        temporary = self.root / 'command-next.json'
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, 'w') as stream:
            json.dump(command, stream)
        os.replace(temporary, self.root / 'command.json')
        start = time.monotonic()
        while time.monotonic() - start < 15:
            try:
                value = json.loads((self.root / 'receipt.json').read_text())
                if value['id'] == self.sequence:
                    self.events.append({'kind': 'appkit_action', 'action': action, 'ok': value['ok'], 'elapsed_ms': round((time.monotonic()-start)*1000, 2)})
                    assert value['ok'], f'AppKit action failed: {action}'
                    return value
            except (FileNotFoundError, json.JSONDecodeError):
                pass
            if self.process is not None and self.process.poll() is not None:
                raise RuntimeError('Installed Mac application exited during UI interaction')
            time.sleep(.05)
        raise RuntimeError(f'AppKit action did not return a receipt: {action}')
    def wait_text(self, text, timeout=35):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = self.action('status')
            if any(text in s for s in value['texts']):
                return value
            time.sleep(.15)
        raise RuntimeError(f'Mac state was not observed: {text}')
    def capture(self, name, window='DroidBridge Companion'):
        self.action('capture', window=window, name=name)
        data = (self.root / name).read_bytes()
        (self.output / name).write_bytes(data)
        return hashlib.sha256(data).hexdigest()
    def start(self):
        app = self.args.app.resolve(strict=True)
        executable = app / 'Contents/MacOS/DroidBridge'
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True, capture_output=True)
        helper = self.root / 'actions.dylib'
        subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit', str(REPO/'scripts/verify-companion-actions.m'), '-o', str(helper)], check=True, capture_output=True)
        environment = os.environ.copy()
        environment.update(DYLD_INSERT_LIBRARIES=str(helper), DROIDBRIDGE_COMPANION_ACTIONS=str(self.root))
        for path in [self.root/'command.json', self.root/'receipt.json']:
            path.unlink(missing_ok=True)
        self.log = (self.root/'installed-host.log').open('wb')
        self.process = subprocess.Popen([str(executable), '--companion-qa-root', str(self.root), '--serial', self.args.serial], env=environment, stdout=self.log, stderr=subprocess.STDOUT)
        (self.root/'installed-host.pid').write_text(str(self.process.pid))
        self.events.append({'kind': 'installed_host_started', 'pid': self.process.pid, 'executable_sha256': hashlib.sha256(executable.read_bytes()).hexdigest(), 'qa_scope': True})
        self.action('status', window='DroidBridge')
        self.action('show_companion')
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            state = self.action('status')
            if any(b['label'] == 'ADB device for companion setup' and b['title'] for b in state['buttons']):
                break
            time.sleep(.15)
        self.action('select_adb', serial=self.args.serial)
    def prepare_phone(self):
        apk = self.args.app.resolve(strict=True) / 'Contents/Resources/Companion/DroidBridgeCompanion.apk'
        assert apk.is_file(), 'The installed candidate must bundle its Android companion APK'
        self.action('click', title='Install / Update Android Companion')
        self.wait_text('Android companion installed.', timeout=100)
        self.events.append({'kind': 'gui_companion_install_confirmed', 'bundled_apk_sha256': hashlib.sha256(apk.read_bytes()).hexdigest(), 'exact_selected_device': self.args.serial})
        self.action('click', title='Open Android Companion')
        # Explicit service consent/Android notification posting are independent.
        if self.phone_click('Start connection service', timeout=5, optional=True):
            self.phone_click('CONTINUE', optional=True)
            self.phone_click('Allow', optional=True)
    def reconnect(self):
        self.action('click', title='Connect Companion')
        self.wait_text('Authenticated companion connected', timeout=30)
        self.events.append({'kind': 'stored_pairing_reconnect', 'fresh_approval_required': False})
    def pair_by_import(self):
        self.phone_click('Pair a new Mac')
        qr = self.root/'pairing-frame.png'
        time.sleep(.5)  # Wait for Android's asynchronous QR image layout.
        qr.write_bytes(self.adb('exec-out', 'screencap', '-p', binary=True))
        os.chmod(qr, 0o600)
        try:
            self.action('click', title='Pair Phone…')
            if self.args.pairing_path == 'image':
                self.action('click', window='Pair Android Companion', title='Import QR Image…')
                self.action('choose_file', path=str(qr))
            else:
                # NSOpenPanel's remote UI cannot be selected reliably by the
                # public in-process observer. Exercise the real supported
                # manual-link path instead; neither link nor QR is evidence.
                reader = self.root/'read-private-qr.swift'
                reader.write_text('''import Foundation
import Vision
let request = VNDetectBarcodesRequest()
request.symbologies = [.qr]
try VNImageRequestHandler(url: URL(fileURLWithPath: CommandLine.arguments[1])).perform([request])
guard let link = request.results?.compactMap({ $0.payloadStringValue }).first(where: { $0.hasPrefix("droidbridge://pair?") }) else { exit(2) }
try Data(link.utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
''')
                private_link = self.root/'pairing-link.txt'
                try:
                    for attempt in range(4):
                        result = subprocess.run(['/usr/bin/swift', str(reader), str(qr), str(private_link)], capture_output=True, timeout=30)
                        if result.returncode == 0:
                            break
                        time.sleep(.3)
                        qr.write_bytes(self.adb('exec-out', 'screencap', '-p', binary=True))
                    else:
                        raise RuntimeError('The live Android pairing QR could not be decoded privately')
                    os.chmod(private_link, 0o600)
                    self.action('set_field', window='Pair Android Companion', label='Companion pairing link', value=private_link.read_text())
                    self.action('click', window='Pair Android Companion', title='Use Pairing Link')
                finally:
                    private_link.unlink(missing_ok=True)
                    reader.unlink(missing_ok=True)
            self.wait_text('Trust is pending phone approval', timeout=20)
            pending = self.action('status')
            mac_codes = set(re.findall(r'compare ([A-F0-9]{8})', '\n'.join(pending['texts'])))
            deadline = time.monotonic() + 15
            phone_code = None
            while time.monotonic() < deadline:
                text = '\n'.join(n.get('text', '') for n in self.nodes())
                matches = re.findall(r'\b([A-F0-9]{8})\b', text)
                phone_code = next((v for v in matches if v in mac_codes), None)
                if phone_code: break
                time.sleep(.2)
            assert mac_codes and phone_code, 'Phone and Mac did not show the same comparison code'
            self.events.append({'kind': 'comparison_code_matched', 'matched': True, 'code_retained': False})
            self.phone_click('Trust Mac')
            self.wait_text('Authenticated companion connected', timeout=30)
            self.events.append({'kind': 'actual_phone_approved_pairing', 'tls_pinned': True, 'pairing_path': self.args.pairing_path, 'camera_verified': False})
            self.capture('paired-native-window.png')
        finally:
            qr.unlink(missing_ok=True)
        # Close the original expiring QR sheet only after credential acceptance.
        self.adb('shell', 'input', 'keyevent', '4')
    def launch_fixture(self):
        self.action('click', title='Apps', label='Companion section Apps')
        self.action('click', title='Refresh Catalog')
        self.wait_text('apps loaded', timeout=25)
        self.capture('paired-catalog.png')
        self.action('set_field', window='DroidBridge', label='Search Android apps', value=FIXTURE)
        self.action('select_app', window='DroidBridge', package=FIXTURE)
        start = time.monotonic()
        self.launch_started_at = time.time()
        self.action('click', window='DroidBridge', title='Launch App')
        deadline = time.monotonic() + 35
        while time.monotonic() < deadline:
            receipt = self.action('status')
            if any(w['visible'] and w['title'] == 'Companion Verification' for w in receipt['windows']):
                break
            time.sleep(.2)
        else:
            raise RuntimeError('Real Android native app window did not appear')
        deadline = time.monotonic() + 25
        running = None
        while time.monotonic() < deadline:
            for event_file in (self.root/'Logs').glob('session-*.log.jsonl'):
                if event_file.stat().st_mtime < self.launch_started_at:
                    continue
                for line in event_file.read_text().splitlines():
                    event = json.loads(line)
                    if event.get('package') == FIXTURE and event.get('device') == self.args.serial and event.get('backend') == 'native' and event.get('state') == 'running':
                        running = event_file
                        break
            if running:
                break
            time.sleep(.1)
        assert running, 'The native backend did not confirm a decoded first frame'
        # First-frame readiness can precede Android activity drawing. Retain a
        # settled screenshot separately; a reviewer still verifies its content.
        time.sleep(2)
        self.capture('native-android-fixture.png', window='Companion Verification')
        (self.output/'native-session.log.jsonl').write_bytes(running.read_bytes())
        (self.output/'native-session.log').write_bytes(running.with_suffix('').read_bytes()[:262144])
        self.events.append({'kind': 'actual_native_android_window', 'package': FIXTURE, 'first_decoded_frame_confirmed': True, 'visible_window_elapsed_ms': round((time.monotonic()-start)*1000, 2)})
        self.action('click', title='Sessions', label='Companion section Sessions')
        self.wait_text('Companion Verification', timeout=12)
        self.capture('registered-native-session.png')
    def finish(self, passed, error=None):
        value = {'passed': passed, 'scope': 'Installed signed Mac app + real Android companion TLS/GUI flow; isolated QA paths', 'serial': self.args.serial, 'physical_focus_verified': False, 'events': self.events}
        if error: value['error'] = error
        (self.output/'results.json').write_text(json.dumps(value, indent=2))
        if self.process is not None and not self.args.leave_running:
            try: self.action('quit')
            except Exception: self.process.terminate()
            try: self.process.wait(timeout=35)
            except subprocess.TimeoutExpired: self.process.kill(); self.process.wait()
        if hasattr(self, 'log'): self.log.close()
        try: self.adb('shell', 'rm', '-f', '/sdcard/droidbridge-installed-flow.xml')
        except Exception: pass
    def hold(self):
        if not self.args.leave_running or self.process is None:
            return
        # Keep the exec session alive: its lifecycle otherwise reaps children.
        # External public-AppKit actions remain usable for subsequent checks.
        stop = self.root/'stop-installed-runner'
        stop.unlink(missing_ok=True)
        while self.process.poll() is None and not stop.exists():
            time.sleep(.25)
        if self.process.poll() is None:
            self.action('quit')
            self.process.wait(timeout=35)
        stop.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--serial', choices=['emulator-5580', 'emulator-5582'], required=True)
    parser.add_argument('--adb', type=Path, required=True)
    parser.add_argument('--qa-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--leave-running', action='store_true')
    parser.add_argument('--pairing-path', choices=['manual', 'image'], default='manual')
    parser.add_argument('--reuse-pairing', action='store_true')
    args = parser.parse_args()
    flow = InstalledFlow(args)
    try:
        flow.start(); flow.prepare_phone()
        if args.reuse_pairing: flow.reconnect()
        else: flow.pair_by_import()
        flow.launch_fixture(); flow.finish(True)
        print('PASS: installed native pairing/catalog/session flow; see structured evidence', flush=True)
        flow.hold()
    except Exception as error:
        flow.finish(False, str(error))
        if args.leave_running:
            print('Installed flow stopped; the owned UI remains available for diagnosis', flush=True)
            flow.hold()
        raise

if __name__ == '__main__': main()
