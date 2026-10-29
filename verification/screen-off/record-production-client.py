#!/usr/bin/env python3
"""Test recording/public SDL injection around the production-generated argv."""
import json,os,pathlib,sys
root=pathlib.Path(__file__).resolve().parents[2];args=sys.argv[1:];real='/opt/homebrew/bin/scrcpy'
if '--version' in args:os.execv(real,[real,*args])
package=next(x.split('=',1)[1] for x in args if x.startswith('--start-app='))
assert package in ('dev.droidbridge.testapp','dev.droidbridge.testapp2')
name='b' if package.endswith('2') else 'a';out=root/'verification/screen-off/concurrent-fallback';out.mkdir(parents=True,exist_ok=True)
(out/(name+'-production-argv.json')).write_text(json.dumps(args,indent=2))
env=os.environ.copy();env.update(DYLD_INSERT_LIBRARIES=str(root/'.build/production-sdl.dylib'),DROIDBRIDGE_SDL_WORD=('2ProductionB' if name=='b' else '1ProductionA'),DROIDBRIDGE_SDL_TRIGGER=str(out/(name+'.trigger')),DROIDBRIDGE_SDL_VIDEO_HEIGHT=str(out/(name+'.height')))
os.execve(real,[real,*args,'--verbosity=debug','--record='+str(out/(name+'.mkv'))],env)
