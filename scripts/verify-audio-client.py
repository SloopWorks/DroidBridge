#!/usr/bin/env python3
"""Real patched-client admission checks. No device or shared preference access."""
import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import tempfile

p=argparse.ArgumentParser()
p.add_argument('--client',type=pathlib.Path,required=True)
p.add_argument('--output',type=pathlib.Path,required=True)
args=p.parse_args()
client=args.client.resolve()
base=['--serial','qa-audio-no-device','--no-video','--no-control','--no-window',
      '--no-power-on','--require-audio','--audio-codec=raw','--force-adb-forward',
      '--port','46062','--audio-source=output']
cases=[('short','1234',[]),('high-bit','81234567',[]),
       ('uppercase','1234ABCD',[]),('nonhex','1234567z',[]),
       ('metacharacters','1;echo x',[]),('video-enabled','12345678',['--no-video','--no-window']),
       ('control-enabled','12345678',['--no-control']),
       ('reverse-enabled','12345678',['--force-adb-forward'])]
report={'passed':False,'client_sha256':hashlib.sha256(client.read_bytes()).hexdigest(),
        'scope':'Real client refusal before any ADB invocation; not live audio acceptance','cases':[]}
with tempfile.TemporaryDirectory(prefix='droidbridge-audio-admission-') as folder:
 root=pathlib.Path(folder);calls=root/'calls'
 adb=root/'adb'
 adb.write_text('#!/bin/sh\nprintf "unexpected ADB call\\n" >> "'+str(calls)+'"\nexit 97\n')
 adb.chmod(0o700)
 for name,scid,omit in cases:
  env=dict(os.environ,ADB=str(adb),DROIDBRIDGE_AUDIO_SCID=scid)
  result=subprocess.run([str(client),*[a for a in base if a not in omit]],
       env=env,text=True,capture_output=True,timeout=10)
  output=result.stdout+result.stderr
  assert result.returncode!=0 and 'Invalid supervised audio session' in output,(name,result.returncode,output)
  assert not calls.exists(),name
  report['cases'].append(dict(name=name,passed=True,exit=result.returncode,output=output))
report['passed']=True
args.output.parent.mkdir(parents=True,exist_ok=True)
args.output.write_text(json.dumps(report,indent=2)+'\n')
print('PASS real audio-client admission: '+str(len(cases))+' cases, no ADB calls')
