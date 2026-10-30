#!/usr/bin/env python3
"""Independent byte/layout audit of a companion corresponding-source candidate.

Reads archive and signed app only. Does not extract, execute packaged code,
contact a device, upload, or assert legal compliance.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess
import tarfile

parser = argparse.ArgumentParser()
parser.add_argument('--archive', type=Path, required=True)
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--expected-commit', required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
prefix = 'DroidBridge-Corresponding-Source/'


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1048576), b''):
            h.update(block)
    return h.hexdigest()


commit = subprocess.check_output(['git', 'rev-parse', args.expected_commit + '^{commit}'], cwd=root, text=True).strip()
subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(args.app)], check=True, capture_output=True)
with tarfile.open(args.archive) as archive:
    members = archive.getmembers()
    require(len(members) <= 10000 and sum(m.size for m in members) <= 1_073_741_824, 'Archive exceeds review bounds')
    files = {}
    for member in members:
        parts = PurePosixPath(member.name)
        require(not parts.is_absolute() and '..' not in parts.parts and (member.name == prefix.rstrip('/') or member.name.startswith(prefix)), 'Unsafe archive path')
        require(member.isdir() or member.isfile(), 'Archive contains a link or special entry')
        if member.isfile():
            require(member.name.startswith(prefix) and member.name not in files, 'Duplicate archive file identity')
            require(member.size <= 536_870_912, 'Oversized archive member')
            files[member.name[len(prefix):]] = member

    def read(name, maximum=4_194_304):
        member = files[name]
        require(member.size <= maximum, 'Metadata exceeds byte bound: ' + name)
        return archive.extractfile(member).read()

    def hash_member(name, algorithm='sha256'):
        member = files[name]
        value = hashlib.new(algorithm)
        if algorithm == 'sha1':
            value.update(('blob ' + str(member.size) + '\0').encode())
        with archive.extractfile(member) as stream:
            for block in iter(lambda: stream.read(1048576), b''):
                value.update(block)
        return value.hexdigest()

    identities = json.loads(read('BUILD_IDENTITIES.json'))
    require(identities['droidbridge_commit'] == commit, 'Wrong committed candidate')
    sums = {}
    for line in read('SOURCE-SHA256SUMS').decode().splitlines():
        sha, name = line.split('  ', 1)
        require(name not in sums and len(sha) == 64, 'Duplicate or invalid checksum identity')
        sums[name] = sha
    require(set(sums) == set(files) - {'SOURCE-SHA256SUMS'}, 'Checksum cohort does not cover the exact archive files')
    for name, sha in sums.items():
        require(hash_member(name) == sha, 'Archive checksum mismatch: ' + name)

    tracked = subprocess.check_output(['git', 'ls-tree', '-r', '-z', commit], cwd=root).split(b'\0')
    tracked_count = 0
    archive_transforms = []
    for entry in tracked:
        if not entry:
            continue
        metadata, raw_name = entry.split(b'\t', 1)
        mode, kind, oid = metadata.decode().split(' ')
        name = raw_name.decode()
        if name.split('/')[0] in {'verification', 'dist', 'Vendor'}:
            continue
        require(kind == 'blob' and mode in ('100644', '100755'), 'Unreviewed source object: ' + name)
        require(files['DroidBridge/' + name].mode & 0o111 == int(mode, 8) & 0o111, 'Archived executable mode differs: ' + name)
        actual_oid = hash_member('DroidBridge/' + name, 'sha1')
        if name == 'AndroidCompanion/gradlew.bat':
            attributes = read('DroidBridge/.gitattributes').decode().splitlines()
            require('AndroidCompanion/gradlew.bat text eol=crlf' in attributes, 'Unapproved archive line-ending transformation')
            raw = read('DroidBridge/' + name, 65536)
            normalized = raw.replace(b'\r\n', b'\n')
            require(raw == normalized.replace(b'\n', b'\r\n'), 'Mixed Gradle Windows launcher endings')
            actual_oid = hashlib.sha1(('blob ' + str(len(normalized)) + '\0').encode() + normalized).hexdigest()
            archive_transforms.append({'path': name, 'transformation': 'Committed Git eol=crlf archive conversion; normalized Git blob verified'})
        require(actual_oid == oid, 'Archived source differs from Git candidate: ' + name)
        tracked_count += 1
    require(not any(name.startswith(('DroidBridge/verification/', 'DroidBridge/dist/', 'DroidBridge/Vendor/')) for name in files), 'Unexpected binary/evidence/source-cache subtree')

    manifest_bytes = read('runtime-sources/MANIFEST.json')
    require(hashlib.sha256(manifest_bytes).hexdigest() == identities['runtime_manifest_sha256'], 'Source manifest binding changed')
    manifest = json.loads(manifest_bytes)
    provided = {(item['name'], item['version']) for item in manifest}
    required = set()
    for origin in json.loads((args.app / 'Contents/Resources/Runtime/dependencies.json').read_text()).values():
        parts = Path(origin).parts
        index = parts.index('Cellar')
        required.add((parts[index + 1], parts[index + 2]))
    require(provided == required and len(provided) == len(manifest), 'Runtime/source formula cohort differs')
    for item in manifest:
        require(hash_member('runtime-sources/' + item['source']) == item['source_sha256'], 'Dependency source hash changed')
        recipe = 'runtime-sources/' + item['name'] + '-' + item['version'] + '/' + item['name'] + '.rb'
        require(hash_member(recipe) == item['recipe_sha256'], 'Dependency recipe changed')
        if item.get('git_bundle'):
            require(hash_member('runtime-sources/' + item['git_bundle']) == item['git_bundle_sha256'], 'Dependency source history changed')

    provenance_bytes = read('adb-source-runtime/BUILD_PROVENANCE.json')
    require(hashlib.sha256(provenance_bytes).hexdigest() == identities['adb_source_provenance_sha256'], 'ADB provenance identity changed')
    notices = args.app / 'Contents/Resources/licenses/adb-source-runtime'
    require((notices / 'BUILD_PROVENANCE.json').read_bytes() == provenance_bytes, 'App ADB provenance differs')
    provenance = json.loads(provenance_bytes)
    runtime_bytes = read('adb-source-runtime/adb-runtime.json')
    require((args.app / 'Contents/Resources/Runtime/bin/adb-runtime.json').read_bytes() == runtime_bytes, 'App ADB inventory differs')
    require(hashlib.sha256(runtime_bytes).hexdigest() == identities['adb_runtime_manifest_sha256'] == provenance['runtime_manifest_sha256'], 'ADB runtime identity changed')
    for item in json.loads(runtime_bytes)['files']:
        require(digest(args.app / 'Contents/Resources/Runtime/bin' / item['name']) == item['sha256'], 'Actual shipped ADB file differs')
    require(hash_member('adb-source-runtime/' + provenance['source_closure']['path']) == provenance['source_closure']['sha256'], 'ADB source closure changed')
    for category in ('sources', 'patches', 'recipes'):
        for item in provenance[category]:
            relative = item.get('staged_source', item.get('path'))
            require(hash_member('adb-source-runtime/' + relative) == item['sha256'], 'ADB source input changed')
    for item in provenance['notices']:
        require(hash_member('adb-source-runtime/' + item['path']) == item['sha256'], 'ADB notice changed')
        require(digest(notices / Path(item['path']).name) == item['sha256'], 'App ADB notice differs')
    require(hash_member('scrcpy-5.0.1.tar') == identities['scrcpy_source_sha256'], 'scrcpy archive changed')

result = {'status': 'passed', 'scope': 'Independent source/archive/app byte-binding review; provisional candidate, no installed interoperability or legal compliance claim',
          'archive_sha256': digest(args.archive), 'droidbridge_commit': commit, 'archive_members': len(members), 'hashed_files': len(sums),
          'git_source_blobs_verified': tracked_count, 'committed_archive_transformations': archive_transforms, 'dependency_formula_versions': sorted('/'.join(x) for x in provided),
          'adb_runtime_manifest_sha256': identities['adb_runtime_manifest_sha256'], 'adb_notices': len(provenance['notices']),
          'links_or_special_entries': 0, 'deep_strict_app_signature_verified': True}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
