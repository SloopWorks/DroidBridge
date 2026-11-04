#!/usr/bin/env python3
"""Developer ID signing/notarization helpers. Never create or export credentials."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def run(argv, timeout=90):
    return subprocess.check_output([str(x) for x in argv], stderr=subprocess.STDOUT,
                                   text=True, timeout=timeout)


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        while data := stream.read(1024 * 1024):
            value.update(data)
    return value.hexdigest()


def source_revision(root):
    """Freeze the committed source identity before doing a public build."""
    commit = run(['/usr/bin/git', '-C', root, 'rev-parse', 'HEAD']).strip()
    if not re.fullmatch(r'[a-f0-9]{40}', commit):
        raise ValueError('Release requires an exact source commit')
    dirty = run(['/usr/bin/git', '-C', root, 'status', '--porcelain',
                 '--untracked-files=normal', '--', '.', ':!verification']).strip()
    if dirty:
        raise ValueError('Public release requires committed source inputs (verification logs excluded)')
    return commit


def configuration(environ=None):
    env = os.environ if environ is None else environ
    mode = env.get('DROIDBRIDGE_SIGNING_MODE', 'adhoc')
    if mode not in ('adhoc', 'developer-id'):
        raise ValueError('DROIDBRIDGE_SIGNING_MODE must be adhoc or developer-id')
    identity = env.get('DROIDBRIDGE_SIGNING_IDENTITY', '')
    team = env.get('DROIDBRIDGE_DEVELOPMENT_TEAM', '')
    profile = env.get('DROIDBRIDGE_NOTARY_PROFILE', '')
    if mode == 'developer-id':
        if not re.fullmatch(r'[A-Fa-f0-9]{40}', identity):
            raise ValueError('Release signing needs a certificate SHA-1 fingerprint in DROIDBRIDGE_SIGNING_IDENTITY')
        if not re.fullmatch(r'[A-Z0-9]{10}', team):
            raise ValueError('Release signing needs DROIDBRIDGE_DEVELOPMENT_TEAM')
        if not re.fullmatch(r'[A-Za-z0-9_.-]{1,128}', profile):
            raise ValueError('Release signing needs a Keychain profile name in DROIDBRIDGE_NOTARY_PROFILE')
    return {'mode': mode, 'identity': identity.upper(), 'team': team, 'profile': profile}


def preflight(config):
    if config['mode'] == 'adhoc':
        return
    listing = run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'])
    matches = re.findall(r'\b([A-Fa-f0-9]{40}) "(Developer ID Application:[^"\n]+)"', listing)
    if not any(key.upper() == config['identity'] and name.endswith('(' + config['team'] + ')')
               for key, name in matches):
        raise ValueError('The selected Developer ID Application identity/private key is not available for the expected team')
    # Reads submission history only; detects missing/expired credentials before building.
    run(['/usr/bin/xcrun', 'notarytool', 'history', '--keychain-profile', config['profile'],
         '--output-format', 'json'], timeout=45)


def verify(path, team, hardened=True):
    if not re.fullmatch(r'[A-Z0-9]{10}', team):
        raise ValueError('Invalid expected signing team')
    requirement = ('anchor apple generic and certificate leaf[subject.OU] = "' + team +
                   '" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists')
    argv = ['/usr/bin/codesign', '--verify', '--strict', '-R=' + requirement]
    if Path(path).is_dir():
        argv.append('--deep')
    run(argv + [path])
    details = run(['/usr/bin/codesign', '-d', '--verbose=4', path])
    if ('TeamIdentifier=' + team + '\n' not in details or
            'Authority=Developer ID Application:' not in details or 'Signature=adhoc' in details):
        raise ValueError('Code does not have the expected Developer ID identity')
    if hardened and '(runtime)' not in details:
        raise ValueError('Executable is missing hardened runtime')
    if not re.search(r'^Timestamp=.+$', details, re.MULTILINE):
        raise ValueError('Developer ID signature is missing a secure timestamp')
    return {'team_id': team, 'developer_id': True, 'hardened_runtime': hardened,
            'secure_timestamp': True}


def sign(path, config, disk_image=False, entitlements=None):
    if config['mode'] == 'adhoc':
        argv = ['/usr/bin/codesign', '--force', '--sign', '-']
        if entitlements:
            argv += ['--entitlements', entitlements]
        run(argv + [path])
        return
    argv = ['/usr/bin/codesign', '--force', '--sign', config['identity'], '--timestamp']
    if not disk_image:
        argv += ['--options', 'runtime']
    if entitlements:
        if disk_image:
            raise ValueError('Disk images cannot receive executable entitlements')
        argv += ['--entitlements', entitlements]
    run(argv + [path])
    verify(path, config['team'], hardened=not disk_image)


def prepare_adb(source, destination, config):
    """Preserve the source cache; publish a separately signed, source-bound cohort."""
    source = source.resolve(strict=True)
    if destination.exists() or destination.is_symlink():
        raise ValueError('Signed ADB destination already exists; choose a new build cohort')
    stage_tool = Path(__file__).with_name('stage-adb-runtime.py')
    run([os.sys.executable, stage_tool, '--adb', source / 'adb'])
    manifest = json.loads((source / 'adb-runtime.json').read_text())
    provenance = json.loads((source / 'BUILD_PROVENANCE.json').read_text())
    original_hash = digest(source / 'adb-runtime.json')
    if provenance['runtime_manifest_sha256'] != original_hash:
        raise ValueError('ADB source provenance does not match its input manifest')
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.adb-signing-', dir=destination.parent))
    try:
        shutil.copytree(source, stage, dirs_exist_ok=True, symlinks=True)
        for entry in manifest['files']:
            sign(stage / entry['name'], config)
            entry['size'] = (stage / entry['name']).stat().st_size
            entry['sha256'] = digest(stage / entry['name'])
        (stage / 'adb-runtime.json').write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
        provenance['distribution_signing'] = {'mode': config['mode'], 'team_id': config['team'],
            'build_runtime_manifest_sha256': original_hash,
            'build_provenance_sha256': digest(source / 'BUILD_PROVENANCE.json')}
        provenance['runtime_manifest_sha256'] = digest(stage / 'adb-runtime.json')
        (stage / 'BUILD_PROVENANCE.json').write_text(json.dumps(provenance, sort_keys=True, indent=2) + '\n')
        run([os.sys.executable, stage_tool, '--adb', stage / 'adb'])
        stage.rename(destination)
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def notarize(archive, staple_target, evidence, config):
    if config['mode'] != 'developer-id':
        raise ValueError('Notarization requires explicit developer-id mode')
    evidence.mkdir(parents=True, exist_ok=True)
    command = ['/usr/bin/xcrun', 'notarytool', 'submit', str(archive), '--keychain-profile',
               config['profile'], '--wait', '--timeout', '15m', '--output-format', 'json']
    try:
        process = subprocess.run(command, capture_output=True, text=True, timeout=960)
    except subprocess.TimeoutExpired as error:
        # Apple's job can still be live after local observation times out. Keep
        # any returned submission ID; the operator must inspect it, not resubmit.
        partial = error.stdout or b''
        if isinstance(partial, bytes): partial = partial.decode('utf-8', errors='replace')
        (evidence / (archive.name + '.notary-timeout.log')).write_text(partial)
        raise ValueError('Notary observation timed out. Inspect the retained submission ID/history before retrying.') from error
    receipt = process.stdout
    (evidence / (archive.name + '.notary.log')).write_text(receipt + process.stderr)
    # Keep both accepted and rejected/pending submission output before deciding
    # whether to publish. Never turn a failed command into a notarization claim.
    if process.returncode:
        raise ValueError('Notary command failed or timed out; inspect its retained output/history before retrying')
    (evidence / (archive.name + '.notary.json')).write_text(receipt)
    result = json.loads(receipt)
    if result.get('status') != 'Accepted':
        raise ValueError('Apple did not accept the notarization submission; see the retained receipt')
    if not re.fullmatch(r'[A-Fa-f0-9-]{36}', result.get('id', '')):
        raise ValueError('Notary response is missing a submission identity')
    run(['/usr/bin/xcrun', 'stapler', 'staple', staple_target])
    validation = run(['/usr/bin/xcrun', 'stapler', 'validate', staple_target])
    (evidence / (archive.name + '.stapler.log')).write_text(validation)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['preflight', 'source-revision', 'sign', 'verify', 'prepare-adb', 'notarize'])
    parser.add_argument('--path', type=Path)
    parser.add_argument('--source', type=Path)
    parser.add_argument('--destination', type=Path)
    parser.add_argument('--staple', type=Path)
    parser.add_argument('--evidence', type=Path)
    parser.add_argument('--disk-image', action='store_true')
    parser.add_argument('--entitlements', type=Path)
    args = parser.parse_args()
    config = configuration()
    if args.operation == 'preflight':
        preflight(config)
    elif args.operation == 'source-revision':
        print(source_revision(Path(__file__).resolve().parents[1]))
    elif args.operation == 'sign' and args.path:
        sign(args.path, config, args.disk_image, args.entitlements)
    elif args.operation == 'verify' and args.path:
        if config['mode'] != 'developer-id':
            raise ValueError('Release verification requires developer-id mode')
        print(json.dumps(verify(args.path, config['team'], not args.disk_image)))
    elif args.operation == 'prepare-adb' and args.source and args.destination:
        prepare_adb(args.source, args.destination, config)
    elif args.operation == 'notarize' and args.path and args.staple and args.evidence:
        notarize(args.path, args.staple, args.evidence, config)
    else:
        parser.error('Missing operation-specific paths')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise SystemExit(str(error))
