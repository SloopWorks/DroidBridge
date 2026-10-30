#!/usr/bin/env python3
"""Stage or verify a signed, flat ADB runtime without changing bound bytes."""
import argparse, hashlib, json, os, pathlib, re, shutil, stat, subprocess

if not __debug__:
    raise SystemExit('Portable ADB validation requires Python assertions; remove -O/PYTHONOPTIMIZE.')

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate portable ADB manifest key')
        result[key] = value
    return result

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()

def inventory(adb):
    manifest = adb.parent / 'adb-runtime.json'
    if not manifest.exists():
        return ['adb'], None
    check_file(manifest, 16_384)
    value = json.loads(manifest.read_bytes(), object_pairs_hook=unique_object)
    assert value['version'] == 1 and type(value['version']) is int
    entries = value['files']
    assert type(entries) is list and 2 <= len(entries) <= 15
    names, total = set(), manifest.stat().st_size
    for entry in entries:
        name, size, sha = entry['name'], entry['size'], entry['sha256']
        assert name == 'adb' or re.fullmatch(r'adb-lib[A-Za-z0-9_.\-]+\.dylib', name), 'Unsafe portable ADB filename'
        assert len(name) <= 120 and name not in names
        assert type(size) is int and 0 < size <= 64 * 1024 * 1024
        assert re.fullmatch(r'[a-f0-9]{64}', sha)
        path = adb.parent / name
        check_file(path, 64 * 1024 * 1024)
        assert path.stat().st_size == size
        assert digest(path) == sha, 'Portable ADB hash mismatch: ' + name
        names.add(name); total += size
    assert 'adb' in names and total <= 128 * 1024 * 1024
    return sorted(names), manifest

def check_file(path, maximum):
    value = path.lstat()
    assert stat.S_ISREG(value.st_mode) and value.st_nlink == 1 and value.st_uid in (0, os.geteuid()) and not value.st_mode & 0o022
    assert 0 < value.st_size <= maximum, 'Unsafe portable ADB file size'

def verify(adb):
    names, manifest = inventory(adb)
    for name in names:
        path = adb.parent / name
        check_file(path, 64 * 1024 * 1024)
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(path)], check=True, capture_output=True)
        deps = subprocess.check_output(['/usr/bin/otool', '-arch', 'arm64', '-L', str(path)], text=True).splitlines()[1:]
        for line in deps:
            dependency = line.strip().split(' (', 1)[0]
            if dependency.startswith(('/usr/lib/', '/System/Library/')):
                continue
            assert manifest is not None and dependency.startswith('@loader_path/'), 'ADB requires an unbundled dependency: ' + dependency
            assert dependency.removeprefix('@loader_path/') in names, 'ADB dependency escapes its inventory: ' + dependency
    return names, manifest

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--adb', type=pathlib.Path, required=True)
    parser.add_argument('--destination', type=pathlib.Path)
    parser.add_argument('--notices-destination', type=pathlib.Path)
    args = parser.parse_args()
    adb = args.adb.absolute()
    names, manifest = verify(adb)
    if args.destination:
        args.destination.mkdir(parents=True, exist_ok=True)
        for name in names + (['adb-runtime.json'] if manifest else []):
            shutil.copy2(adb.parent / name, args.destination / name)
        origins = adb.parent / 'dependency-origins.json'
        if manifest:
            assert origins.is_file(), 'Missing exact portable ADB dependency origins'
            mapping = json.loads(origins.read_bytes(), object_pairs_hook=unique_object)
            assert set(mapping).issubset(set(names) - {'adb'})
            assert set(mapping) == set(names) - {'adb'}, 'Unmapped portable ADB library source'
            assert all(type(value) is str and value.startswith('/opt/homebrew/Cellar/') for value in mapping.values())
            (args.destination / 'adb-dependency-origins.json').write_text(json.dumps(mapping, indent=2) + '\n')
        verify(args.destination / 'adb')
    if args.notices_destination and manifest:
        source = adb.parent / 'BUILD_PROVENANCE.json'
        assert stat.S_ISREG(source.lstat().st_mode) and source.stat().st_size <= 1_048_576, 'Missing/unsafe source ADB provenance'
        provenance = json.loads(source.read_bytes(), object_pairs_hook=unique_object)
        assert provenance['version'] == 1 and provenance['runtime_manifest_sha256'] == digest(manifest), 'ADB provenance does not bind this runtime'
        closure = provenance['source_closure']
        assert closure['path'] == 'SOURCE_CLOSURE.json' and re.fullmatch(r'[a-f0-9]{64}', closure['sha256'])
        closure_path = adb.parent / closure['path']
        check_file(closure_path, 4_194_304)
        assert digest(closure_path) == closure['sha256'], 'ADB source closure hash differs'
        notices = adb.parent / 'notices'
        assert stat.S_ISDIR(notices.lstat().st_mode), 'Missing source ADB notices'
        declared = {}
        for entry in provenance['notices']:
            path, sha = entry['path'], entry['sha256']
            assert re.fullmatch(r'notices/[A-Za-z0-9_.-]{1,120}', path) and path not in declared, 'Unsafe/duplicate ADB notice path'
            assert re.fullmatch(r'[a-f0-9]{64}', sha) and type(entry['source']) is str and 0 < len(entry['source']) <= 512
            check_file(adb.parent / path, 2_097_152)
            assert digest(adb.parent / path) == sha, 'ADB notice differs from source provenance: ' + path
            declared[path] = sha
        assert 1 <= len(declared) <= 128, 'Missing/oversized ADB notice declaration'
        files = list(notices.rglob('*'))
        assert len(files) <= 128
        total = 0
        for file in files:
            metadata = file.lstat()
            assert stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode), 'Unsafe ADB notice entry'
            if file.is_file():
                total += metadata.st_size
                assert total <= 2_097_152 and len(file.relative_to(notices).parts) <= 4, 'ADB notices exceed bounds'
        assert any(file.is_file() for file in files), 'Empty ADB source notices'
        assert {str(file.relative_to(adb.parent)) for file in files if file.is_file()} == set(declared), 'ADB notices do not match the declared cohort'
        args.notices_destination.mkdir(parents=True, exist_ok=True)
        shutil.copytree(notices, args.notices_destination, dirs_exist_ok=True)
        shutil.copy2(source, args.notices_destination / source.name)
        shutil.copy2(closure_path, args.notices_destination / closure_path.name)
    print(json.dumps({'portable': manifest is not None, 'files': names, 'verified_signatures_and_load_closure': True}))

if __name__ == '__main__':
    main()
