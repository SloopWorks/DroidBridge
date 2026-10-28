#!/usr/bin/env python3
"""Independent output location for shipping factory/Spotlight/COW/scale harness.
Uses isolated managed roots and never writes the user's default managed catalog.
"""
import os,pathlib,subprocess
root=pathlib.Path.cwd();source=(root/'scripts/verify-managed-apps.swift').read_text();original='appendingPathComponent("verification/onboarding")';assert source.count(original)==1
copy=root/'.build/qa-verify-managed-apps.swift';copy.write_text(source.replace(original,'appendingPathComponent("verification/onboarding/qa/managed-apps")'))
bin=pathlib.Path(subprocess.check_output(['swift','build','--show-bin-path'],text=True).strip());exe=root/'.build/qa-verify-managed-apps';out=root/'verification/onboarding/qa/managed-apps';out.mkdir(parents=True,exist_ok=True)
subprocess.run(['swiftc','-parse-as-library','-I',str(bin/'Modules'),str(root/'Sources/DroidBridge/MacAppWrapper.swift'),str(copy),*map(str,(bin/'DroidBridgeCore.build').glob('*.o')),'-o',str(exe)],check=True)
with (out/'run.log').open('w') as log:subprocess.run([str(exe)],stdout=log,stderr=log,check=True,timeout=90)
