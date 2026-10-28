#!/usr/bin/env python3
"""Real unmodified scrcpy client, public SDL test events, actual recorded frames.
This test never claims physical keyboard/macOS focus delivery under a locked desktop.
"""
import json, os, pathlib, re, subprocess, time
ROOT = pathlib.Path(__file__).resolve().parents[2]
SERIAL = os.environ.get('DROIDBRIDGE_TEST_SERIAL', 'emulator-5580')
assert SERIAL in ('emulator-5580', 'emulator-5582')
ADB = str(pathlib.Path.home()/'Library/Android/sdk/platform-tools/adb')
def adb(*args): return subprocess.check_output([ADB, '-s', SERIAL, *args], text=True, stderr=subprocess.STDOUT, timeout=15)
api = adb('shell', 'getprop', 'ro.build.version.sdk').strip()
out = ROOT/'verification/desktop-mode'/('api'+api); out.mkdir(parents=True, exist_ok=True)
def own_forwards(output): return set(line for line in output.splitlines() if line.startswith(SERIAL+' '))
baseline_forward = own_forwards(adb('forward', '--list'))
baseline_reverse = adb('reverse', '--list')
baseline_displays = adb('shell', 'dumpsys', 'display').count('DisplayDeviceInfo{')
results = []
for decorations in (True, False):
    label = 'decorated' if decorations else 'desktop'
    adb('logcat', '-c')
    environment = os.environ.copy()
    environment.update(DYLD_INSERT_LIBRARIES=str(ROOT/'.build/desktop-sdl.dylib'), DROIDBRIDGE_SDL_WORD='1Desktop'+label)
    args = ['/opt/homebrew/bin/scrcpy', '--serial', SERIAL, '--new-display=720x1080/240', '--window-width=480', '--window-height=720', '--no-audio', '--start-app=dev.droidbridge.testapp', '--shortcut-mod=lctrl', '--time-limit=11', '--record='+str(out/f'external-{label}.mkv')]
    if not decorations: args += ['--no-vd-system-decorations']
    (out/f'external-{label}-command.json').write_text(json.dumps(args, indent=2)+'\n')
    with (out/f'external-{label}-session.log').open('w') as log:
        process = subprocess.Popen(args, env=environment, stdout=log, stderr=log)
        try:
            time.sleep(2)
            assert process.poll() is None, 'scrcpy exited before measurement'
            (out/f'external-{label}-display.txt').write_text(adb('shell', 'dumpsys', 'display'))
            (out/f'external-{label}-windows.txt').write_text(adb('shell', 'dumpsys', 'window', 'displays'))
            process.wait(timeout=18)
        finally:
            if process.poll() is None: process.terminate(); process.wait(timeout=5)
    assert process.returncode == 0
    receipt = adb('logcat', '-d', '-s', 'DroidBridgeProbe:I', '*:S')
    (out/f'external-{label}-input.log').write_text(receipt)
    expected = 'text=1Desktop'+label+'k'
    assert 'click=' in receipt and expected in receipt, receipt
    assert 'secondary display=' in receipt, receipt
    stream = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-count_frames', '-show_entries', 'stream=width,height,nb_read_frames', '-of', 'json', str(out/f'external-{label}.mkv')], text=True))['streams'][0]
    assert int(stream['nb_read_frames']) > 20, stream
    sizes = subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'frame=width,height', '-of', 'csv=p=0', str(out/f'external-{label}.mkv')], text=True)
    distinct_sizes = sorted(set(sizes.splitlines()))
    # Fixed client geometry isolates initial public SDL input; a second adaptive
    # pass below verifies flex display separately.
    # assert len(distinct_sizes) > 1, distinct_sizes
    for second in (1, 5.5, 8):
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-ss', str(second), '-i', str(out/f'external-{label}.mkv'), '-frames:v', '1', str(out/f'external-{label}-{second}s.png')], check=True)
    text = (out/f'external-{label}-session.log').read_text()
    assert '"SDL_resize","success":true' in text
    results.append(dict(decorations=decorations, frames=int(stream['nb_read_frames']), frameSizes=distinct_sizes, mouseKeyboard=True, backEventSent=True, backResult='Inspect recorded after-Back PNG; API37 may retain secondary activity'))
    # Independently verify adaptive display resize using the same actual client,
    # now with --flex-display and only public SDL window-resize input.
    flex_args = ['/opt/homebrew/bin/scrcpy', '--serial', SERIAL, '--new-display=720x1080/240', '--flex-display', '--no-audio', '--start-app=dev.droidbridge.testapp', '--time-limit=4', '--record='+str(out/f'external-{label}-flex.mkv')]
    if not decorations: flex_args += ['--no-vd-system-decorations']
    flex_env = environment.copy(); flex_env['DROIDBRIDGE_DESKTOP_RESIZE_ONLY'] = '1'
    with (out/f'external-{label}-flex.log').open('w') as flex_log:
        subprocess.run(flex_args, env=flex_env, stdout=flex_log, stderr=flex_log, timeout=12, check=True)
    flex_sizes = sorted(set(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'frame=width,height', '-of', 'csv=p=0', str(out/f'external-{label}-flex.mkv')], text=True).splitlines()))
    assert len(flex_sizes) > 1, flex_sizes
    results[-1]['flexDisplaySizes'] = flex_sizes
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-ss', '2.8', '-i', str(out/f'external-{label}-flex.mkv'), '-frames:v', '1', str(out/f'external-{label}-flex-resized.png')], check=True)
time.sleep(.8)
cleanup = dict(forward=own_forwards(adb('forward', '--list')) == baseline_forward, reverse=adb('reverse', '--list') == baseline_reverse, displays=adb('shell', 'dumpsys', 'display').count('DisplayDeviceInfo{') == baseline_displays)
assert all(cleanup.values()), cleanup
(out/'external-results.json').write_text(json.dumps(dict(api=api, serial=SERIAL, backend='scrcpy', results=results, cleanup=cleanup), indent=2)+'\n')
print(json.dumps(results, indent=2))
