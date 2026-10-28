#!/usr/bin/env python3
import hashlib,json,os,pathlib,plistlib,shutil,subprocess,tempfile
repo=pathlib.Path.cwd();out=repo/'verification/onboarding/qa/managed-gates';out.mkdir(parents=True,exist_ok=True)
pref=pathlib.Path.home()/'Library/Application Support/DroidBridge/preferences.json';prior=pref.read_bytes() if pref.exists() else None
identifier='app.droidbridge.managed.qa.launchgates';state=pref.parent/('sessions-'+identifier+'.json');saved=state.read_bytes() if state.exists() else None
try:
 with tempfile.TemporaryDirectory(prefix='qa-managed-gates-') as temp:
  root=pathlib.Path(temp);bundle=root/'Managed Gates.app';mac=bundle/'Contents/MacOS';res=bundle/'Contents/Resources';mac.mkdir(parents=True);res.mkdir()
  (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':identifier,'CFBundleExecutable':'ManagedGates','CFBundleName':'Managed Gates QA'}))
  (res/'launch.json').write_text(json.dumps({'serial':'qa-managed-gate','package':'dev.qa.gate','backend':'native','name':'Managed Gate'}))
  adb=root/'adb';adb.write_text('#!/bin/sh\nif [ "$1" = devices ]; then printf "List of devices attached\\nqa-managed-gate device model:Fixture\\n"; elif [ "$4" = getprop ]; then if [ -f "$DROIDBRIDGE_QA_ROOT/delay-next-readiness" ]; then rm "$DROIDBRIDGE_QA_ROOT/delay-next-readiness"; touch "$DROIDBRIDGE_QA_ROOT/readiness-delayed"; sleep 0.3; fi; echo 1; elif [ "$4" = cmd ]; then echo package:/system/framework/framework-res.apk; fi\n');adb.chmod(0o755)
  scrcpy=root/'scrcpy';scrcpy.write_text('#!/bin/sh\nif [ \"$3\" = --list-apps ]; then echo \" * Managed Gate dev.qa.gate\"; exit 0; fi\nif [ \"$1\" = --version ]; then echo scrcpy 5.0.1; exit 0; fi\ntouch "$DROIDBRIDGE_QA_ROOT/scrcpy-spawned"\nexit 1\n');scrcpy.chmod(0o755);(root/'server').touch()
  bin=pathlib.Path(subprocess.check_output(['swift','build','--show-bin-path'],text=True).strip());sources=['Launcher','DeviceOnboarding','DeviceOnboardingUI','DeviceOnboardingAgent','NativeWindow','MacAppWrapper']
  subprocess.run(['swiftc','-parse-as-library','-I',str(bin/'Modules'),*[str(repo/'Sources/DroidBridge'/(s+'.swift')) for s in sources],str(repo/'verification/onboarding/qa/verify-managed-gates.swift'),*map(str,(bin/'DroidBridgeCore.build').glob('*.o')),*map(str,(bin/'DroidBridgeStreaming.build').glob('*.o')),'-o',str(mac/'ManagedGates')],check=True)
  env=os.environ.copy();env.update(DROIDBRIDGE_QA_ROOT=str(root),DROIDBRIDGE_ADB=str(adb),DROIDBRIDGE_SCRCPY=str(scrcpy),DROIDBRIDGE_SERVER=str(root/'server'))
  with (out/'run.log').open('w') as log:result=subprocess.run([str(mac/'ManagedGates')],env=env,stdout=log,stderr=log,timeout=30)
  if (root/'results.json').exists():shutil.copy2(root/'results.json',out/'results.json')
  result.check_returncode()
finally:
 for path,data in [(pref,prior),(state,saved)]:
  if data is None:path.unlink(missing_ok=True)
  else:path.write_bytes(data)
