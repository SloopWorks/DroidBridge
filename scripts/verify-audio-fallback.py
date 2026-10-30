#!/usr/bin/env python3
"""Installed fallback audio and copied-wrapper ownership acceptance.

Run only after exclusive emulator AND shared preferences/session handoff. Main
apps launch from real public launcher target/actions. SDL input is injected into
the exact unchanged bundled Player's public main-thread event queue; no physical
OS focus is claimed. Only a record flag is appended to video argv. Audio argv is
unchanged; an exec-only proxy observes successful SDL PCM submissions from the
exact bundled client, retaining aggregate synthetic tone metrics, never PCM.
"""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
import pathlib
import plistlib
import re
import shlex
import shutil
import signal
import subprocess
import struct
import sys
import time
import uuid

REPO = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('audio_native_helpers', REPO/'scripts/verify-audio-native.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
run, wait, read_jsonl, snapshot, restore = native.run, native.wait, native.read_jsonl, native.snapshot, native.restore
ORIGINAL_PREPARE = native.prepare_instruments


def prepare(app, output):
    base = ORIGINAL_PREPARE(app, output)
    runtime = app/'Contents/Resources/Runtime'
    actions, pump = output/'player-actions.dylib', output/'player-pump.dylib'
    capture = output/'player-capture.dylib'
    flags = shlex.split(run('/opt/homebrew/bin/pkg-config', '--cflags', 'sdl3'))
    run('clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit', *flags,
        REPO/'scripts/verify-hidden-ime-fallback.m', '-o', actions)
    run('clang', '-dynamiclib', *flags, REPO/'scripts/verify-hidden-ime-fallback-sdl.c',
        base[4], '-Wl,-headerpad_max_install_names', '-o', pump)
    run('clang', '-dynamiclib', *flags, REPO/'scripts/verify-audio-player-capture.c',
        base[4], '-o', capture)
    run('codesign', '--force', '--sign', '-', capture)
    run('codesign', '--force', '--sign', '-', actions)
    run('codesign', '--force', '--sign', '-', pump)
    sources=[pathlib.Path(__file__),REPO/'scripts/verify-audio-player-capture.c',REPO/'scripts/verify-hidden-ime-fallback.m',REPO/'scripts/verify-hidden-ime-fallback-sdl.c']
    (output/'fallback-instrument-sources.json').write_text(json.dumps({str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},indent=2))
    shutil.copy2(__file__,output/'fallback-driver-snapshot.py')
    player = runtime/'Player.app/Contents/MacOS/scrcpy'
    proxy = output/'player-proxy'
    configuration = dict(player=str(player), root=str(output/'players'),
                         dylibs=str(actions)+':'+str(pump)+':'+str(capture), libraries=str(runtime/'lib'))
    proxy.write_text('#!'+sys.executable+'\nconfig='+repr(configuration)+'\n'+'''import json,os,pathlib,sys,time
argv=sys.argv[1:]; env=dict(os.environ)
package=next((a.split("=",1)[1] for a in argv if a.startswith("--start-app=")),None)
if package:
 root=pathlib.Path(config["root"])/package;root.mkdir(parents=True,exist_ok=True)
 (root/"production-argv.json").write_text(json.dumps(argv,indent=2))
 (root/"started.json").write_text(json.dumps(dict(pid=os.getpid(),time=time.time(),player=config["player"])))
 extra=["--record="+str(root/"video.mkv")]
 (root/"launched-argv.json").write_text(json.dumps(argv+extra,indent=2))
 argv+=extra
 env.update(DYLD_INSERT_LIBRARIES=config["dylibs"],DYLD_LIBRARY_PATH=config["libraries"],DROIDBRIDGE_HIDDEN_IME_QA=str(root),DROIDBRIDGE_HIDDEN_INPUT="sdl",DROIDBRIDGE_AUDIO_PLAYER_CAPTURE_ROOT=str(root))
else:env.pop("DYLD_INSERT_LIBRARIES",None)
os.execve(config["player"],[config["player"]]+argv,env)
''')
    proxy.chmod(0o700)
    return (*base, proxy)


class FallbackAudioTest(native.NativeAudioTest):
    def __init__(self, args):
        super().__init__(args)
        self.players = {}
        self.player_number = 0
        self.report['backend'] = 'scrcpy'
        self.report['driver_sha256']=hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest()
        self.report['player_sha256']=hashlib.sha256((self.app/'Contents/Resources/Runtime/Player.app/Contents/MacOS/scrcpy').read_bytes()).hexdigest()
        self.report['instrumentation'] = 'Public launcher actions; public SDL event queue; fresh public SDL renderer readback; record-only video; successful SDL PCM aggregates'

    def player_command(self, package, action, **fields):
        self.player_number += 1
        root = self.out/'players'/package
        receipt = root/f'player-receipt-{self.player_number}.json'
        temporary = root/'player-command.tmp'
        temporary.write_text(json.dumps(dict(id=self.player_number, action=action, **fields)))
        temporary.replace(root/'player-command.json')
        wait('Player '+action, receipt.exists, 20)
        value = json.loads(receipt.read_text())
        assert value['passed'] and value['main_thread'], value
        return value

    def capture(self, window, label):
        package=next(p for p,item in self.windows.items() if item['window']==window)
        root=self.out/'players'/package
        self.capture_number=getattr(self,'capture_number',0)+1
        number=self.capture_number
        temporary=root/'capture-request.tmp'
        temporary.write_text(str(number)+'\n');temporary.replace(root/'capture-request')
        def acknowledged():
            try:
                value=json.loads((root/'capture-ack.json').read_text())
                return value if value.get('id')==number else None
            except (FileNotFoundError,json.JSONDecodeError):return None
        receipt=wait('fresh actual SDL renderer readback '+label,acknowledged,15)
        assert receipt['passed'] and receipt['main_thread'] and receipt['pid']==self.windows[package]['player_pid'],receipt
        assert receipt['capture_method']=='SDL_RenderReadPixels-before-SDL_RenderPresent' and receipt['renderer'],receipt
        destination=self.out/(label+'.png')
        run(shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg','-v','error','-y',
            '-i',root/'frame.bmp','-frames:v','1',destination,timeout=15)
        assert struct.unpack('>II',destination.read_bytes()[16:24])==(receipt['width'],receipt['height'])
        assert (receipt['width'],receipt['height'])==(receipt['output_width'],receipt['output_height']),receipt
        texture_log=pathlib.Path(self.windows[package]['log']).read_text()
        textures=re.findall(r'Texture(?: \(VideoToolbox\))?: (\d+)x(\d+)',texture_log)
        receipt['last_android_texture']=textures[-1] if textures else None
        rows=json.loads(run(self.ocr,destination))
        assert rows,'Fresh actual renderer contained no readable content'
        (self.out/(label+'-ocr.json')).write_text(json.dumps(rows,indent=2))
        (self.out/(label+'-video-frame.json')).write_text(json.dumps(dict(receipt,
            capture='SDL_RenderReadPixels before original SDL_RenderPresent',
            production_player_sha256=self.report['player_sha256'],package=package),indent=2))
        return rows

    def capture_recorded(self, window, label):
        package = next(p for p, item in self.windows.items() if item['window'] == window)
        recording = self.out/'players'/package/'video.mkv'
        destination = self.out/(label+'.png')
        ffmpeg = shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
        ffprobe = shutil.which('ffprobe') or '/opt/homebrew/bin/ffprobe'
        def decode():
            try:
                log=pathlib.Path(self.windows[package]['log']).read_text()
                textures=re.findall(r'Texture(?: \(VideoToolbox\))?: (\d+)x(\d+)',log)
                if not textures:return None
                expected=tuple(map(int,textures[-1]))
                destination.unlink(missing_ok=True)
                # An unfinished Matroska has no reliable seek index. Decode the
                # available bytes in order and retain the LAST real frame. PNG
                # encoder dimensions otherwise stay at the initial stream size;
                # verify source showinfo dimensions before rendering at current
                # Texture size, so a pre-resize frame cannot pass this check.
                trace=run(ffmpeg, '-v', 'info', '-y', '-i', recording,
                    '-vf', f'fps=2,showinfo,scale={expected[0]}:{expected[1]}',
                    '-update', '1', destination, timeout=30)
                sources=re.findall(r'Parsed_showinfo[^\n]*pts_time:([^ ]+)[^\n]* s:(\d+)x(\d+)',trace)
                (self.out/(label+'-decode-attempt.json')).write_text(json.dumps(dict(expected=expected,sources_tail=sources[-2:],recording_bytes=recording.stat().st_size),indent=2))
                if not sources or tuple(map(int,sources[-1][1:]))!=expected:return None
                if not destination.exists():return None
                png=destination.read_bytes()
                if len(png)<24 or png[:8]!=b'\x89PNG\r\n\x1a\n':return None
                dimensions=struct.unpack('>II',png[16:24])
                if dimensions!=expected:return None
                (self.out/(label+'-video-frame.json')).write_text(json.dumps(dict(
                    source_dimensions=expected,last_source_pts=sources[-1][0],
                    recording=str(recording),sequential_last_frame=True),indent=2))
                rows = json.loads(run(self.ocr, destination))
                if not rows:
                    return None
                return rows
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError) as error:
                (self.out/(label+'-decode-error.txt')).write_text(str(error)+'\n'+str(getattr(error,'output',''))[-3000:])
                return None
        rows = wait('actual recorded frame '+label, decode, 60)
        (self.out/(label+'-ocr.json')).write_text(json.dumps(rows, indent=2))
        return rows

    def launch(self, package):
        self.command('search', query=package)
        wait('filtered app '+package, lambda:self.command('status')['rows']>=1)
        before = {e.get('session') for e in self.events()}
        self.command('launch', package=package, backend='scrcpy')
        event = wait('real fallback app and renderer', lambda:next((e for e in reversed(self.events())
                     if e.get('package')==package and e.get('backend')=='scrcpy'
                     and e.get('state')=='running' and e.get('session') not in before),None),60)
        self.bind_fallback(package,event)

    def bind_fallback(self,package,event):
        log = self.logs/f'session-{event["session"]}.log'
        display = int(wait('exact fallback display binding',lambda:((m.group(1) if
                      (m:=re.search(r'Starting app .*?\['+re.escape(package)+r'\] on display (\d+)',log.read_text())) else None))))
        status = self.player_command(package, 'status')
        actual=run('/bin/ps','-ww','-p',status['pid'],'-o','command=')
        assert str(self.app/'Contents/Resources/Runtime/Player.app/Contents/MacOS/scrcpy') in actual and package in actual
        self.windows[package] = dict(window=status['window'],session=event['session'],display=display,
                                     player_pid=status['pid'],log=str(log))
        production = json.loads((self.out/'players'/package/'production-argv.json').read_text())
        launched = json.loads((self.out/'players'/package/'launched-argv.json').read_text())
        assert launched == production+['--record='+str(self.out/'players'/package/'video.mkv')]
        assert '--no-audio' in production and '--display-ime-policy=hide' in production
        assert '--no-mouse-hover' in production
        self.player_command(package,'resize',width=720,height=1080)
        wait('actual tone button rendered',lambda:any('play test tone' in r['text'].lower()
             for r in self.capture(status['window'],'launched-'+package.rsplit('.',1)[-1])),35)

    def click(self, package, phrase, label):
        window = self.windows[package]['window']
        rows = self.capture(window,label)
        point = next((r for r in rows if phrase.casefold() in r['text'].casefold()),None)
        assert point, (phrase,rows)
        before = self.android('logcat','-d','-s','DroidBridgeProbe:I','*:S')
        self.player_command(package,'click',x=point['x'],y=point['y'])
        display=self.windows[package]['display']
        if phrase=='Play test tone':
            marker='tone_started frequency='+str(1499 if package.endswith('2') else 997)+' display='+str(display)
            count=before.count(marker)
            wait('NEW display-specific SDL tone receipt',lambda:self.android('logcat','-d','-s','DroidBridgeProbe:I','*:S').count(marker)>count,10)
        self.assert_no_tone_failure()
        return point

    def video_alive(self,label):
        label=label.replace('native','fallback')
        if label=='panel-off-continued-frames':
            for package in self.windows:self.player_command(package,'resize',width=840,height=1100)
        for package,item in self.windows.items():
            self.player_command(package,'status')
            first=self.capture(item['window'],label+'-'+package.rsplit('.',1)[-1])
            ticks=[r['text'] for r in first if 'ticks' in r['text'].lower()]
            assert ticks,first
            initial_tick=int(re.search(r'ticks\s+(\d+)',ticks[0],re.I).group(1))
            # An unfinished MKV exposes newly flushed clusters, rather than every
            # decoded SDL frame. Require eventual NEW content from this recording;
            # two instant seeks can legitimately land on the same available tick.
            started=time.monotonic()
            def changed():
                assert not any(e.get('session')==item['session'] and e.get('state') in ('failed','stopped') for e in self.events())
                second=self.capture(item['window'],label+'-updated-'+package.rsplit('.',1)[-1])
                current=[r['text'] for r in second if 'ticks' in r['text'].lower()]
                match=re.search(r'ticks\s+(\d+)',current[0],re.I) if current else None
                return current if match and int(match.group(1))>initial_tick else None
            current=wait('NEW recorded video tick '+package,changed,40)
            self.report.setdefault('video_updates',[]).append(dict(label=label,package=package,
                before=ticks,after=current,wait_seconds=round(time.monotonic()-started,3)))

    def sample_phase(self,*args,**kwargs):
        super().sample_phase(*args,**kwargs)
        pids={item['pid'] for item in self.live_audio()}
        pids.update(item['player_pid'] for item in self.windows.values())
        if self.child and self.child.poll() is None:pids.add(self.child.pid)
        observation=subprocess.run(['/bin/ps','-p',','.join(map(str,pids)),
            '-o','pid=,ppid=,%cpu=,rss=,etime=,comm='],capture_output=True,text=True)
        self.report.setdefault('resource_observations',[]).append(dict(phase=args[0],
            processes=observation.stdout.splitlines(),rss_unit='KiB',cpu_unit='percent',
            observational_not_acceptance=True))

    def cleanup(self):
        super().cleanup()
        if not self.report.get('state_restored') and (not self.child or self.child.poll() is not None):
            # A dead/unbootable emulator must not prevent local intent recovery.
            # Exclusive runtime scope means no unrelated writer is admitted.
            restored=[]
            for path,prior in [(self.sessions,self.session_snapshot),(self.prefs,self.prior_prefs),(self.audio_prefs,self.prior_audio_prefs),*self.control_snapshots.items()]:
                path.parent.mkdir(parents=True,exist_ok=True)
                with path.with_suffix(path.suffix+'.lock').open('a') as lock:
                    fcntl.flock(lock,fcntl.LOCK_EX);restore(path,prior)
                restored.append(path.name)
            self.report['local_state_restored_after_device_failure']=restored
            (self.out/'result.json').write_text(json.dumps(self.report,indent=2)+'\n')

    def execute(self):
        def adapted(app,out):
            shim,proxy,ocr,client,sdl,player_proxy=prepare(app,out)
            os.environ['DROIDBRIDGE_SCRCPY']=str(player_proxy)
            return shim,proxy,ocr,client,sdl
        native.prepare_instruments=adapted
        try:
            super().execute()
        finally:
            native.prepare_instruments=ORIGINAL_PREPARE
            os.environ.pop('DROIDBRIDGE_SCRCPY',None)



class WrapperOwnershipTest(FallbackAudioTest):
    main_package='dev.droidbridge.testapp2'
    wrapper_package='dev.droidbridge.testapp3'

    def command_wrapper(self,action,**fields):
        self.wrapper_number+=1
        receipt=self.wrapper_out/f'receipt-{self.wrapper_number}.json'
        temporary=self.wrapper_out/'command.tmp'
        temporary.write_text(json.dumps(dict(id=self.wrapper_number,action=action,**fields)))
        temporary.replace(self.wrapper_out/'command.json')
        wait('independent wrapper '+action,receipt.exists,20)
        result=json.loads(receipt.read_text());assert result['passed'],result
        return result

    def invocations(self):
        values=read_jsonl(self.out/'audio-argv.jsonl')
        if hasattr(self,'wrapper_out'):values+=read_jsonl(self.wrapper_out/'audio-argv.jsonl')
        return values

    def metrics(self):
        values=read_jsonl(self.out/'samples.jsonl')
        if hasattr(self,'wrapper_out'):values+=read_jsonl(self.wrapper_out/'samples.jsonl')
        assert all(v.get('dropped_frames')==0 for v in values),'Observer metrics dropped frames'
        return values

    def live_audio(self):
        result=[]
        known=getattr(self,'known_clients',{str(getattr(self,'client','')):None})
        for invocation in self.invocations():
            if invocation['client'] not in known:raise AssertionError('Unexpected audio client path')
            try:
                command=run('/bin/ps','-ww','-p',invocation['pid'],'-o','command=').strip()
                if invocation['client'] in command and '--no-video' in command:
                    result.append(invocation);self.owned_audio_pids.add(invocation['pid'])
            except subprocess.CalledProcessError:pass
        assert len(result)<=1,'Independent hosts created duplicate audio clients'
        return result

    def assert_argv(self,item,route):
        old_client,old_sdl=self.client,self.sdl
        self.client=pathlib.Path(item['client']);self.sdl=self.known_clients[item['client']]
        try:super().assert_argv(item,route)
        finally:self.client,self.sdl=old_client,old_sdl

    def wrapper_capture(self,label):
        self.command_wrapper('capture',window=self.wrapper_window,filename=label+'.png')
        image=self.wrapper_out/(label+'.png')
        rows=json.loads(run(self.ocr,image))
        (self.wrapper_out/(label+'-ocr.json')).write_text(json.dumps(rows,indent=2))
        return rows

    def wrapper_click(self,phrase,label):
        rows=wait('native wrapper actual tone button',lambda:((rows if any(phrase.lower() in r['text'].lower() for r in rows) else None)
                  if (rows:=self.wrapper_capture(label)) else None),25)
        point=next(r for r in rows if phrase.lower() in r['text'].lower())
        marker='tone_started frequency=997 display='+str(self.wrapper_display)
        before=self.android('logcat','-d','-s','DroidBridgeProbe:I','*:S').count(marker)
        self.command_wrapper('input',window=self.wrapper_window,x=point['x'],y=point['y'])
        if phrase=='Play test tone':wait('new native wrapper tone receipt',lambda:self.android('logcat','-d','-s','DroidBridgeProbe:I','*:S').count(marker)>before,10)

    def wrapper_video_alive(self,label):
        first=self.wrapper_capture(label)
        ticks=[r['text'] for r in first if 'ticks' in r['text'].lower()]
        assert ticks,first
        time.sleep(.4)
        second=self.wrapper_capture(label+'-updated')
        assert ticks!=[r['text'] for r in second if 'ticks' in r['text'].lower()],'Surviving wrapper video froze'
        assert self.wrapper_child.poll() is None

    def baseline(self):
        self.before=self.resources();self.report['before']=self.before
        self.original_panel=self.panel()
        self.input_before_lines=set(self.android('logcat','-d','-s','DroidBridgeProbe:I','*:S').splitlines())
        self.settings_before=self.global_settings()
        self.system_server_before=self.android('shell','pidof','system_server').strip()
        self.report['system_server_pid_before']=self.system_server_before
        self.session_snapshot=snapshot(self.sessions);self.prior_prefs=snapshot(self.prefs)
        self.prior_audio_prefs=snapshot(self.audio_prefs)
        original=json.loads(self.prior_prefs[0]) if self.prior_prefs else {}
        audio=json.loads(self.prior_audio_prefs[0]) if self.prior_audio_prefs else {}
        self.prior_screen_off=self.args.serial in original.get('screenOffDeviceSerials',[])
        self.prior_route_present=self.args.serial in audio.get('deviceAudioRoutes',{})
        self.prior_route=audio.get('deviceAudioRoutes',{}).get(self.args.serial)
        self.control_snapshots={self.audio_dir/(self.device_key+suffix):snapshot(self.audio_dir/(self.device_key+suffix)) for suffix in ('.retry','.failed.json')}
        self.geometry={}
        for package in (self.main_package,):
            key='NSWindow Frame AndroidApp.'+hashlib.sha256((self.args.serial+':'+package).encode()).hexdigest()
            try:self.geometry[key]=run('defaults','read',self.metadata['CFBundleIdentifier'],key).strip()
            except subprocess.CalledProcessError:self.geometry[key]=None
        self.initial_logs=set(self.logs.glob('*.jsonl'))
        self.initial_audio_logs=set(self.audio_dir.glob('*.log'))

    def execute(self):
        self.shim,self.proxy,self.ocr,self.client,self.sdl,player_proxy=prepare(self.app,self.out)
        self.known_clients={str(self.client):self.sdl}
        factory=prepare_wrapper_helper(self.out)
        self.wrapper_out=self.out/'independent-wrapper';self.wrapper_out.mkdir()
        self.wrapper_number=0;self.wrapper_child=None
        self.wrapper_root=pathlib.Path.home()/'Applications/DroidBridge Audio QA'/str(uuid.uuid4())
        factory_receipt=self.out/'wrapper-factory.json'
        run(factory,self.app,self.args.serial,self.wrapper_package,self.wrapper_root,factory_receipt,timeout=120)
        created=json.loads(factory_receipt.read_text());assert created['passed'] and created['signed_and_verified']
        wrapper=pathlib.Path(created['bundle']);wrapper_info=plistlib.loads((wrapper/'Contents/Info.plist').read_bytes())
        wshim,wproxy,wocr,wclient,wsdl=ORIGINAL_PREPARE(wrapper,self.wrapper_out)
        self.known_clients[str(wclient)]=wsdl
        assert hashlib.sha256(wclient.read_bytes()).hexdigest()==hashlib.sha256(self.client.read_bytes()).hexdigest()
        payload_hashes=[]
        for name,source in [('host',self.binary),('wrapper',wrapper/'Contents/MacOS/DroidBridge')]:
            unsigned=self.out/(name+'-unsigned-test-copy')
            shutil.copy2(source,unsigned)
            run('codesign','--remove-signature',unsigned)
            payload_hashes.append(hashlib.sha256(unsigned.read_bytes()).hexdigest())
        assert payload_hashes[0]==payload_hashes[1],'Copied wrapper executable payload differs from installed host'
        self.report['wrapper_unsigned_payload_sha256']=payload_hashes[1]
        run('codesign','--verify','--deep','--strict',self.app)
        run('codesign','--verify','--deep','--strict',wrapper)
        self.wrapper_state=self.support/('sessions-'+wrapper_info['CFBundleIdentifier']+'.json')
        self.wrapper_prior_state=snapshot(self.wrapper_state)
        key='NSWindow Frame AndroidApp.'+hashlib.sha256((self.args.serial+':'+self.wrapper_package).encode()).hexdigest()
        try:geometry=run('defaults','read',wrapper_info['CFBundleIdentifier'],key).strip()
        except subprocess.CalledProcessError:geometry=None
        self.baseline()
        self.report['factory']=created;self.report['backend']='mixed-fallback-and-native-copied-wrapper'
        try:
            self.sessions.write_text('[]')
            env=dict(os.environ,PATH='/usr/bin:/bin',DYLD_INSERT_LIBRARIES=str(self.shim),DROIDBRIDGE_LAUNCHER_QA_ROOT=str(self.out),DROIDBRIDGE_AUDIO_CLIENT=str(self.proxy),DROIDBRIDGE_SCRCPY=str(player_proxy))
            self.main_log=(self.out/'host.log').open('w')
            self.child=subprocess.Popen([str(self.binary),'--serial',self.args.serial],env=env,stdout=self.main_log,stderr=self.main_log)
            wait('main installed catalog',lambda:self.command('status')['rows']>0,60)
            self.command('select_device',serial=self.args.serial);self.panel_checkbox(False);self.set_panel('ON')
            self.select_route('phone','Phone audio');self.launch(self.main_package)
            self.select_route('mac','Mac output initialized')
            first=wait('main owns audio',self.live_audio)[0];self.assert_argv(first,'mac')
            assert first['client']==str(self.client)
            self.click(self.main_package,'Play test tone','main-1499')
            self.sample_phase('main-owner-fallback-1499',wanted=(1499,),absent=(997,))
            wenv=dict(os.environ,PATH='/usr/bin:/bin',DYLD_INSERT_LIBRARIES=str(wshim),DROIDBRIDGE_LAUNCHER_QA_ROOT=str(self.wrapper_out),DROIDBRIDGE_AUDIO_CLIENT=str(wproxy))
            self.wrapper_log=(self.wrapper_out/'host.log').open('w')
            self.wrapper_child=subprocess.Popen([str(wrapper/'Contents/MacOS/DroidBridge')],env=wenv,stdout=self.wrapper_log,stderr=self.wrapper_log)
            event=wait('independent actual native wrapper decoded frame',lambda:next((e for e in reversed(self.events()) if e.get('package')==self.wrapper_package and e.get('backend')=='native' and e.get('state')=='running'),None),60)
            window_event=wait('wrapper native window mapping',lambda:next((e for e in self.events() if e.get('session')==event['session'] and e.get('event')=='loading_window_presented'),None))
            self.wrapper_window=int(window_event['details']['window_number'])
            wrapper_video_log=self.logs/f'session-{event["session"]}.log'
            self.wrapper_display=int(wait('wrapper display binding',lambda:((m.group(1) if (m:=re.search(r'Starting app .* on display (\d+)',wrapper_video_log.read_text())) else None))))
            self.command_wrapper('resize',window=self.wrapper_window,width=480,height=720)
            shared=wait('wrapper reports shared device audio',lambda:((r if any('Shared device audio' in i['title'] for i in r['audio_menu']) else None)
                        if (r:=self.command_wrapper('audio_menu')) else None),25)
            assert [i['pid'] for i in self.live_audio()]==[first['pid']]
            identity=self.wrapper_out/'running-identity.json'
            run(factory,'--inspect',self.wrapper_child.pid,identity)
            actual=json.loads(identity.read_text());assert actual['bundle']==str(wrapper) and actual['activation_policy']==0,actual
            assert actual['bundle_identifier']==created['bundle_identifier'] and actual['bundle_identifier']!=self.metadata['CFBundleIdentifier'],actual
            self.wrapper_click('Play test tone','wrapper-shared-997')
            self.click(self.main_package,'Play test tone','main-shared-1499')
            self.sample_phase('shared-independent-apps-one-mixed-stream',wanted=(997,1499))
            self.report['phases'].append(dict(phase='copied-native-wrapper-shared-with-main-fallback',passed=True,identity=actual,shared_menu=shared['audio_menu']))
            # Crash ONLY our owned main GUI. Both its video and audio supervisors
            # must drain, while the unrelated wrapper remains alive and takes over.
            crashed_gui=self.child.pid;os.kill(crashed_gui,signal.SIGKILL);self.child.wait(timeout=5)
            successor=wait('wrapper takes audio after GUI owner crash',lambda:next((i for i in self.live_audio() if i['client']==str(wclient) and i['pid']!=first['pid']),None),35)
            wait('wrapper output ready menu',lambda:any(i['title']=='Mac output initialized' for i in self.command_wrapper('audio_menu')['audio_menu']),30)
            self.assert_argv(successor,'mac')
            self.wrapper_video_alive('wrapper-survives-owner-crash')
            self.wrapper_click('Play test tone','wrapper-owner-997')
            self.sample_phase('wrapper-successor-997-after-main-crash',wanted=(997,),absent=(1499,))
            self.command_wrapper('audio_menu',value='macAndPhone')
            duplicate=wait('wrapper Mac+Phone route via native menu',lambda:next((i for i in self.live_audio() if '--audio-dup' in i['argv']),None),35)
            wait('dup output initialized',lambda:any(i['title']=='Mac output initialized' for i in self.command_wrapper('audio_menu')['audio_menu']),30)
            self.assert_argv(duplicate,'macAndPhone')
            self.wrapper_click('Play test tone','wrapper-dup-997')
            self.sample_phase('wrapper-menu-MacAndPhone-997',wanted=(997,),absent=(1499,))
            self.command_wrapper('audio_menu',value='phone')
            wait('wrapper Phone releases only owned capture',lambda:not self.live_audio(),30)
            self.wrapper_video_alive('wrapper-phone-video-still-live')
            self.command_wrapper('quit');self.wrapper_child.wait(timeout=45)
            assert self.wrapper_child.returncode==0
            self.report['phases'].append(dict(phase='owner-crash-lease-handoff-and-native-menu-route-release',passed=True,crashed_gui_pid=crashed_gui,first_audio_pid=first['pid'],successor_audio_pid=successor['pid']))
            self.report.update(passed=True,acceptance=True,wrapper_identity=actual)
        except Exception as error:
            self.report['failure']=str(error);raise
        finally:
            if self.wrapper_child and self.wrapper_child.poll() is None:
                try:self.command_wrapper('quit');self.wrapper_child.wait(timeout=45)
                except Exception:
                    self.wrapper_child.terminate()
                    try:self.wrapper_child.wait(timeout=35)
                    except subprocess.TimeoutExpired:self.wrapper_child.kill();self.wrapper_child.wait(timeout=5)
            restore(self.wrapper_state,self.wrapper_prior_state)
            if geometry is None:subprocess.run(['defaults','delete',wrapper_info['CFBundleIdentifier'],key],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            else:run('defaults','write',wrapper_info['CFBundleIdentifier'],key,'-string',geometry)
            self.cleanup()
            if hasattr(self,'main_log'):self.main_log.close()
            if hasattr(self,'wrapper_log'):self.wrapper_log.close()
            # Remove only the owned unique QA wrapper; no managed registry is read.
            lsregister='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
            subprocess.run([lsregister,'-u',str(wrapper)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            if self.wrapper_root.parent==pathlib.Path.home()/'Applications/DroidBridge Audio QA':shutil.rmtree(self.wrapper_root,ignore_errors=True)


class DisconnectRecoveryTest(FallbackAudioTest):
    main_package='dev.droidbridge.testapp2'
    baseline=WrapperOwnershipTest.baseline

    def execute(self):
        assert self.args.serial=='emulator-5582','Actual restart is restricted to owned API37 port5582'
        assert self.android('emu','avd','name').splitlines()[0]=='DroidBridge_API37'
        self.shim,self.proxy,self.ocr,self.client,self.sdl,player_proxy=prepare(self.app,self.out)
        self.baseline()
        self.report['scenario']='Actual owned emulator shutdown/reboot; explicit audio Retry if latched'
        original_boot=self.android('shell','cat','/proc/sys/kernel/random/boot_id').strip()
        emulator=pathlib.Path.home()/'Library/Android/sdk/emulator/emulator'
        arguments=['-avd','DroidBridge_API37','-port','5582','-no-window','-no-snapshot','-gpu','auto']
        self.report['emulator_restart_argv']=[str(emulator),*arguments]
        host_output=(self.out/'host.log').open('w');emulator_output=None
        self.emulator_process=None
        try:
            self.sessions.write_text('[]')
            env=dict(os.environ,PATH='/usr/bin:/bin',DYLD_INSERT_LIBRARIES=str(self.shim),DROIDBRIDGE_LAUNCHER_QA_ROOT=str(self.out),DROIDBRIDGE_AUDIO_CLIENT=str(self.proxy),DROIDBRIDGE_SCRCPY=str(player_proxy))
            self.child=subprocess.Popen([str(self.binary),'--serial',self.args.serial],env=env,stdout=host_output,stderr=host_output)
            wait('main installed GUI device catalog',lambda:self.command('status')['rows']>0,60)
            self.command('select_device',serial=self.args.serial);self.panel_checkbox(False);self.set_panel('ON')
            self.select_route('phone','Phone audio');self.launch(self.main_package)
            first_session=self.windows[self.main_package]['session']
            first_player=self.windows[self.main_package]['player_pid']
            gui_pid=self.child.pid
            self.select_route('mac','Mac output initialized')
            first_audio=wait('initial audio owner',self.live_audio)[0];self.assert_argv(first_audio,'mac')
            self.sample_phase('disconnect-silence-baseline',silence=True)
            self.click(self.main_package,'Play test tone','before-reboot-1499')
            self.sample_phase('before-emulator-disconnect-1499',wanted=(1499,),absent=(997,))
            self.video_alive('before-real-emulator-disconnect')
            self.android('emu','kill')
            wait('owned transport disappears',lambda:not any(l.startswith(self.args.serial+'\t') for l in run(self.adb,'devices').splitlines()),30)
            wait('audio client drained on actual disconnect',lambda:not self.live_audio(),30)
            assert self.child.poll() is None and self.command('status')['pid']==gui_pid,'GUI crashed during disconnect'
            def player_gone():
                try:return str(self.app/'Contents/Resources/Runtime/Player.app/Contents/MacOS/scrcpy') not in run('/bin/ps','-ww','-p',first_player,'-o','command=')
                except subprocess.CalledProcessError:return True
            wait('old real fallback process drained',player_gone,20)
            recording=self.out/'players'/self.main_package/'video.mkv'
            if recording.exists():shutil.copy2(recording,self.out/'video-before-disconnect.mkv')
            self.report['phases'].append(dict(phase='actual-emulator-offline-GUI-alive-no-audio',passed=True,gui_pid=gui_pid,old_audio_pid=first_audio['pid']))
            emulator_output=(self.out/'emulator-restart.log').open('w')
            self.emulator_process=subprocess.Popen([str(emulator),*arguments],stdout=emulator_output,stderr=emulator_output,start_new_session=True)
            def booted():
                if self.emulator_process.poll() is not None:raise AssertionError('Owned emulator restart exited early')
                try:return self.android('shell','getprop','sys.boot_completed').strip()=='1'
                except (subprocess.CalledProcessError,subprocess.TimeoutExpired):return False
            wait('same owned AVD boots again',booted,180)
            boot=self.android('shell','cat','/proc/sys/kernel/random/boot_id').strip()
            assert boot!=original_boot,'Emulator did not actually reboot'
            self.report['expected_emulator_restart']=dict(before_boot_id=original_boot,after_boot_id=boot,new_host_pid=self.emulator_process.pid,prior_system_server_pid=self.system_server_before)
            self.system_server_before=self.android('shell','pidof','system_server').strip()
            self.report['system_server_pid_before']=self.system_server_before
            wait('GUI catalog recovers authorized device',lambda:self.args.serial in self.command('status')['device'],70)
            self.command('select_device',serial=self.args.serial)
            def restored():return next((e for e in reversed(self.events()) if e.get('package')==self.main_package and e.get('backend')=='scrcpy' and e.get('state')=='running' and e.get('session')!=first_session),None)
            try:
                event=wait('automatic video intent restoration',restored,35)
                self.bind_fallback(self.main_package,event);recovery='automatic retained video intent'
            except AssertionError as error:
                self.report['automatic_video_restore_failure']=str(error)
                self.launch(self.main_package);recovery='explicit graphical Launch App after reconnect'
            self.report['video_recovery']=recovery
            state=wait('audio recovery becomes actionable',lambda:((r if 'Audio unavailable' in r['audio_status'] or 'Mac output initialized' in r['audio_status'] else None)
                       if (r:=self.command('status')) else None),35)
            retry=False
            if 'Audio unavailable' in state['audio_status']:
                assert state['buttons'].get('Retry Audio');self.command('button',title='Retry Audio');retry=True
                wait('explicit Retry Audio initialized',lambda:'Mac output initialized' in self.command('status')['audio_status'],35)
            successor=wait('reconnected exact audio client',self.live_audio)[0]
            assert successor['pid']!=first_audio['pid'];self.assert_argv(successor,'mac')
            self.sample_phase('reconnected-silence-baseline',silence=True)
            self.click(self.main_package,'Play test tone','after-reboot-1499')
            self.sample_phase('after-real-reconnect-and-explicit-retry-1499',wanted=(1499,),absent=(997,))
            self.video_alive('after-real-emulator-reconnect')
            assert self.child.pid==gui_pid and self.child.poll() is None
            self.report['phases'].append(dict(phase='same-GUI-video-and-audio-recovery-after-real-reboot',passed=True,explicit_audio_retry=retry,first_audio_pid=first_audio['pid'],successor_audio_pid=successor['pid']))
            self.command('quit');self.child.wait(timeout=45);assert self.child.returncode==0
            self.report.update(passed=True,acceptance=True)
        except Exception as error:
            self.report['failure']=str(error);raise
        finally:
            self.cleanup();host_output.close()
            if emulator_output:emulator_output.close()
            # Leave the same owned AVD running, as it was at admission. Root is
            # given its exact new PID; no unrelated emulator or ADB server stops.
            self.report['restarted_emulator_pid']=self.emulator_process.pid if self.emulator_process else None
            (self.out/'result.json').write_text(json.dumps(self.report,indent=2)+'\n')

def prepare_wrapper_helper(output):
    binary=output/'wrapper-factory'
    build=pathlib.Path(run('swift','build','--show-bin-path').strip())
    objects=sorted((build/'DroidBridgeCore.build').glob('*.o'))
    assert objects,'Build Core before preparing wrapper factory'
    run('swiftc','-parse-as-library','-I',build/'Modules',REPO/'Sources/DroidBridge/MacAppWrapper.swift',
        REPO/'scripts/verify-audio-wrappers.swift',*objects,'-o',binary,timeout=60)
    return binary


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app',type=pathlib.Path,default=pathlib.Path.home()/'Applications/DroidBridge.app')
    parser.add_argument('--serial',choices=['emulator-5580','emulator-5582'],default='emulator-5580')
    parser.add_argument('--output',type=pathlib.Path,required=True)
    parser.add_argument('--prepare-only',action='store_true')
    parser.add_argument('--expected-sha256')
    parser.add_argument('--wrappers',action='store_true',help='After fallback matrix, run copied native wrapper ownership/handoff test')
    parser.add_argument('--wrappers-only',action='store_true')
    parser.add_argument('--disconnect',action='store_true',help='After matrix, actual ownedAPI37 reboot/recovery gate')
    parser.add_argument('--disconnect-only',action='store_true')
    args=parser.parse_args()
    if (args.disconnect or args.disconnect_only) and args.serial!='emulator-5582':
        parser.error('Actual emulator restart is restricted to owned API37 emulator-5582')
    if args.prepare_only:
        args.output.resolve().mkdir(parents=True,exist_ok=True)
        prepare(args.app.resolve(),args.output.resolve())
        prepare_wrapper_helper(args.output.resolve())
        print('Prepared fallback/audio/wrapper instruments only; no device or preferences operations')
        return
    if args.expected_sha256:
        assert hashlib.sha256((args.app/'Contents/MacOS/DroidBridge').read_bytes()).hexdigest()==args.expected_sha256
    if not args.wrappers_only and not args.disconnect_only:
        test=FallbackAudioTest(args);test.execute()
        print(json.dumps(test.report,indent=2));assert test.report['passed']
    if args.wrappers or args.wrappers_only:
        original=args.output;args.output=original/'wrapper-ownership' if not args.wrappers_only else original
        test=WrapperOwnershipTest(args);test.execute()
        print(json.dumps(test.report,indent=2));assert test.report['passed']
    if args.disconnect or args.disconnect_only:
        args.output=original/'disconnect-recovery' if 'original' in locals() else (args.output if args.disconnect_only else args.output/'disconnect-recovery')
        test=DisconnectRecoveryTest(args);test.execute()
        print(json.dumps(test.report,indent=2));assert test.report['passed']


if __name__=='__main__':main()
