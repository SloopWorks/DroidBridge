#!/usr/bin/env python3
"""Fail closed if a locally installed bundle relies on external dylib paths.
Does not assert Gatekeeper trust or notarization from ad-hoc codesigning.
"""
import argparse, hashlib, json, os, pathlib, plistlib, subprocess, zipfile
if not __debug__:
    raise SystemExit('Package validation requires Python assertions; remove -O/PYTHONOPTIMIZE.')

SYSTEM_PREFIXES = ('/usr/lib/', '/System/Library/')
MAX_PLAYER_LIBRARIES = 64
MAX_PLAYER_LIBRARY_BYTES = 256 * 1024 * 1024
MACHO_MAGIC = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
               b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
               b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}

def run(*command):
    return subprocess.check_output(command, text=True, stderr=subprocess.STDOUT, timeout=30)

def is_macho(path):
    with path.open('rb') as stream:
        return stream.read(4) in MACHO_MAGIC

def dependencies(path):
    return [line.strip().split(' (', 1)[0]
            for line in run('/usr/bin/otool', '-arch', 'arm64', '-L', str(path)).splitlines()[1:]]

def rpaths(path):
    lines = run('/usr/bin/otool', '-arch', 'arm64', '-l', str(path)).splitlines()
    return [lines[i + 2].strip().removeprefix('path ').split(' (', 1)[0]
            for i, line in enumerate(lines[:-2]) if line.strip() == 'cmd LC_RPATH']

def is_system_dependency(dependency):
    if not dependency.startswith(SYSTEM_PREFIXES): return False
    parts = pathlib.PurePosixPath(dependency)
    assert str(parts) == dependency and not any(part in ('.', '..') for part in parts.parts), f'noncanonical system dependency: {dependency}'
    return True

def resolve_dependency(dependency, loader, executable, jail):
    if is_system_dependency(dependency):
        return None  # Apple dyld-cache libraries need not exist as filesystem files.
    def expand(value):
        if value.startswith('@loader_path/'):
            return loader.parent / value.removeprefix('@loader_path/')
        if value.startswith('@executable_path/'):
            return executable.parent / value.removeprefix('@executable_path/')
        raise AssertionError(f'unsupported or external dependency path {loader}: {value}')
    if dependency.startswith('@rpath/'):
        suffix = dependency.removeprefix('@rpath/')
        candidates = []
        for owner in dict.fromkeys((loader, executable)):
            for entry in rpaths(owner):
                # Every active search entry must stay jailed. Skipping an earlier
                # external path would not model dyld's first-match behavior safely.
                assert entry.startswith(('@loader_path/', '@executable_path/')), f'external or unsupported rpath {loader}: {entry}'
                base = (owner.parent / entry.removeprefix('@loader_path/')) if entry.startswith('@loader_path/') else (executable.parent / entry.removeprefix('@executable_path/'))
                candidate = (base / suffix).resolve()
                assert candidate.is_relative_to(jail), f'dependency escapes bundle: {candidate}'
                if candidate.is_file(): candidates.append(candidate)
        assert candidates, f'unresolved rpath dependency {loader}: {dependency}'
        assert len(set(candidates)) == 1, f'ambiguous rpath dependency {loader}: {dependency}'
        return candidates[0]
    resolved = expand(dependency).resolve()
    assert resolved.is_relative_to(jail), f'dependency escapes bundle: {resolved}'
    assert resolved.is_file(), f'missing dependency {resolved}'
    return resolved

def check_symlinks(root):
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            path = pathlib.Path(directory) / name
            if path.is_symlink():
                target = path.resolve(strict=True)
                assert not os.path.isabs(os.readlink(path)) and target.is_relative_to(root), f'symlink escapes bundle: {path}'

def verify_machos(root, executable):
    result = {}
    check_symlinks(root)
    for file in sorted(root.rglob('*')):
        if not file.is_file() or file.is_symlink() or not is_macho(file): continue
        signature = run('/usr/bin/codesign', '--verify', '--strict', str(file))
        deps = dependencies(file)
        for dependency in deps: resolve_dependency(dependency, file, executable, root)
        result[str(file.relative_to(root))] = {'signature': signature, 'dependencies': deps}
    assert result, f'no Mach-O code in {root}'
    return result

def sha256_file(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()

def stage_player_libraries(runtime, player):
    """Copy the pinned Player's bounded closure without changing signed dylib bytes."""
    runtime = runtime.resolve(strict=True); player = player.resolve(strict=True)
    source_lib = (runtime / 'lib').resolve(strict=True)
    target_lib = player / 'Contents/lib'
    assert not target_lib.exists() and not target_lib.is_symlink(), 'Player library directory must be new'
    target_lib.mkdir()
    source_executable = runtime / 'bin/scrcpy'
    target_executable = player / 'Contents/MacOS/scrcpy'
    assert target_executable.read_bytes() == source_executable.read_bytes(), 'Player executable differs from staged scrcpy'
    queue = [(source_executable, target_executable)]
    entries = {}; total = 0
    while queue:
        source, target = queue.pop(0)
        for dependency in dependencies(source):
            if is_system_dependency(dependency): continue
            resolved = resolve_dependency(dependency, source, source_executable, runtime)
            assert resolved.is_relative_to(source_lib), f'Player library outside runtime/lib: {resolved}'
            # The pinned relocation uses only @loader_path and requires no relinking.
            assert dependency.startswith('@loader_path/'), f'unsupported Player staging token: {dependency}'
            destination = (target.parent / dependency.removeprefix('@loader_path/')).resolve()
            assert destination.parent == target_lib, f'Player dependency outside local lib: {destination}'
            assert destination.suffix == '.dylib' and is_macho(resolved), f'invalid Player dylib: {resolved}'
            size = resolved.stat().st_size
            existing = entries.get(destination.name)
            if existing:
                assert size == existing['size'], f'Player library collision: {destination.name}'
            else:
                assert len(entries) < MAX_PLAYER_LIBRARIES and 0 < size <= MAX_PLAYER_LIBRARY_BYTES - total, 'Player library closure exceeds bounds'
            digest = sha256_file(resolved)
            entry = {'name': destination.name, 'source': str(resolved.relative_to(runtime)),
                     'sha256': digest, 'size': size}
            if destination.name in entries:
                assert entries[destination.name] == entry, f'Player library collision: {destination.name}'
                continue
            total += size
            import shutil
            shutil.copy2(resolved, destination)
            assert destination.stat().st_size == size and sha256_file(destination) == digest
            entries[destination.name] = entry
            queue.append((resolved, destination))
    inventory = {'schema': 1, 'files': [entries[key] for key in sorted(entries)], 'logical_bytes': total}
    (player / 'Contents/Resources/dylib-inventory.json').write_text(json.dumps(inventory, indent=2) + '\n')
    return inventory

def verify_player_bundle(player):
    player = player.resolve(strict=True)
    library = player / 'Contents/lib'
    assert library.is_dir() and not library.is_symlink(), 'Player Contents/lib must be a real internal directory'
    check_symlinks(player)
    info = plistlib.loads((player / 'Contents/Info.plist').read_bytes())
    assert info.get('CFBundleExecutable') == 'scrcpy', 'unexpected Player executable'
    signature = run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(player))
    code = verify_machos(player, player / 'Contents/MacOS/scrcpy')
    inventory = json.loads((player / 'Contents/Resources/dylib-inventory.json').read_text())
    assert inventory['schema'] == 1 and 0 < len(inventory['files']) <= MAX_PLAYER_LIBRARIES
    names = set(); total = 0
    for entry in inventory['files']:
        name = entry['name']; assert name == pathlib.Path(name).name and name not in names
        names.add(name); file = library / name
        assert file.is_file() and not file.is_symlink() and is_macho(file)
        size = file.stat().st_size
        assert type(entry['size']) is int and size == entry['size']
        assert 0 < size <= MAX_PLAYER_LIBRARY_BYTES - total, 'Player library inventory exceeds bounds'
        total += size
        assert sha256_file(file) == entry['sha256'], f'Player inventory hash mismatch: {name}'
        assert entry['source'] == 'lib/' + name
    assert set(path.name for path in library.iterdir()) == names, 'Player library inventory differs from files'
    assert total == inventory['logical_bytes'] and total <= MAX_PLAYER_LIBRARY_BYTES
    # Every local library must be reachable; no unused code can hide in the closure.
    reachable = set(); queue = [player / 'Contents/MacOS/scrcpy']
    while queue:
        file = queue.pop()
        if file in reachable: continue
        reachable.add(file)
        for dep in dependencies(file):
            resolved = resolve_dependency(dep, file, player / 'Contents/MacOS/scrcpy', player)
            if resolved is not None: queue.append(resolved)
    assert reachable == {player / path for path in code}, 'Player contains unreachable Mach-O code'
    return {'codesign': signature, 'machos': code, 'library_inventory': inventory}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=pathlib.Path)
    parser.add_argument('--output', type=pathlib.Path, default=pathlib.Path('verification/review/package.json'))
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--signatures-only', action='store_true', help='offline all-Mach-O and nested Player signature checks; executes no bundled code')
    mode.add_argument('--player-only', action='store_true', help='offline nested signature and dependency checks; executes no bundled code')
    mode.add_argument('--stage-player-libraries-from', type=pathlib.Path, metavar='RUNTIME', help='assemble a bounded, byte-preserving local Player dylib closure')
    args = parser.parse_args()
    app = args.app.resolve(); assert app.is_dir() and app.suffix == '.app'
    if args.stage_player_libraries_from:
        report = stage_player_libraries(args.stage_player_libraries_from, app)
    elif args.player_only:
        report = {'app': str(app), 'player_bundle': verify_player_bundle(app)}
    elif args.signatures_only:
        report = {'app': str(app), 'codesign': run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)),
                  'dependencies': verify_machos(app, app/'Contents/MacOS/DroidBridge'),
                  'player_bundle': verify_player_bundle(app/'Contents/Resources/Runtime/Player.app')}
    else:
        report = {'app': str(app), 'codesign': run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)),
                  'dependencies': verify_machos(app, app/'Contents/MacOS/DroidBridge')}
        runtime=app/'Contents/Resources/Runtime'
        report['adb_portable_inventory']=subprocess.check_output(['python3',str(pathlib.Path(__file__).with_name('stage-adb-runtime.py')),'--adb',str(runtime/'bin/adb')],text=True,stderr=subprocess.STDOUT,timeout=30)
        for binary in ('adb','scrcpy'):
            environment=os.environ.copy(); environment['PATH']='/usr/bin:/bin'; environment['HOME']=str(pathlib.Path.home())
            report[binary]=subprocess.check_output([str(runtime/'bin'/binary),'--version' if binary=='scrcpy' else 'version'],env=environment,text=True,stderr=subprocess.STDOUT)
        assert 'scrcpy 5.0.1' in report['scrcpy']
        audio=runtime/'bin/DroidBridgeAudioClient'
        assert audio.is_file() and os.access(audio,os.X_OK), 'missing audio client'
        report['audio_client']=subprocess.check_output([str(audio),'--version'],env=environment,text=True,stderr=subprocess.STDOUT,timeout=5)
        assert 'scrcpy 5.0.1' in report['audio_client']
        audio_strings=run('/usr/bin/strings',str(audio))
        assert 'DROIDBRIDGE_AUDIO_OUTPUT_READY' in audio_strings and 'DROIDBRIDGE_AUDIO_SCID' in audio_strings
        helper=runtime/'bin/DroidBridgeAvailability'
        assert helper.is_file() and os.access(helper,os.X_OK), 'missing device availability helper'
        report['availability_helper']=subprocess.check_output([str(helper),'--version'],env=environment,text=True,stderr=subprocess.STDOUT,timeout=5)
        assert 'DroidBridgeAvailability' in report['availability_helper']
        assert (runtime/'bin/DroidBridgeSupervisor').is_file(), 'missing session supervisor'
        broker=runtime/'bin/DroidBridgeCompanionBroker'
        assert broker.is_file() and os.access(broker,os.X_OK), 'missing companion broker'
        report['companion_broker']=subprocess.check_output([str(broker),'--version'],env=environment,text=True,stderr=subprocess.STDOUT,timeout=5)
        assert 'DroidBridgeCompanionBroker protocol 1' in report['companion_broker']
        apk=app/'Contents/Resources/Companion/DroidBridgeCompanion.apk'
        assert apk.is_file() and 0 < apk.stat().st_size <= 32*1024*1024, 'missing/oversized companion APK'
        report['companion_apk_sha256']=hashlib.sha256(apk.read_bytes()).hexdigest()
        assert (apk.parent/'APK-SHA256.txt').read_text().split()[0] == report['companion_apk_sha256'], 'companion APK hash mismatch'
        report['companion_notices'] = {}
        with zipfile.ZipFile(apk) as archive:
            for name in ('Apache-2.0.txt', 'COMPONENTS.txt', 'NOTICE.txt', 'zxing-NOTICE.txt', 'kotlin-NOTICE.txt', 'SOURCES.json'):
                entry=archive.getinfo('assets/licenses/'+name)
                assert 0 < entry.file_size <= 65_536, 'oversized companion notice'
                data=archive.read(entry)
                assert data == (app/'Contents/Resources/licenses/android-companion'/name).read_bytes(), 'companion APK/bundle notices differ'
                report['companion_notices'][name]=hashlib.sha256(data).hexdigest()
        info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
        assert info.get('NSCameraUsageDescription'), 'missing explicit pairing camera usage explanation'
        report['version']=info['CFBundleShortVersionString']; report['build']=info['CFBundleVersion']
        report['player_bundle'] = verify_player_bundle(runtime/'Player.app')
        report['player']=subprocess.check_output([str(runtime/'Player.app/Contents/MacOS/scrcpy'),'--version'],env=environment,text=True,stderr=subprocess.STDOUT)
        assert 'scrcpy 5.0.1' in report['player']
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(f"PASS package checks; report {args.output}")

if __name__ == '__main__':
    main()
