#!/usr/bin/env python3
"""Fail if a release APK packages diagnostic collectors or dev source identity."""
import argparse
import hashlib
import json
from pathlib import Path
from zipfile import ZipFile

parser = argparse.ArgumentParser()
parser.add_argument('apk', type=Path)
args = parser.parse_args()
forbidden = [b'works/sloop/swip', b'com/sloopworks/debugdrawer', b'swip_pub_droidbridge', b'CompanionDiagnosticsActivity']
with ZipFile(args.apk) as archive:
    dex = b''.join(archive.read(name) for name in archive.namelist() if name.endswith('.dex'))
    if not dex:
        raise SystemExit('APK contains no DEX; release boundary cannot be verified.')
    found = [marker.decode() for marker in forbidden if marker in dex]
    if found:
        raise SystemExit('Release diagnostic boundary violated: ' + ', '.join(found))
print(json.dumps({'apk': args.apk.name, 'sha256': hashlib.sha256(args.apk.read_bytes()).hexdigest(), 'diagnostic_markers_absent': [m.decode() for m in forbidden], 'passed': True}, indent=2))
