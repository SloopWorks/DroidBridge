#!/usr/bin/env python3
"""TEST ONLY: two unmodified bundled scrcpy clients, public SDL event paths.

A DYLD_INSERT_LIBRARIES fixture pushes SDL mouse, text, and key events on each
client's own main thread. It never writes the scrcpy control protocol, invokes
ADB input, or substitutes a client. This verifies client event routing under a
locked desktop; OS focus/physical keyboard delivery is a separate claim.
"""
import argparse, hashlib, json, os, pathlib, re, shutil, subprocess, time
p = argparse.ArgumentParser()
p.add_argument('app', type=pathlib.Path)
p.add_argument('--output', type=pathlib.Path, default=pathlib.Path('verification/review/sdl-input'))
p.add_argument('--build-only', action='store_true')
args = p.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
shim = out / 'verify-sdl-input.dylib'
subprocess.run(['clang','-dynamiclib','-Wall','-Wextra','-I/opt/homebrew/include','-undefined','dynamic_lookup',str(root/'scripts/verify-sdl-input.c'),'-o',str(shim)], check=True)
subprocess.run(['codesign','--force','--sign','-',str(shim)], check=True)
if args.build_only:
    print(json.dumps({'test_shim':str(shim),'built':True})); raise SystemExit(0)
runtime = args.app.resolve()/'Contents/Resources/Runtime'
adb = runtime/'bin/adb'; player = runtime/'Player.app/Contents/MacOS/scrcpy'
ffmpeg = shutil.which('ffmpeg'); ffprobe = shutil.which('ffprobe')
assert ffmpeg and ffprobe, 'FFmpeg inspection tools required for test evidence'
def android(*command):
    return subprocess.check_output([str(adb),'-s','emulator-5580',*command], text=True, stderr=subprocess.STDOUT, timeout=12)
def display_count(): return android('shell','dumpsys','display').count('DisplayDeviceInfo{')
assert android('shell','getprop','sys.boot_completed').strip() == '1'
baseline_forward=android('forward','--list'); baseline_reverse=android('reverse','--list'); baseline_display=display_count()
android('logcat','-c')
processes=[]; results=[]
try:
    for index,word in enumerate(('1SDLFirst','2SDLSecond')):
        pkg='dev.droidbridge.testapp'+('2' if index else '')
        environment=os.environ.copy(); environment['PATH']='/usr/bin:/bin'
        environment['ADB']=str(adb); environment['SCRCPY_SERVER_PATH']=str(runtime/'share/scrcpy/scrcpy-server')
        environment['DYLD_INSERT_LIBRARIES']=str(shim); environment['DROIDBRIDGE_SDL_WORD']=word
        log=(out/f'player-{index}.log').open('w')
        command=[str(player),'--serial','emulator-5580','--new-display=720x1080/240','--window-width=480','--window-height=720','--no-audio','--start-app=+'+pkg,'--window-title=SDL client event QA '+str(index),'--time-limit=14','--record='+str(out/f'player-{index}.mkv')]
        process=subprocess.Popen(command,env=environment,stdout=log,stderr=log)
        processes.append((process,log,pkg,word))
    deadline=time.monotonic()+25
    while time.monotonic()<deadline:
        if all(process.poll() is not None for process,_,_,_ in processes): break
        time.sleep(.2)
finally:
    for process,log,_,_ in processes:
        if process.poll() is None: process.terminate()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: process.kill(); process.wait()
        log.close()
    cleanup_started=time.monotonic()
    while time.monotonic()-cleanup_started<5:
        if android('forward','--list')==baseline_forward and android('reverse','--list')==baseline_reverse and display_count()==baseline_display: break
        time.sleep(.2)
    receipt=android('logcat','-d','-s','DroidBridgeProbe:I','*:S')
    (out/'android-input.log').write_text(receipt)
    cleanup={'forward_restored':android('forward','--list')==baseline_forward,'reverse_restored':android('reverse','--list')==baseline_reverse,'display_restored':display_count()==baseline_display}
    (out/'cleanup.json').write_text(json.dumps(cleanup,indent=2)+'\n')
    assert all(cleanup.values()), cleanup
for index,(process,_,pkg,word) in enumerate(processes):
    text=(out/f'player-{index}.log').read_text()
    assert process.returncode==0, text
    match=re.search(r'Starting app .* on display (\d+)',text); assert match, text
    display=match[1]
    assert '"main_thread":true' in text and '"test":"SDL_input_complete"' in text, text
    assert any('click=1 display='+display in line for line in receipt.splitlines()), 'no mouse receipt for '+display
    assert any('text='+word+' display='+display in line for line in receipt.splitlines()), 'no SDL text receipt for '+display
    assert any('text='+word+'k display='+display in line for line in receipt.splitlines()), 'no SDL raw-key receipt for '+display
    video=out/f'player-{index}.mkv'
    details=json.loads(subprocess.check_output([ffprobe,'-v','error','-count_frames','-select_streams','v:0','-show_entries','stream=codec_name,width,height,nb_read_frames','-of','json',str(video)],text=True))
    frames=int(details['streams'][0]['nb_read_frames']); assert frames>30, details
    hashes=[]
    for second in (1,7):
        png=out/f'player-{index}-{second}s.png'
        subprocess.run([ffmpeg,'-y','-v','error','-ss',str(second),'-i',str(video),'-frames:v','1',str(png)],check=True)
        hashes.append(hashlib.sha256(png.read_bytes()).hexdigest())
    assert len(set(hashes))==2,'recorded live content did not change'
    results.append({'package':pkg,'display':int(display),'player_pid':process.pid,'word':word,'mouse_received':True,'SDL_text_received':True,'SDL_raw_key_received':True,'recorded_frames':frames,'video':details,'frame_sha256':hashes,'client_sha256':hashlib.sha256(player.read_bytes()).hexdigest(),'input_evidence':'TEST ONLY: public SDL_PushEvent on SDL main thread; no OS-focus claim'})
assert len({r['display'] for r in results})==2
(out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
