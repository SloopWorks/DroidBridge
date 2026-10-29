#!/usr/bin/python3
import os,pathlib,sys
marker=pathlib.Path('/Users/patrick/workspace/DroidBridge/verification/screen-off/qa/installed-api35-on-retry/fail-next-on')
a=sys.argv[1:]
if a[:2]==['-s','emulator-5580'] and a[2:] in (['shell','cmd','display','power-on','0'],['shell','cmd','display','power-reset','0']) and marker.exists():
 marker.unlink();print('QA injected one explicit ON transport failure',file=sys.stderr);sys.exit(1)
os.execv('/Users/patrick/Applications/DroidBridge.app/Contents/Resources/Runtime/bin/adb',['/Users/patrick/Applications/DroidBridge.app/Contents/Resources/Runtime/bin/adb']+a)
