#!/usr/bin/env python3
"""Installed-GUI/native audio acceptance. Requires exclusive coordinated emulator.

Only emulator-5580/5582 are accepted. Android apps launch via public launcher
controls. Native input uses public AppKit events at locally OCR-derived points.
The exact bundled audio client receives unchanged production argv through an
exec-only observer proxy. Only aggregate successfully queued PCM is retained;
physical audibility and physical desktop focus remain unverified.
"""
import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shlex
import signal
import subprocess
import sys
import time

REPO = pathlib.Path(__file__).resolve().parents[1]
PACKAGES = ('dev.droidbridge.testapp', 'dev.droidbridge.testapp2')
PHONE_CHECKBOX = 'Keep phone screen off during Mac sessions'


def run(*argv, timeout=25):
    return subprocess.check_output(list(map(str, argv)), text=True,
                                   stderr=subprocess.STDOUT, timeout=timeout)


def wait(label, predicate, seconds=30):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(.15)
    raise AssertionError('Timeout: ' + label)


def read_jsonl(path):
    result = []
    if path.exists():
        for line in path.read_text().splitlines():
            try:
                result.append(json.loads(line))
            except json.JSONDecodeError:
                pass  # Final append may still be in flight.
    return result



def redact_inventory(text, serial):
    """Redact unrelated ADB inventory rows, retaining targeted diagnostics."""
    pattern = re.compile(r'^\s*(?:(?:INFO|ERROR|WARN|DEBUG):\s*)?(?:[-=>*]+\s*)?(?:\([^)]*\)\s*)?(\S+)\s+(device|offline|unauthorized)\b')
    lines, count = [], 0
    for line in text.splitlines(keepends=True):
        match = pattern.search(line)
        if match and match.group(1) != serial:
            lines.append('[REDACTED unrelated ADB inventory row]\n')
            count += 1
        else:
            lines.append(line)
    return ''.join(lines), count


def snapshot(path):
    return (path.read_bytes(), path.stat().st_mode & 0o777) if path.exists() else None


def restore(path, prior):
    if prior is None:
        path.unlink(missing_ok=True)
    else:
        temporary = path.with_name(path.name + '.audio-qa-' + str(os.getpid()))
        temporary.write_bytes(prior[0])
        temporary.chmod(prior[1])
        temporary.replace(path)


def prepare_instruments(app, output):
    """Offline compilation only; does not run DroidBridge, ADB or preferences."""
    shim = output / 'actions.dylib'
    run('clang', '-dynamiclib', '-fobjc-arc', '-Wall', '-Wextra', '-framework',
        'AppKit', REPO / 'scripts/verify-audio-actions.m', '-o', shim)
    runtime = app / 'Contents/Resources/Runtime'
    candidates = sorted((runtime / 'lib').glob('libSDL3*.dylib'))
    assert candidates, 'Bundled SDL3 is missing'
    sdl = candidates[0].resolve()
    observer = output / 'samples.dylib'
    flags = shlex.split(run('/opt/homebrew/bin/pkg-config', '--cflags', 'sdl3'))
    run('clang', '-dynamiclib', '-O2', '-Wall', '-Wextra', *flags,
        REPO / 'scripts/verify-audio-samples.c', sdl, '-o', observer)
    (output / 'observer-linkage.txt').write_text(run('otool', '-L', observer))
    ocr_source = output / 'recognize.swift'
    ocr_source.write_text('''import Foundation
import Vision
let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate
request.usesLanguageCorrection=false;request.recognitionLanguages=["en-US"]
try VNImageRequestHandler(url:URL(fileURLWithPath:CommandLine.arguments[1])).perform([request])
let rows=(request.results ?? []).compactMap {row -> [String:Any]? in
 guard let text=row.topCandidates(1).first?.string else {return nil}
 let r=row.boundingBox
 return ["text":text,"x":r.midX,"y":1-r.midY,"width":r.width,"height":r.height]
}
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:rows,options:[.sortedKeys]))
''')
    ocr = output / 'recognize'
    run('swiftc', ocr_source, '-o', ocr)
    client = runtime / 'bin/DroidBridgeAudioClient'
    assert client.is_file(), 'Bundled audio client missing'
    proxy = output / 'audio-client-proxy'
    # Fixed trusted paths are serialized into Python literals, never shell code.
    configuration = dict(client=str(client), argv_log=str(output / 'audio-argv.jsonl'),
                         observer=str(observer), library_path=str(runtime / 'lib'), metrics=str(output / 'samples.jsonl'))
    proxy.write_text('#!' + sys.executable + '\n' + 'config=' + repr(configuration) + '\n' + '''import json,os,sys,time
client=config["client"]
with open(config["argv_log"],"a") as log:
 log.write(json.dumps(dict(pid=os.getpid(),client=client,argv=sys.argv[1:],time=time.time()))+"\\n")
env=dict(os.environ,DYLD_INSERT_LIBRARIES=config["observer"],DYLD_LIBRARY_PATH=config["library_path"],DROIDBRIDGE_AUDIO_PROBE_OUTPUT=config["metrics"])
os.execve(client,[client]+sys.argv[1:],env)
''')
    proxy.chmod(0o700)
    return shim, proxy, ocr, client, sdl


class NativeAudioTest:
    def __init__(self, args):
        self.args = args
        self.app = args.app.resolve()
        self.out = args.output.resolve()
        if self.out.exists() and any(self.out.iterdir()):
            archived = self.out.with_name(self.out.name + '-before-' + str(time.time_ns()))
            self.out.rename(archived)  # Preserve every failed run.
        self.out.mkdir(parents=True, exist_ok=True)
        self.binary = self.app / 'Contents/MacOS/DroidBridge'
        self.adb = self.app / 'Contents/Resources/Runtime/bin/adb'
        self.metadata = plistlib.loads((self.app / 'Contents/Info.plist').read_bytes())
        self.logs = pathlib.Path.home() / 'Library/Logs/DroidBridge'
        self.support = pathlib.Path.home() / 'Library/Application Support/DroidBridge'
        self.sessions = self.support / 'sessions.json'
        self.prefs = self.support / 'preferences.json'
        self.audio_prefs = self.support / 'audio-preferences.json'
        self.audio_dir = self.support / 'AudioRoutes.noindex'
        self.device_key = hashlib.sha256(args.serial.encode()).hexdigest()
        self.report = dict(passed=False, acceptance=False, app=str(self.app), serial=args.serial,
                           version=self.metadata['CFBundleShortVersionString'], build=self.metadata['CFBundleVersion'],
                           installed_sha256=hashlib.sha256(self.binary.read_bytes()).hexdigest(),
                           physical_audibility_verified=False, physical_focus_verified=False,
                           instrumentation='Public AppKit actions, local Vision OCR, aggregate successful SDL PCM only', phases=[])
        self.child = None
        self.number = 0
        self.windows = {}
        self.initial_logs = set()
        self.owned_audio_pids = set()

    def android(self, *argv):
        return run(self.adb, '-s', self.args.serial, *argv)

    def resources(self):
        return dict(displays=self.android('shell', 'cmd', 'display', 'get-displays').count('Display id '),
                    forwards=sorted(l for l in run(self.adb, 'forward', '--list').splitlines()
                                    if l.startswith(self.args.serial + ' ')),
                    reverses=sorted(l for l in self.android('reverse', '--list').splitlines() if l.strip()))

    def global_settings(self):
        return {scope + ":" + key: self.android('shell', 'settings', 'get', scope, key).strip()
                for scope, key in [('secure', 'show_ime_with_hard_keyboard'), ('secure', 'default_input_method'),
                                   ('secure', 'enabled_input_methods'), ('global', 'stay_on_while_plugged_in'),
                                   ('system', 'screen_off_timeout')]}

    def panel(self):
        line = next(l for l in self.android('shell', 'cmd', 'display', 'get-displays').splitlines()
                    if l.startswith('Display id 0:'))
        return re.search(r'\bstate ([A-Z_]+)', line).group(1)

    def set_panel(self, value):
        api = int(self.android('shell', 'getprop', 'ro.build.version.sdk').strip())
        if value == 'OFF':
            self.android('shell', 'cmd', 'display', 'power-off', '0')
        elif api >= 37:
            self.android('shell', 'cmd', 'display', 'power-reset', '0')
            if self.panel() != 'ON':
                self.android('shell', 'cmd', 'power', 'wakeup', '--display-id', '0')
        else:
            self.android('shell', 'cmd', 'display', 'power-on', '0')
        wait('panel ' + value, lambda: self.panel() == value, 12)

    def command(self, action, **fields):
        self.number += 1
        path = self.out / f'receipt-{self.number}.json'
        temporary = self.out / 'command.tmp'
        temporary.write_text(json.dumps(dict(id=self.number, action=action, **fields)))
        temporary.replace(self.out / 'command.json')
        def received():
            if self.child and self.child.poll() is not None:
                raise AssertionError('Installed GUI exited before receipt: ' + action)
            return path.exists()
        wait('AppKit receipt ' + action, received, 20)
        receipt = json.loads(path.read_text())
        assert receipt['passed'], receipt
        return receipt

    def events(self):
        result = []
        for file in set(self.logs.glob('*.jsonl')) - self.initial_logs:
            result.extend(read_jsonl(file))
        return [e for e in result if e.get('device') == self.args.serial]

    def capture(self, window, label):
        self.command('capture', window=window, filename=label + '.png')
        path = self.out / (label + '.png')
        rows = json.loads(run(self.ocr, path))
        (self.out / (label + '-ocr.json')).write_text(json.dumps(rows, indent=2))
        return rows

    def click(self, package, phrase, label):
        window = self.windows[package]['window']
        def recognized():
            rows = self.capture(window, label)
            return next((r for r in rows if phrase.casefold() in r['text'].casefold()), None)
        point = wait('OCR ' + phrase, recognized, 20)
        before = self.android('logcat', '-d', '-s', 'DroidBridgeProbe:I', '*:S')
        self.command('input', window=window, x=point['x'], y=point['y'])
        if phrase == 'Play test tone':
            frequency = 1499 if package.endswith('2') else 997
            marker = 'tone_started frequency=' + str(frequency) + ' display=' + str(self.windows[package]['display'])
            count = before.count(marker)
            wait('NEW tone receipt on exact Android display', lambda: self.android('logcat', '-d', '-s', 'DroidBridgeProbe:I', '*:S').count(marker) > count, 8)
        self.assert_no_tone_failure()
        return point

    def assert_no_tone_failure(self):
        text = self.android('logcat', '-d', '-s', 'DroidBridgeProbe:I', '*:S')
        fresh = [line for line in text.splitlines() if line not in self.input_before_lines]
        assert not any('tone_failed' in line for line in fresh), 'Android AudioTrack tone failed'
        (self.out / 'android-input-current.log').write_text(text)

    def video_alive(self, label):
        status = self.command('status')
        for package, item in self.windows.items():
            assert any(w['number'] == item['window'] and w['visible'] for w in status['windows']), status
            rows = self.capture(item['window'], label + '-' + package.rsplit('.', 1)[-1])
            tick_rows = [r['text'] for r in rows if 'ticks' in r['text'].lower()]
            assert tick_rows, rows
            time.sleep(.35)
            newer = self.capture(item['window'], label + '-updated-' + package.rsplit('.', 1)[-1])
            assert [r['text'] for r in newer if 'ticks' in r['text'].lower()] != tick_rows, 'Decoded tick content did not update'
            assert not any(e.get('session') == item['session'] and e.get('state') in ('failed', 'stopped') for e in self.events())

    def launch(self, package):
        self.command('search', query=package)
        wait('filtered app ' + package, lambda: self.command('status')['rows'] >= 1)
        self.command('launch', package=package, backend='native')
        running = wait('real decoded native frame ' + package, lambda: next((e for e in reversed(self.events())
                       if e.get('package') == package and e.get('backend') == 'native' and e.get('state') == 'running'), None), 55)
        session = running['session']
        shown = wait('window mapping', lambda: next((e for e in self.events()
                     if e.get('session') == session and e.get('event') == 'loading_window_presented'), None))
        window = int(shown['details']['window_number'])
        log = self.logs / f'session-{session}.log'
        display = int(wait('display binding', lambda: ((m.group(1) if (m := re.search(r'Starting app .* on display (\d+)', log.read_text())) else None))))
        self.windows[package] = dict(window=window, session=session, display=display)
        self.command('resize', window=window, width=480, height=720)
        wait('tone control rendered', lambda: any('play test tone' in r['text'].lower()
             for r in self.capture(window, 'launched-' + package.rsplit('.', 1)[-1])), 30)

    def invocations(self):
        return read_jsonl(self.out / 'audio-argv.jsonl')

    def live_audio(self):
        live = []
        for item in self.invocations():
            try:
                actual = run('/bin/ps', '-ww', '-p', item['pid'], '-o', 'command=').strip()
                if str(self.client) in actual and '--no-video' in actual:
                    live.append(item)
                    self.owned_audio_pids.add(item['pid'])
            except subprocess.CalledProcessError:
                pass
        assert len(live) <= 1, 'More than one audio client for this device: ' + str(live)
        return live

    def assert_argv(self, item, route):
        argv = item['argv']
        port = argv[argv.index('--port') + 1]
        expected = ['--serial', self.args.serial, '--port', port, '--force-adb-forward', '--no-video',
                    '--no-control', '--no-window', '--no-power-on', '--require-audio', '--audio-codec=raw']
        expected += ['--audio-source=playback', '--audio-dup'] if route == 'macAndPhone' else ['--audio-source=output']
        assert argv == expected, (argv, expected)
        assert item['client'] == str(self.client)
        mapping = run('/usr/bin/vmmap', '-w', item['pid'], timeout=20)
        (self.out / f'loaded-images-{item["pid"]}.txt').write_text(mapping)
        assert any(str(self.sdl) in line and self.sdl.name in line for line in mapping.splitlines()), 'Bundled SDL mapping not proven loaded'

    def metrics(self):
        samples = read_jsonl(self.out / 'samples.jsonl')
        assert all(s.get('dropped_frames') == 0 for s in samples), 'Observer dropped frames; evidence is incomplete'
        return samples

    def sample_phase(self, label, wanted=(), absent=(), silence=False, minimum=6, seconds=8):
        owner = self.live_audio()
        assert len(owner) == 1, 'No unique owned audio client at phase admission'
        pid = owner[0]['pid']
        start = len(self.metrics())
        noise = getattr(self, 'silence_floor', {997: 0.0, 1499: 0.0})
        thresholds = {hz: max(.00002, noise[hz] * 8) for hz in (997, 1499)}
        baseline_admission = label.endswith('silence-baseline')
        silence_rms_limit = .0001 if baseline_admission else max(.00002, getattr(self, 'silence_rms', 0.0) * 3)
        def matches(sample):
            # The fixture tone deliberately has low amplitude, and Android's
            # preserved media volume attenuates it. Require measured-baseline
            # separation plus narrowband dominance rather than assume a gain.
            if any(sample['tone' + str(hz)] <= thresholds[hz] for hz in wanted):
                return False
            if any(sample['tone' + str(hz)] < .25 * sample['rms'] for hz in wanted):
                return False
            # A 100 ms rectangular Goertzel window has predictable sidelobes
            # between these non-bin-centered tones. Use a gain-independent 2%
            # ratio; playback capture is prevolume, unlike attenuated output.
            if wanted and absent and any(sample['tone' + str(hz)] >= .02 * max(sample['tone' + str(on)] for on in wanted) for hz in absent):
                return False
            if not wanted and any(sample['tone' + str(hz)] >= thresholds[hz] for hz in absent):
                return False
            return not silence or sample['rms'] < silence_rms_limit
        def measured():
            self.assert_no_tone_failure()
            samples = [sample for sample in self.metrics()[start:] if sample['pid'] == pid]
            chosen = [sample for sample in samples if matches(sample)]
            return (samples, chosen) if len(chosen) >= minimum else None
        samples, chosen = wait('aggregate PCM ' + label, measured, seconds)
        assert [item['pid'] for item in self.live_audio()] == [pid], 'Audio owner changed during sample phase'
        if baseline_admission:
            self.silence_floor = {hz: max(sample['tone' + str(hz)] for sample in chosen) for hz in (997, 1499)}
            self.silence_rms = max(sample['rms'] for sample in chosen)
        phase = dict(phase=label, passed=True, audio_pid=pid, samples=len(samples), matching=len(chosen),
                     tone_presence_thresholds=thresholds, maximum_absent_to_wanted_ratio=.02, silence_rms_limit=silence_rms_limit,
                     minimum_wanted_to_rms_ratio=.25,
                     wanted_hz=list(wanted), absent_hz=list(absent), silence=silence,
                     max_dropped_frames=max(s['dropped_frames'] for s in samples),
                     max_tone997=max(s['tone997'] for s in samples), max_tone1499=max(s['tone1499'] for s in samples),
                     min_rms=min(s['rms'] for s in samples), max_rms=max(s['rms'] for s in samples),
                     one_audio_client=len(self.live_audio()) == 1)
        assert phase['one_audio_client']
        self.report['phases'].append(phase)
        (self.out / (label + '-metrics.json')).write_text(json.dumps(dict(summary=phase, samples=samples), indent=2))

    def select_route(self, route, expected):
        self.command('route', value=route)
        status = wait('audio UI ' + expected, lambda: ((s if expected in s['audio_status'] and s['audio_route'] == route else None)
                      if (s := self.command('status')) else None), 35)
        self.command('capture', filename='launcher-route-' + route + '-' + str(self.number) + '.png')
        return status

    def panel_checkbox(self, off):
        state = self.command('status')['button_states'][PHONE_CHECKBOX]
        if bool(state) != off:
            self.command('button', title=PHONE_CHECKBOX)

    def execute(self):
        self.shim, self.proxy, self.ocr, self.client, self.sdl = prepare_instruments(self.app, self.out)
        run('codesign', '--verify', '--deep', '--strict', self.app)
        self.report['signature_verified'] = True
        self.report['instrument_hashes'] = {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in [self.client, self.sdl, self.shim, self.out / 'samples.dylib',
                         REPO / 'scripts/verify-audio-actions.m', REPO / 'scripts/verify-audio-samples.c',
                         pathlib.Path(__file__)]}
        assert self.android('shell', 'getprop', 'sys.boot_completed').strip() == '1'
        self.before = self.resources()
        self.report['before'] = self.before
        self.original_panel = self.panel()
        self.input_before_lines = set(self.android('logcat', '-d', '-s', 'DroidBridgeProbe:I', '*:S').splitlines())
        self.settings_before = self.global_settings()
        self.system_server_before = self.android('shell', 'pidof', 'system_server').strip()
        self.report['system_server_pid_before'] = self.system_server_before
        (self.out / 'android-settings-before.json').write_text(json.dumps(self.settings_before, indent=2))
        self.session_snapshot = snapshot(self.sessions)
        self.prior_prefs = snapshot(self.prefs)
        self.prior_audio_prefs = snapshot(self.audio_prefs)
        prefs = json.loads(self.prior_prefs[0]) if self.prior_prefs else {}
        audio_prefs = json.loads(self.prior_audio_prefs[0]) if self.prior_audio_prefs else {}
        self.prior_route_present = self.args.serial in audio_prefs.get('deviceAudioRoutes', {})
        self.prior_route = audio_prefs.get('deviceAudioRoutes', {}).get(self.args.serial)
        self.prior_screen_off = self.args.serial in prefs.get('screenOffDeviceSerials', [])
        self.control_snapshots = {self.audio_dir / (self.device_key + suffix): snapshot(self.audio_dir / (self.device_key + suffix))
                                  for suffix in ('.retry', '.failed.json')}
        self.geometry = {}
        for package in PACKAGES:
            key = 'NSWindow Frame AndroidApp.' + hashlib.sha256((self.args.serial + ':' + package).encode()).hexdigest()
            try:
                self.geometry[key] = run('defaults', 'read', self.metadata['CFBundleIdentifier'], key).strip()
            except subprocess.CalledProcessError:
                self.geometry[key] = None
        self.initial_logs = set(self.logs.glob('*.jsonl'))
        self.initial_audio_logs = set(self.audio_dir.glob('*.log'))
        try:
            self.sessions.write_text('[]')
            env = dict(os.environ, PATH='/usr/bin:/bin', DYLD_INSERT_LIBRARIES=str(self.shim),
                       DROIDBRIDGE_LAUNCHER_QA_ROOT=str(self.out), DROIDBRIDGE_AUDIO_CLIENT=str(self.proxy))
            with (self.out / 'host.log').open('w') as log:
                self.child = subprocess.Popen([str(self.binary), '--serial', self.args.serial], env=env, stdout=log, stderr=log)
                wait('device catalog', lambda: ((s if self.args.serial in s['device'] and s['rows'] > 0 else None)
                     if (s := self.command('status')) else None), 60)
                self.command('select_device', serial=self.args.serial)
                self.panel_checkbox(False)
                self.set_panel('ON')
                self.select_route('phone', 'Phone audio')
                for package in PACKAGES:
                    self.launch(package)
                assert len({i['display'] for i in self.windows.values()}) == 2
                assert not self.live_audio() and not self.invocations(), 'Phone route started capture'
                self.video_alive('phone-no-capture')
                self.report['phases'].append(dict(phase='phone-no-capture', passed=True, windows=self.windows.copy()))
                self.select_route('mac', 'Mac output initialized')
                audio = wait('one Mac client', self.live_audio)[0]
                self.assert_argv(audio, 'mac')
                self.sample_phase('mac-silence-baseline', silence=True)
                self.click(PACKAGES[0], 'Play test tone', 'play-A')
                self.sample_phase('mac-A-997', wanted=(997,), absent=(1499,))
                self.click(PACKAGES[1], 'Play test tone', 'play-B')
                self.sample_phase('mac-overlapping-A-B', wanted=(997, 1499))
                self.click(PACKAGES[0], 'Stop test tone', 'stop-A')
                self.sample_phase('mac-B-1499', wanted=(1499,), absent=(997,))
                self.click(PACKAGES[1], 'Stop test tone', 'stop-B')
                self.sample_phase('mac-stopped-silence', silence=True)
                self.video_alive('two-native-with-one-audio')
                self.select_route('macAndPhone', 'Mac output initialized')
                duplicate = wait('one playback-dup client', lambda: next((i for i in self.live_audio()
                     if '--audio-dup' in i['argv']), None))
                self.assert_argv(duplicate, 'macAndPhone')
                self.sample_phase('macAndPhone-silence-baseline', silence=True)
                assert duplicate['pid'] != audio['pid']
                self.click(PACKAGES[0], 'Play test tone', 'dup-play-A')
                self.sample_phase('macAndPhone-A-997', wanted=(997,), absent=(1499,))
                self.panel_checkbox(True)
                wait('real phone panel OFF', lambda: self.panel() == 'OFF', 20)
                self.click(PACKAGES[0], 'Play test tone', 'panel-off-replay-A')
                self.sample_phase('panel-off-video-and-tone', wanted=(997,), absent=(1499,))
                self.video_alive('panel-off-continued-frames')
                assert self.panel() == 'OFF'
                self.click(PACKAGES[0], 'Stop test tone', 'dup-stop-A')
                self.sample_phase('macAndPhone-stopped-silence', silence=True)
                videos_only = self.resources()
                self.select_route('phone', 'Phone audio')
                wait('audio client stopped', lambda: not self.live_audio(), 25)
                wait('audio tunnel removed videos retained', lambda: len(self.resources()['forwards']) == len(videos_only['forwards']) - 1, 20)
                self.video_alive('phone-again-videos-continue')
                self.report['phases'].append(dict(phase='phone-releases-audio-keeps-two-videos', passed=True))
                self.select_route('mac', 'Mac output initialized')
                crash = wait('new owned audio client', self.live_audio)[0]
                self.assert_argv(crash, 'mac')
                # Only our proxy-recorded exact bundled client is signalled.
                assert crash['pid'] in self.owned_audio_pids
                os.kill(crash['pid'], signal.SIGTERM)
                failed = wait('visible audio recovery', lambda: ((s if 'Audio unavailable' in s['audio_status']
                     and s['buttons'].get('Retry Audio') and s['buttons'].get('Use Phone') else None)
                     if (s := self.command('status')) else None), 25)
                self.video_alive('audio-failed-video-continues')
                self.command('capture', filename='launcher-audio-failed.png')
                self.command('button', title='Retry Audio')
                wait('retry ready', lambda: 'Mac output initialized' in self.command('status')['audio_status'], 35)
                retried = wait('retried audio client', self.live_audio)[0]
                assert retried['pid'] != crash['pid']
                self.click(PACKAGES[1], 'Play test tone', 'retry-play-B')
                self.sample_phase('retry-B-1499', wanted=(1499,), absent=(997,))
                self.click(PACKAGES[1], 'Stop test tone', 'retry-stop-B')
                # Exercise the actual failed-state Phone button, not just picker.
                os.kill(retried['pid'], signal.SIGTERM)
                wait('second failed recovery', lambda: self.command('status')['buttons'].get('Use Phone'), 25)
                self.command('button', title='Use Phone')
                wait('Phone recovery selected', lambda: 'Phone audio' in self.command('status')['audio_status'], 20)
                wait('no capture after Phone', lambda: not self.live_audio(), 15)
                self.video_alive('use-phone-recovery-videos-continue')
                self.report['phases'].append(dict(phase='audio-only-crash-retry-and-phone-recovery', passed=True,
                                                  failed_status=failed['audio_status'], crashed_pid=crash['pid'], retry_pid=retried['pid']))
                self.command('quit')
                self.child.wait(timeout=45)
                assert self.child.returncode == 0
            wait('resource baseline after quit', lambda: self.resources() == self.before, 30)
            samples = self.metrics()
            assert samples and all(s['dropped_frames'] == 0 for s in samples)
            self.report.update(passed=True, acceptance=True, windows=self.windows, metric_samples=len(samples),
                               dropped_frames=0, distinct_audio_pids=sorted({s['pid'] for s in samples}))
        except Exception as error:
            self.report['failure'] = str(error)
            try:
                self.command('capture', filename='failure-launcher.png')
                for package, item in self.windows.items():
                    self.capture(item['window'], 'failure-' + package.rsplit('.', 1)[-1])
            except Exception:
                pass
            raise
        finally:
            self.cleanup()

    def cleanup(self):
        cleanup_errors = []
        if self.child and self.child.poll() is None:
            try:
                self.command('quit')
                self.child.wait(timeout=45)
            except Exception as error:
                cleanup_errors.append('Graceful quit: ' + str(error))
                self.child.terminate()
                try:
                    self.child.wait(timeout=35)
                except subprocess.TimeoutExpired:
                    self.child.kill()
                    self.child.wait(timeout=5)
        try:
            wait('audio client drain', lambda: not self.live_audio(), 25)
            wait('resource baseline restoration', lambda: self.resources() == self.before, 25)
            restore(self.sessions, self.session_snapshot)
            # Restore only our serial's settings; preserve every unrelated key,
            # route and physical device, including concurrent unrelated changes.
            current = json.loads(self.prefs.read_bytes()) if self.prefs.exists() else {}
            original = json.loads(self.prior_prefs[0]) if self.prior_prefs else {}
            audio_current = json.loads(self.audio_prefs.read_bytes()) if self.audio_prefs.exists() else {}
            audio_original = json.loads(self.prior_audio_prefs[0]) if self.prior_audio_prefs else {}
            routes = audio_current.get('deviceAudioRoutes', {})
            if self.prior_route_present:
                routes[self.args.serial] = self.prior_route
            else:
                routes.pop(self.args.serial, None)
            if routes or 'deviceAudioRoutes' in audio_original:
                audio_current['deviceAudioRoutes'] = routes
            else:
                audio_current.pop('deviceAudioRoutes', None)
            audio_other_routes_same = {k:v for k,v in routes.items() if k != self.args.serial} == {k:v for k,v in audio_original.get('deviceAudioRoutes', {}).items() if k != self.args.serial}
            if audio_other_routes_same:
                # New-store envelope defaults may have been materialized by the
                # first write; they have no global preference authority.
                restore(self.audio_prefs, self.prior_audio_prefs)
            else:
                restore(self.audio_prefs, (json.dumps(audio_current).encode(), self.prior_audio_prefs[1] if self.prior_audio_prefs else 0o600))
            off = set(current.get('screenOffDeviceSerials', []))
            off.add(self.args.serial) if self.prior_screen_off else off.discard(self.args.serial)
            if off or 'screenOffDeviceSerials' in original:
                current['screenOffDeviceSerials'] = sorted(off)
            else:
                current.pop('screenOffDeviceSerials', None)
            # Preserve byte identity when only our UI operations changed it.
            defaults = dict(bulkWrapperOnboardingEnabled=True, showAndroidSystemDecorations=True,
                            screenOffDeviceSerials=[], deviceAudioRoutes={})
            # Older envelope schemas may omit default-valued fields that the
            # current writer materializes. Restore original bytes for those too.
            if dict(defaults, **current) == dict(defaults, **original):
                restore(self.prefs, self.prior_prefs)
            else:
                restore(self.prefs, (json.dumps(current).encode(), self.prior_prefs[1] if self.prior_prefs else 0o600))
            for path, prior in self.control_snapshots.items():
                restore(path, prior)
            for key, value in self.geometry.items():
                if value is None:
                    subprocess.run(['defaults', 'delete', self.metadata['CFBundleIdentifier'], key], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                else:
                    run('defaults', 'write', self.metadata['CFBundleIdentifier'], key, '-string', value)
            self.set_panel(self.original_panel)
            self.report['after'] = self.resources()
            assert self.report['after'] == self.before
            settings_after = self.global_settings()
            (self.out / 'android-settings-after.json').write_text(json.dumps(settings_after, indent=2))
            assert settings_after == self.settings_before, 'Android global/input settings changed'
            self.report['system_server_pid_after'] = self.android('shell', 'pidof', 'system_server').strip()
            assert self.report['system_server_pid_after'] == self.system_server_before, 'Android system_server restarted'
            self.report['state_restored'] = True
            self.report['android_global_input_settings_unchanged'] = True
        except Exception as error:
            cleanup_errors.append(str(error))
        redactions = {}
        for path in set(self.logs.glob('*.jsonl')) - self.initial_logs:
            owned = [event for event in read_jsonl(path) if event.get('device') == self.args.serial]
            if not owned:
                continue
            (self.out / path.name).write_text(''.join(json.dumps(event) + '\n' for event in owned))
            raw = path.with_suffix('')
            if raw.exists():
                text, count = redact_inventory(raw.read_text(errors='replace'), self.args.serial)
                (self.out / raw.name).write_text(text)
                redactions[raw.name] = count
        for path in set(self.audio_dir.glob('*.log')) - self.initial_audio_logs:
            text = path.read_text(errors='replace')
            # Audio logs are shared by independent hosts. Require the exact
            # supervisor parent receipt before copying one, even if new.
            if not self.child or not re.search(r'"parent"\s*:\s*' + str(self.child.pid) + r'[,}]', text):
                continue
            sanitized, count = redact_inventory(text, self.args.serial)
            name = 'audio-' + path.name
            (self.out / name).write_text(sanitized)
            redactions[name] = count
        host_log = self.out / 'host.log'
        if host_log.exists():
            sanitized, count = redact_inventory(host_log.read_text(errors='replace'), self.args.serial)
            host_log.write_text(sanitized)
            redactions[host_log.name] = count
        self.report['unrelated_adb_inventory_rows_redacted'] = redactions
        try:
            (self.out / 'android-input.log').write_text(self.android('logcat', '-d', '-s', 'DroidBridgeProbe:I', '*:S'))
        except Exception as error:
            cleanup_errors.append('Input log: ' + str(error))
        self.report['cleanup_errors'] = cleanup_errors
        if cleanup_errors:
            self.report.update(passed=False, acceptance=False)
        (self.out / 'result.json').write_text(json.dumps(self.report, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=pathlib.Path, default=pathlib.Path.home() / 'Applications/DroidBridge.app')
    parser.add_argument('--serial', choices=['emulator-5580', 'emulator-5582'], default='emulator-5580')
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--prepare-only', action='store_true', help='compile instrumentation only; no device or preferences access')
    args = parser.parse_args()
    if args.prepare_only:
        args.output.resolve().mkdir(parents=True, exist_ok=True)
        prepare_instruments(args.app.resolve(), args.output.resolve())
        print('Prepared instruments only; no device/preferences operations')
        return
    test = NativeAudioTest(args)
    test.execute()
    print(json.dumps(test.report, indent=2))
    if not test.report['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
