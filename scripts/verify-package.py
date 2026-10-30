#!/usr/bin/env python3
"""Fail closed if a locally installed bundle relies on external dylib paths.
Does not assert Gatekeeper trust or notarization from ad-hoc codesigning.
"""
import argparse, json, os, pathlib, subprocess
p=argparse.ArgumentParser(); p.add_argument('app',type=pathlib.Path); p.add_argument('--output',type=pathlib.Path,default=pathlib.Path('verification/review/package.json')); args=p.parse_args()
app=args.app.resolve(); assert app.is_dir() and app.suffix=='.app'
def run(*command): return subprocess.check_output(command,text=True,stderr=subprocess.STDOUT)
report={'app':str(app),'codesign':run('/usr/bin/codesign','--verify','--deep','--strict',str(app)), 'dependencies':{}}
for file in app.rglob('*'):
    if not file.is_file() or file.is_symlink(): continue
    if 'Mach-O' not in run('/usr/bin/file','-b',str(file)): continue
    deps=[]
    for line in run('/usr/bin/otool','-arch','arm64','-L',str(file)).splitlines()[1:]:
        dep=line.strip().split(' (',1)[0]; deps.append(dep)
        assert dep.startswith(('/usr/lib/','/System/Library/','@loader_path/','@executable_path/','@rpath/')),f'external dependency {file}: {dep}'
        if dep.startswith('@loader_path/'):
            resolved=(file.parent/dep.removeprefix('@loader_path/')).resolve()
            assert resolved.is_relative_to(app),f'dependency escapes bundle: {resolved}'
            assert resolved.exists(),f'missing dependency {resolved}'
    report['dependencies'][str(file.relative_to(app))]=deps
runtime=app/'Contents/Resources/Runtime'
for binary in ('adb','scrcpy'):
    environment=os.environ.copy(); environment['PATH']='/usr/bin:/bin'; environment['HOME']=str(pathlib.Path.home())
    report[binary]=subprocess.check_output([str(runtime/'bin'/binary),'--version' if binary=='scrcpy' else 'version'],env=environment,text=True,stderr=subprocess.STDOUT)
assert 'scrcpy 5.0.1' in report['scrcpy']
audio=runtime/'bin/DroidBridgeAudioClient'
assert audio.is_file() and os.access(audio,os.X_OK), 'missing audio client'
report['audio_client']=subprocess.check_output([str(audio),'--version'],env=environment,text=True,stderr=subprocess.STDOUT,timeout=5)
assert 'scrcpy 5.0.1' in report['audio_client']
audio_strings=run('/usr/bin/strings',str(audio))
assert 'DROIDBRIDGE_AUDIO_OUTPUT_READY' in audio_strings and 'DROIDBRIDGE_AUDIO_SCID' in audio_strings
helper=runtime/'bin/DroidBridgeAvailability'
assert helper.is_file() and os.access(helper,os.X_OK), 'missing device availability helper'
report['availability_helper']=subprocess.check_output([str(helper),'--version'],env=environment,text=True,stderr=subprocess.STDOUT,timeout=5)
assert 'DroidBridgeAvailability' in report['availability_helper']
assert (runtime/'bin/DroidBridgeSupervisor').is_file(), 'missing session supervisor'
player=runtime/'Player.app/Contents/MacOS/scrcpy'
if player.exists():
    report['player']=subprocess.check_output([str(player),'--version'],env=environment,text=True,stderr=subprocess.STDOUT)
    assert 'scrcpy 5.0.1' in report['player']
args.output.parent.mkdir(parents=True,exist_ok=True); args.output.write_text(json.dumps(report,indent=2)+'\n')
print(f"PASS bundle signature, {len(report['dependencies'])} Mach-O dependency trees, isolated-PATH adb/scrcpy/helper versions; report {args.output}")
