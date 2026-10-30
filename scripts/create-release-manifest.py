#!/usr/bin/env python3
"""Bind public installer metadata to exact locally verified release artifacts."""
import argparse, hashlib, json, pathlib, plistlib, subprocess
if not __debug__:
    raise SystemExit('Release validation requires Python assertions; remove -O/PYTHONOPTIMIZE.')
p=argparse.ArgumentParser();p.add_argument('--app',type=pathlib.Path,required=True);p.add_argument('--dmg',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
subprocess.run(['codesign','--verify','--deep','--strict',str(a.app)],check=True)
signing=subprocess.run(['codesign','-dv','--verbose=4',str(a.app)],capture_output=True,text=True,check=True).stderr
assert 'Signature=adhoc' in signing, 'Review manifest signing classification for this artifact'
info=plistlib.loads((a.app/'Contents/Info.plist').read_bytes());version=info['CFBundleShortVersionString']
assert version=='0.2.0' and info['LSMinimumSystemVersion']=='26.0','Update and review versioned delivery policy before another release'
assert a.dmg.name==f'DroidBridge-{version}-arm64.dmg'
size=a.dmg.stat().st_size;assert 0<size<=268435456
h=hashlib.sha256()
with a.dmg.open('rb') as f:
    for block in iter(lambda:f.read(1048576),b''):h.update(block)
metadata={'version':version,'build':info['CFBundleVersion'],'architecture':'arm64','minimum_macos':'26.0','size_bytes':size,'sha256':h.hexdigest(),'signing':'ad_hoc_not_notarized','download_url':f'https://github.com/SloopWorks/DroidBridge/releases/download/v{version}/DroidBridge-{version}-arm64.dmg','release_url':f'https://github.com/SloopWorks/DroidBridge/releases/tag/v{version}'}
a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(metadata,indent=2)+'\n')
print(f'Bound {version} build {info["CFBundleVersion"]} installer metadata; publication and actual HTTPS download verification remain required.')
