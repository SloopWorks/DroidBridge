#!/usr/bin/env python3
"""Copy and relink every non-system Mach-O dependency into an app-local runtime."""
import pathlib, re, shutil, subprocess, sys, json
root = pathlib.Path(sys.argv[1]).resolve()
lib = root / 'lib'
queue = list((root / 'bin').iterdir())
seen = set()
manifest = {}
def run(*args):
    return subprocess.check_output(args, text=True)
portable = set()
adb_manifest = root / 'bin/adb-runtime.json'
if adb_manifest.exists():
    # These bytes were already relocated and signed together. Rewriting or
    # re-signing one would invalidate the private-service runtime inventory.
    subprocess.run([sys.executable, str(pathlib.Path(__file__).with_name('stage-adb-runtime.py')), '--adb', str(root / 'bin/adb')], check=True)
    portable = {entry['name'] for entry in json.loads(adb_manifest.read_text())['files']}
    origins = json.loads((root / 'bin/adb-dependency-origins.json').read_text())
    manifest.update({'bin/' + name: origin for name, origin in origins.items()})
while queue:
    binary = queue.pop(0)
    if str(binary) in seen: continue
    seen.add(str(binary))
    if binary.parent == root / 'bin' and binary.name in portable: continue
    if 'Mach-O' not in run('/usr/bin/file', '-b', str(binary)): continue
    lines = run('otool', '-arch', 'arm64', '-L', str(binary)).splitlines()[1:]
    for line in lines:
        dependency = line.strip().split(' (', 1)[0]
        if dependency.startswith(('/usr/lib/', '/System/Library/', '@rpath/', '@loader_path/', '@executable_path/')): continue
        original = pathlib.Path(dependency)
        if not original.is_file(): raise RuntimeError(f'Missing dependency {dependency} for {binary}')
        target = lib / original.name
        if not target.exists():
            shutil.copy2(original.resolve(), target)
            target.chmod(0o755)
            queue.append(target)
            manifest[str(target.relative_to(root))] = str(original.resolve())
        else:
            existing = manifest.get(str(target.relative_to(root)))
            if existing and existing != str(original.resolve()): raise RuntimeError(f'Dependency basename collision: {original} / {existing}')
        relative = '@loader_path/' + ('../lib/' if binary.parent.name == 'bin' else '') + target.name
        subprocess.run(['install_name_tool', '-change', dependency, relative, str(binary)], check=True)
    if binary.suffix == '.dylib': subprocess.run(['install_name_tool', '-id', '@loader_path/' + binary.name, str(binary)], check=True)
(root / 'dependencies.json').write_text(json.dumps(manifest, indent=2) + '\n')
# Retain dependency license notices and exact Homebrew build receipts beside the runtime.
licenses = root.parent / 'licenses'
for source in sorted(set(manifest.values())):
    path = pathlib.Path(source)
    parts = path.parts
    if 'Cellar' not in parts: continue
    index = parts.index('Cellar')
    package_root = pathlib.Path(*parts[:index + 3])
    package_name = package_root.parent.name
    destination = licenses / package_name
    destination.mkdir(parents=True, exist_ok=True)
    for pattern in ['LICENSE*', 'COPYING*', 'NOTICE*', 'AUTHORS*', 'INSTALL_RECEIPT.json', 'sbom.spdx.json']:
        for notice in package_root.glob(pattern):
            if notice.is_file(): shutil.copy2(notice, destination / notice.name)
