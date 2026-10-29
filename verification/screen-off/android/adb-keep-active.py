#!/usr/bin/env python3
"""TEST ONLY pass-through to the real ADB, adding pinned keep-active server flags.
DroidBridge production sources are not modified by this feasibility experiment.
"""
import json, os, pathlib, sys
serial = os.environ.get('DROIDBRIDGE_TEST_SERIAL', 'emulator-5580')
assert serial in ('emulator-5580', 'emulator-5582')
args = sys.argv[1:]
if 'com.genymobile.scrcpy.Server' in args:
    assert args[:2] == ['-s', serial]
    args += ['keep_active=true', 'power_on=false']
    out = pathlib.Path(os.environ['DROIDBRIDGE_SCREEN_OFF_EVIDENCE'])
    with (out/'native-server-command.jsonl').open('a') as log:
        log.write(json.dumps(args)+'\n')
adb = str(pathlib.Path.home()/'Library/Android/sdk/platform-tools/adb')
os.execv(adb, [adb] + args)
