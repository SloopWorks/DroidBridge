#!/usr/bin/env python3
"""Dedicated emulator feasibility: two real scrcpy virtual displays + main panel OFF.
Test-only public SDL events enter the unmodified clients after OFF is observed.
"""
import json, os, pathlib, re, subprocess, time
ROOT = pathlib.Path(__file__).resolve().parents[3]
serial = os.environ.get('DROIDBRIDGE_TEST_SERIAL', 'emulator-5580')
assert serial in ('emulator-5580', 'emulator-5582')
adb_bin = str(pathlib.Path.home()/'Library/Android/sdk/platform-tools/adb')
def adb(*args): return subprocess.check_output([adb_bin, '-s', serial, *args], text=True, stderr=subprocess.STDOUT, timeout=15)
api = adb('shell', 'getprop', 'ro.build.version.sdk').strip()
local_ime = os.environ.get('DROIDBRIDGE_TEST_LOCAL_IME') == '1'
evidence_suffix = os.environ.get('DROIDBRIDGE_TEST_EVIDENCE_SUFFIX', '')
assert not evidence_suffix or re.fullmatch(r'-[a-z0-9-]{1,40}', evidence_suffix)
control_on = os.environ.get('DROIDBRIDGE_CONTROL_PANEL_ON') == '1'
out = ROOT/'verification/screen-off/android'/('api'+api+('-control-panel-on' if control_on else '')+('-local-ime' if local_ime else '')+evidence_suffix); out.mkdir(parents=True, exist_ok=True)
(out/'external-results.json').unlink(missing_ok=True)
def facts(name):
    value = adb('shell', 'cmd', 'display', 'get-displays'); (out/name).write_text(value); return value
def state(text, display_id=0):
    line = next(line for line in text.splitlines() if line.startswith(f'Display id {display_id}:'))
    return re.search(r'\bstate ([A-Z_]+)', line).group(1)
def await_state(wanted, name, ids=()):
    for _ in range(30):
        value = facts(name)
        if state(value) == wanted and all(state(value, i) == 'ON' for i in ids): return value
        time.sleep(.2)
    raise AssertionError((wanted, value))
def own_forward(): return set(line for line in adb('forward', '--list').splitlines() if line.startswith(serial+' '))
def display_count(): return adb('shell', 'dumpsys', 'display').count('DisplayDeviceInfo{')
original = state(facts('external-baseline-displays.txt'))
assert original in ('ON', 'OFF')
baseline_forward, baseline_reverse, baseline_count = own_forward(), adb('reverse', '--list'), display_count()
settings_before = adb('shell', 'settings', 'get', 'global', 'stay_on_while_plugged_in') + adb('shell', 'settings', 'get', 'system', 'screen_off_timeout')
(out/'external-settings-before.txt').write_text(settings_before)
triggers = [ROOT/'.build'/('screen-off-trigger-'+serial+'-'+str(i)) for i in range(2)]
for trigger in triggers: trigger.unlink(missing_ok=True)
processes = []; ids = []; changed = False; started = time.monotonic(); off_time = None; first_close = None; first_close_second_pts = None
try:
    adb('logcat', '-c')
    for index, word in enumerate(('1ScreenOffA', '2ScreenOffB')):
        package = 'dev.droidbridge.testapp' + ('2' if index else '')
        environment = os.environ.copy(); environment.update(ADB=adb_bin, DYLD_INSERT_LIBRARIES=str(ROOT/'.build/screen-off-sdl.dylib'), DROIDBRIDGE_SDL_WORD=word, DROIDBRIDGE_SDL_TRIGGER=str(triggers[index]))
        command = ['/opt/homebrew/bin/scrcpy', '--serial', serial, '--new-display=720x1080/240', '--window-width=480', '--window-height=720', '--no-vd-system-decorations', '--no-audio', '--keep-active', '--no-power-on', '--start-app='+package, '--record='+str(out/f'external-{index}.mkv')]
        if local_ime: command += ['--display-ime-policy=local']
        (out/f'external-{index}-command.json').write_text(json.dumps(command, indent=2)+'\n')
        log = (out/f'external-{index}.log').open('w')
        process = subprocess.Popen(command, env=environment, stdout=log, stderr=log)
        processes.append((process, log))
        # Pinned upstream installs reverse forwarding before binding its local
        # listener. Start sequentially to avoid the independently recorded
        # same-port startup race; both streams coexist throughout OFF testing.
        for _ in range(80):
            launched = (out/f'external-{index}.log').read_text()
            if re.search(r'Starting app .*\['+re.escape(package)+r'\] on display (\d+)', launched): break
            assert process.poll() is None, launched
            time.sleep(.2)
        else: raise AssertionError('No package-specific startup: '+launched)
    for _ in range(60):
        texts = [(out/f'external-{i}.log').read_text() for i in range(2)]
        matches = [re.search(r'Starting app .* on display (\d+)', value) for value in texts]
        if all(matches): ids = [int(match.group(1)) for match in matches]; break
        assert all(p.poll() is None for p, _ in processes)
        time.sleep(.2)
    assert len(set(ids)) == 2, texts
    expected_panel = 'ON' if control_on else 'OFF'
    if not control_on:
        adb('shell', 'cmd', 'display', 'power-off', '0'); changed = original == 'ON'
    await_state(expected_panel, 'external-off-displays.txt', ids); off_time = time.monotonic()-started
    (out/'external-off-power.txt').write_text(adb('shell', 'dumpsys', 'power'))
    time.sleep(12)
    await_state(expected_panel, 'external-off-after-idle-displays.txt', ids)
    # A user types into one focused Mac application at a time. Stagger the
    # clients rather than racing Android's shared IME focus across processes.
    for trigger, word, display_id in zip(triggers, ('1ScreenOffA', '2ScreenOffB'), ids):
        trigger.touch()
        for _ in range(50):
            receipt = adb('logcat', '-d', '-s', 'DroidBridgeProbe:I', '*:S')
            if f'text={word}k display={display_id}' in receipt: break
            time.sleep(.2)
        if f'text={word}k display={display_id}' not in receipt:
            (out/'external-failed-input.log').write_text(receipt)
            (out/'external-failed-input-state.txt').write_text(adb('shell', 'dumpsys', 'input'))
            (out/'external-failed-window-state.txt').write_text(adb('shell', 'dumpsys', 'window', 'windows'))
        assert f'text={word}k display={display_id}' in receipt, receipt
    (out/'external-input.log').write_text(receipt)
    for word, display_id in zip(('1ScreenOffA', '2ScreenOffB'), ids):
        assert f'click=1 display={display_id}' in receipt and f'text={word}k display={display_id}' in receipt, receipt
    await_state(expected_panel, 'external-off-after-input-displays.txt', ids)
    processes[0][0].terminate(); processes[0][0].wait(timeout=5); first_close = time.monotonic()-started
    # Recording PTS begins at each client's first frame, not at the host
    # harness start. Sample the second stream's own clock at the close boundary.
    with (out/'external-second-close-boundary-probe.log').open('w') as probe_log:
        boundary_frames = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'frame=pts_time', '-of', 'json', str(out/'external-1.mkv')], text=True, stderr=probe_log, timeout=5))['frames']
    assert boundary_frames, 'No second-stream frame at first-client close'
    first_close_second_pts = max(float(f.get('pts_time', '0')) for f in boundary_frames)
    (out/'external-second-close-boundary.json').write_text(json.dumps(dict(lastFramePTSAtFirstClose=first_close_second_pts, hostSecondsAtFirstClose=first_close), indent=2)+'\n')
    time.sleep(2)
    assert processes[1][0].poll() is None
    await_state(expected_panel, 'external-off-one-session-closed.txt', [ids[1]])
finally:
    for p, log in processes:
        if p.poll() is None: p.terminate()
        try: p.wait(timeout=5)
        except subprocess.TimeoutExpired: p.kill(); p.wait()
        log.close()
    if changed:
        if int(api) >= 37:
            adb('shell', 'cmd', 'display', 'power-reset', '0')
            if state(facts('external-reset-displays.txt')) != 'ON': adb('shell', 'cmd', 'power', 'wakeup', '--display-id', '0')
        else: adb('shell', 'cmd', 'display', 'power-on', '0')
        await_state('ON', 'external-restored-displays.txt')
    for trigger in triggers: trigger.unlink(missing_ok=True)
settings_after = adb('shell', 'settings', 'get', 'global', 'stay_on_while_plugged_in') + adb('shell', 'settings', 'get', 'system', 'screen_off_timeout')
(out/'external-settings-after.txt').write_text(settings_after)
assert settings_before == settings_after
cleanup = dict(forward=own_forward() == baseline_forward, reverse=adb('reverse', '--list') == baseline_reverse, displays=display_count() == baseline_count)
assert all(cleanup.values()), cleanup
streams = []
for i in range(2):
    media = out/f'external-{i}.mkv'
    frames = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'frame=pts_time', '-of', 'json', str(media)], text=True))['frames']
    off_frames = [f for f in frames if float(f.get('pts_time', '0')) >= off_time + .5]
    assert len(off_frames) > 30, len(off_frames)
    hashes = subprocess.check_output(['ffmpeg', '-v', 'error', '-ss', str(off_time+1), '-i', str(media), '-f', 'framemd5', '-'], text=True)
    distinct = len(set(line.split(',')[-1].strip() for line in hashes.splitlines() if not line.startswith('#')))
    assert distinct > 10, distinct
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-ss', str(off_time+3), '-i', str(media), '-frames:v', '1', str(out/f'external-{i}-panel-off.png')], check=True)
    streams.append(dict(displayID=ids[i], totalFrames=len(frames), framesAfterPanelOff=len(off_frames), distinctFramesAfterPanelOff=distinct))
assert max(float(f.get('pts_time', '0')) for f in frames) > first_close_second_pts+.5, 'Second recording did not produce later source timestamps after first-client close'
(out/'external-results.json').write_text(json.dumps(dict(api=api, serial=serial, originalPanel=original, idleSeconds=12, physicalPanelOffObserved=not control_on, panelOnControl=control_on, localIME=local_ime, displayIDs=ids, streams=streams, twoAppInput=True, firstCloseLeftOtherStreamActive=True, secondStreamPTSAtFirstClose=first_close_second_pts, secondStreamLastPTS=max(float(f.get('pts_time', '0')) for f in frames), settingsUnchanged=True, cleanup=cleanup), indent=2)+'\n')
print((out/'external-results.json').read_text())
