#!/usr/bin/env python3
"""Bind installer metadata to verified bytes; never infer notarization from text."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess

from release_signing import digest, run, source_revision, verify

if not __debug__:
    raise SystemExit('Release validation requires an unoptimized Python interpreter; remove -O/PYTHONOPTIMIZE.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--dmg', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--require-notarized', action='store_true')
    parser.add_argument('--team-id')
    args = parser.parse_args()
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', args.app])
    signature = run(['/usr/bin/codesign', '-d', '--verbose=4', args.app])
    info = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not re.fullmatch(r'[1-9][0-9]*', build):
        raise ValueError('Invalid app version/build')
    if info['LSMinimumSystemVersion'] != '26.0' or args.dmg.name != f'DroidBridge-{version}-arm64.dmg':
        raise ValueError('Installer platform/name does not match the app')
    size = args.dmg.stat().st_size
    if not 0 < size <= 268435456:
        raise ValueError('Installer exceeds its delivery size budget')
    signing = 'ad_hoc_not_notarized'
    extra = {}
    if args.require_notarized:
        if not args.team_id:
            raise ValueError('Notarized delivery requires an expected team')
        verify(args.app, args.team_id)
        verify(args.dmg, args.team_id, hardened=False)
        for path in (args.app, args.dmg):
            run(['/usr/bin/xcrun', 'stapler', 'validate', path])
        run(['/usr/sbin/spctl', '--assess', '--type', 'execute', args.app])
        run(['/usr/sbin/spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', args.dmg])
        root = Path(__file__).resolve().parents[1]
        commit = source_revision(root)
        if info.get('DroidBridgeSourceCommit') != commit:
            raise ValueError('App source identity differs from the current committed candidate')
        signing = 'developer_id_notarized'
        extra = {'schema_version': 2, 'team_id': args.team_id, 'source_commit': commit, 'source_dirty': False}
    elif 'Signature=adhoc' not in signature:
        raise ValueError('Developer ID artifacts need --require-notarized and --team-id; cannot mislabel signing')
    metadata = {'version': version, 'build': build, 'architecture': 'arm64', 'minimum_macos': '26.0',
        'size_bytes': size, 'sha256': digest(args.dmg), 'signing': signing,
        'download_url': f'https://github.com/SloopWorks/DroidBridge/releases/download/v{version}/DroidBridge-{version}-arm64.dmg',
        'release_url': f'https://github.com/SloopWorks/DroidBridge/releases/tag/v{version}', **extra}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(metadata, indent=2) + '\n')
    print(f'Bound {version} build {build} metadata ({signing}); publication/download acceptance remains separate.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise SystemExit(str(error))
