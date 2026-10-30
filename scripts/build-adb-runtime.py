#!/usr/bin/env python3
"""Build pinned, source-available ADB37; retain dynamic, replaceable libusb.

No command here starts an ADB server or connects to a device. Source downloads
use system curl's TLS validation followed by exact SHA256 verification. CMake
dependency fetching is disabled. Protobuf/Abseil are static permissive inputs;
libusb and compression libraries remain separate signed Mach-O siblings.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import uuid

REPO = Path(__file__).resolve().parents[1]
SOURCES = [
    ('android-tools', '37.0.0', 'android-tools-37.0.0.tar.xz', 'https://github.com/nmeum/android-tools/releases/download/37.0.0/android-tools-37.0.0.tar.xz', '2725d09f892a3a38e534429f47a321f58ecf6a3169caa42c915fb2cb7d46be0e', 'android-tools-37.0.0'),
    ('protobuf', '36.2', 'protobuf-36.2.tar.gz', 'https://github.com/protocolbuffers/protobuf/releases/download/v36.2/protobuf-36.2.tar.gz', '3d9642a662d10e68ebae5e53f14dcce5105684212d5078f8e0d47d1ab3ae6b64', 'protobuf-36.2'),
    ('abseil', '20260817.0', 'abseil-20260817.0.tar.gz', 'https://github.com/abseil/abseil-cpp/archive/refs/tags/20260817.0.tar.gz', 'f7e05179df39c45434cad433f5783840bb3788ef322976f9138bc6b72b3a107d', 'abseil-cpp-20260817.0'),
    ('googletest', '1.18.0', 'googletest-1.18.0.tar.gz', 'https://github.com/google/googletest/archive/refs/tags/v1.18.0.tar.gz', '6e3191c1455468b3fc35a417fb565c1c5071aee1b7e7f85e30cf48a98d37d8b5', 'googletest-1.18.0'),
]
PATCHES = ['android-tools-boringssl-headers.patch', 'android-tools-protobuf-logging.patch', 'android-tools-adb-includes.patch']

NOTICE_INPUTS = [
    ('android-tools', 'android-tools-37.0.0', 'LICENSE'),
    ('adb', 'android-tools-37.0.0', 'vendor/adb/NOTICE'),
    ('libbase', 'android-tools-37.0.0', 'vendor/libbase/NOTICE'),
    ('libcutils', 'android-tools-37.0.0', 'vendor/core/libcutils/NOTICE'),
    ('liblog', 'android-tools-37.0.0', 'vendor/logging/liblog/NOTICE'),
    ('boringssl', 'android-tools-37.0.0', 'vendor/boringssl/LICENSE'),
    ('boringssl-fiat', 'android-tools-37.0.0', 'vendor/boringssl/third_party/fiat/LICENSE'),
    ('boringssl-fiat', 'android-tools-37.0.0', 'vendor/boringssl/third_party/fiat/AUTHORS'),
    ('fmt', 'android-tools-37.0.0', 'vendor/fmtlib/LICENSE'),
    ('fmt', 'android-tools-37.0.0', 'vendor/fmtlib/NOTICE'),
    ('protobuf', 'protobuf-36.2', 'LICENSE'),
    ('protobuf-utf8-range', 'protobuf-36.2', 'third_party/utf8_range/LICENSE'),
    ('abseil', 'abseil-cpp-20260817.0', 'LICENSE'),
    ('abseil', 'abseil-cpp-20260817.0', 'AUTHORS'),
    ('googletest', 'googletest-1.18.0', 'LICENSE'),
]

def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1_048_576), b''):
            digest.update(block)
    return digest.hexdigest()

def run(argv, **kwargs):
    try:
        return subprocess.check_output([str(x) for x in argv], text=True, stderr=subprocess.STDOUT, **kwargs)
    except subprocess.CalledProcessError as error:
        sys.stderr.write(error.output or '')
        raise

def tree_inventory(root, exclude=()):
    """Hash names, file bytes, executable modes and symlink targets, never follow links."""
    inventory = {}
    for path in sorted(root.rglob('*')):
        name = str(path.relative_to(root))
        if name in exclude:
            continue
        info = path.lstat()
        if stat.S_ISDIR(info.st_mode):
            continue
        if stat.S_ISLNK(info.st_mode):
            inventory[name] = {'type': 'symlink', 'target': os.readlink(path)}
        elif stat.S_ISREG(info.st_mode):
            inventory[name] = {'type': 'file', 'sha256': sha(path), 'size': info.st_size, 'mode': stat.S_IMODE(info.st_mode)}
        else:
            raise RuntimeError(f'Unsupported source cache object: {path}')
    return inventory

def require_tree_match(actual, expected, exclude=()):
    inventory = tree_inventory(actual, exclude=exclude)
    if inventory != expected:
        added = sorted(set(inventory) - set(expected))[:8]
        missing = sorted(set(expected) - set(inventory))[:8]
        changed = [name for name in sorted(set(inventory) & set(expected)) if inventory[name] != expected[name]][:8]
        raise RuntimeError(f'Expanded source cache differs from pinned archive/patches: {actual}; added={added}, missing={missing}, changed={changed}. Preserve the cache and select a fresh --work directory.')
    return inventory

def verify_expanded_sources(work):
    """Derive the expected tree anew from authenticated archives, not a mutable cache marker."""
    expected_trees = {}
    with tempfile.TemporaryDirectory(prefix='adb-source-verification-', dir=work) as temporary:
        pristine = Path(temporary)
        for _, _, archive, _, digest, folder in SOURCES:
            cached = work / archive
            if sha(cached) != digest:
                raise RuntimeError(f'Exact source digest mismatch: {archive}')
            with tarfile.open(cached) as source:
                source.extractall(pristine, filter='data')
            if folder == 'android-tools-37.0.0':
                for patch in PATCHES:
                    run(['/usr/bin/patch', '-d', pristine / folder, '-p1', '--forward', '--input', REPO / 'scripts/patches' / patch])
            expected = tree_inventory(pristine / folder)
            require_tree_match(work / 'sources' / folder, expected, exclude=('.droidbridge-patches',) if folder == 'android-tools-37.0.0' else ())
            expected_trees[folder] = expected
    return expected_trees

def notice_comments(text):
    """Retain embedded attribution/license comments from actual compiler inputs."""
    expressions = [r'/\*.*?\*/', r'(?m)^\s*//[^\n]*(?:\n\s*//[^\n]*)*', r'(?m)^\s*\#[ \t]+[^\n]*(?:\n\s*\#[ \t]+[^\n]*)*']
    blocks = []
    for expression in expressions:
        for match in re.finditer(expression, text, re.DOTALL if expression.startswith('/\\') else 0):
            block = match.group(0).strip()
            if re.search(r'copyright|licen[sc]e|redistribution|permission is hereby granted|public domain', block, re.IGNORECASE):
                blocks.append((match.start(), block))
    return [block for _, block in sorted(blocks)]

def archive_members(path):
    # CMake runs ranlib when installing Darwin archives, changing the container
    # symbol-table timestamp. Compare every ordered object member's bytes rather
    # than treating that metadata rewrite as changed compiled code.
    data = path.read_bytes()
    if not data.startswith(b'!<arch>\n') or len(data) > 128 * 1_048_576:
        raise RuntimeError(f'Unsupported static archive: {path}')
    position, members = 8, []
    while position < len(data):
        header = data[position:position + 60]
        if len(header) != 60 or header[-2:] != b'`\n':
            raise RuntimeError(f'Malformed static archive: {path}')
        name = header[:16].decode('ascii').strip()
        size = int(header[48:58])
        start, end = position + 60, position + 60 + size
        if end > len(data):
            raise RuntimeError(f'Truncated static archive: {path}')
        if name.startswith('#1/'):
            length = int(name[3:])
            if not 0 < length <= 512 or length > size:
                raise RuntimeError(f'Invalid static archive member: {path}')
            name = data[start:start + length].rstrip(b'\x00').decode('utf-8')
            start += length
        else:
            name = name.removesuffix('/')
        if name not in ('__.SYMDEF', '__.SYMDEF SORTED'):
            if not name.endswith('.o') or len(members) >= 2048:
                raise RuntimeError(f'Unexpected static archive member {name}: {path}')
            members.append({'name': name, 'sha256': hashlib.sha256(data[start:end]).hexdigest(), 'size': end - start})
        position = end + (size & 1)
    if not members:
        raise RuntimeError(f'Empty static archive: {path}')
    return members

def source_closure(work):
    """Resolve the actual ADB link graph through installed static archives to compiler/header inputs."""
    adb_build = work / 'adb-release'
    commands = run(['ninja', '-C', adb_build, '-t', 'commands', 'adb'])
    prefix = work / 'static-prefix/lib'
    archives = sorted(set(Path(word) for word in shlex.split(commands.splitlines()[-1]) if word.endswith('.a') and word.startswith(str(prefix) + '/')))
    targets = {'adb-release': ['adb'], 'protobuf-release': [], 'abseil-release': []}
    archive_records = []
    for archive in archives:
        build_name = 'abseil-release' if archive.name.startswith('libabsl_') else 'protobuf-release'
        candidates = list((work / build_name).rglob(archive.name))
        if len(candidates) != 1 or archive_members(candidates[0]) != archive_members(archive):
            raise RuntimeError(f'Linked static archive differs from its exact build output: {archive}')
        archive_records.append({'name': archive.name, 'installed_sha256': sha(archive), 'build_sha256': sha(candidates[0]), 'ordered_object_members_sha256': hashlib.sha256(json.dumps(archive_members(archive), sort_keys=True, separators=(',', ':')).encode()).hexdigest()})
        targets[build_name].append(str(candidates[0].relative_to(work / build_name)))
    inputs = set()
    graphs = []
    for build_name, selected in targets.items():
        if not selected:
            continue
        build = work / build_name
        graph = run(['ninja', '-C', build, '-t', 'inputs'] + selected)
        objects = []
        for line in graph.splitlines():
            path = Path(line)
            resolved = path if path.is_absolute() else build / path
            if resolved.is_file():
                inputs.add(resolved.resolve())
            if line.endswith('.o'):
                objects.append(line)
        # Ninja's saved depfiles include header inputs absent from its static
        # build graph. Query only objects reachable from the linked archives.
        for offset in range(0, len(objects), 64):
            deps = run(['ninja', '-C', build, '-t', 'deps'] + objects[offset:offset + 64])
            for line in deps.splitlines():
                if line.startswith('    '):
                    path = Path(line.strip())
                    resolved = path if path.is_absolute() else build / path
                    if resolved.is_file():
                        inputs.add(resolved.resolve())
        graphs.append({'build': build_name, 'targets': selected, 'input_graph_sha256': hashlib.sha256(graph.encode()).hexdigest(), 'objects': len(objects)})
    source_root = work / 'sources'
    files = []
    headers = []
    generated_headers = []
    for path in sorted(inputs):
        if not path.is_relative_to(source_root):
            # Protobuf/Abseil installed headers must correspond to the verified
            # source tree, rather than becoming unrecorded prefix-cache inputs.
            include = work / 'static-prefix/include'
            if path.is_relative_to(include):
                relative = path.relative_to(include)
                candidates = [source_root / 'abseil-cpp-20260817.0' / relative, source_root / 'protobuf-36.2/src' / relative, source_root / 'protobuf-36.2/third_party/utf8_range' / relative]
                matching = [candidate for candidate in candidates if candidate.is_file() and sha(candidate) == sha(path)]
                if not matching and str(relative) == 'absl/base/options.h':
                    # Abseil's verified CMake recipe pins C++17 ABI choices in
                    # the installed header. Derive those exact bytes from its
                    # source template instead of trusting the generated cache.
                    template = source_root / 'abseil-cpp-20260817.0/absl/base/options.h'
                    expected = template.read_bytes().replace(b'#define ABSL_OPTION_USE_STD_SOURCE_LOCATION 2', b'#define ABSL_OPTION_USE_STD_SOURCE_LOCATION 0').replace(b'#define ABSL_OPTION_USE_STD_ORDERING 2', b'#define ABSL_OPTION_USE_STD_ORDERING 0')
                    generated = work / 'abseil-release/options-pinned.h'
                    if path.read_bytes() == expected and generated.read_bytes() == expected:
                        generated_headers.append({'path': 'abseil-release/options-pinned.h', 'sha256': sha(generated), 'source': str(template.relative_to(source_root)), 'transform': 'Abseil CMake C++17 ABI pin: STD_SOURCE_LOCATION=0, STD_ORDERING=0'})
                        matching = [template]
                if not matching:
                    raise RuntimeError(f'Installed static header differs from verified source: {relative}')
                path = matching[0]
            else:
                continue  # SDK, generated build files and dynamic Homebrew inputs have separate provenance.
        name = str(path.relative_to(source_root))
        if any(file['path'] == name for file in files):
            continue
        files.append({'path': name, 'sha256': sha(path), 'size': path.stat().st_size})
        if path.suffix in ('.h', '.hpp', '.hh', '.inc', '.c', '.cc', '.cpp', '.S', '.s') and path.stat().st_size < 8 * 1_048_576:
            blocks = notice_comments(path.read_text(errors='replace'))
            if blocks:
                headers.append('===== ' + name + ' =====\n' + '\n\n'.join(blocks) + '\n')
    return {'version': 1, 'graphs': graphs, 'static_archives': archive_records, 'generated_headers': generated_headers, 'files': sorted(files, key=lambda item: item['path'])}, '\n'.join(headers)

def dependencies(path):
    return [line.strip().split(' (', 1)[0] for line in run(['/usr/bin/otool', '-arch', 'arm64', '-L', path]).splitlines()[1:]]

def resolve_dependency(dependency, parent):
    if dependency.startswith('@loader_path/'):
        return (parent.parent / dependency[len('@loader_path/'):]).resolve()
    if dependency.startswith('@rpath/'):
        # Homebrew relocatable libraries keep their siblings in the same exact
        # Cellar lib directory. Never search PATH or a user's current directory.
        candidate = parent.parent / dependency[len('@rpath/'):]
        if candidate.is_file():
            return candidate.resolve()
        raise RuntimeError(f'Unresolved exact sibling dependency {dependency}: {parent}')
    if dependency.startswith('/'):
        return Path(dependency).resolve()
    raise RuntimeError(f'Unsupported dependency reference {dependency}: {parent}')

def package(binary, output, source_records, work):
    stage = output.parent / (output.name + '-stage-' + str(uuid.uuid4()))
    stage.mkdir(mode=0o700)
    shutil.copy2(binary, stage / 'adb')
    names = {str(binary.resolve()): 'adb'}
    originals = {str(binary.resolve()): binary.resolve()}
    queue = [binary.resolve()]
    edges = {}
    origins = {}
    while queue:
        original = queue.pop(0)
        edges[str(original)] = []
        for dependency in dependencies(original):
            if dependency.startswith(('/usr/lib/', '/System/Library/')):
                continue
            resolved = resolve_dependency(dependency, original)
            if not resolved.is_file() or not str(resolved).startswith('/opt/homebrew/Cellar/'):
                raise RuntimeError(f'Non-pinned runtime origin: {resolved}')
            name = 'adb-lib' + resolved.name.removeprefix('lib')
            if not re.fullmatch(r'adb-lib[A-Za-z0-9_.-]+\.dylib', name) or len(name) > 120:
                raise RuntimeError(f'Unsupported library name: {name}')
            if str(resolved) not in names:
                if name in names.values():
                    raise RuntimeError(f'Library basename collision: {name}')
                names[str(resolved)] = name
                originals[str(resolved)] = resolved
                origins[name] = str(resolved)
                shutil.copy2(resolved, stage / name)
                queue.append(resolved)
            edges[str(original)].append((dependency, names[str(resolved)]))
    if not 2 <= len(names) <= 15:
        raise RuntimeError(f'Portable runtime exceeds file budget: {len(names)}')
    for key, name in names.items():
        target = stage / name
        target.chmod(0o755)
        # Remove the old signature before load-command edits; sign exact final bytes.
        subprocess.run(['/usr/bin/codesign', '--remove-signature', str(target)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for dependency, replacement in edges[key]:
            run(['/usr/bin/install_name_tool', '-change', dependency, '@loader_path/' + replacement, target])
        if name != 'adb':
            run(['/usr/bin/install_name_tool', '-id', '@loader_path/' + name, target])
        run(['/usr/bin/codesign', '--force', '--sign', '-', target])
        run(['/usr/bin/codesign', '--verify', '--strict', target])
    files = [{'name': name, 'size': (stage / name).stat().st_size, 'sha256': sha(stage / name)} for name in sorted(names.values())]
    if any(x['size'] > 64 * 1_048_576 for x in files) or sum(x['size'] for x in files) > 128 * 1_048_576:
        raise RuntimeError('Portable runtime exceeds byte budget')
    (stage / 'adb-runtime.json').write_text(json.dumps({'version': 1, 'files': files}, sort_keys=True, indent=2) + '\n')
    (stage / 'dependency-origins.json').write_text(json.dumps(origins, sort_keys=True, indent=2) + '\n')
    source_out = stage / 'sources'
    source_out.mkdir()
    records = []
    for record in source_records:
        archive = work / record['archive']
        shutil.copy2(archive, source_out / archive.name)
        records.append(dict(record, staged_source='sources/' + archive.name))
    for name in PATCHES:
        shutil.copy2(REPO / 'scripts/patches' / name, source_out / name)
    for name in ('build-adb-runtime.sh', 'build-adb-runtime.py'):
        shutil.copy2(REPO / 'scripts' / name, source_out / name)
    notices = stage / 'notices'
    notices.mkdir()
    notice_records = []
    for package_name, source_relative, notice in NOTICE_INPUTS:
        source = work / 'sources' / source_relative / notice
        target = notices / (package_name + '-' + source.name)
        shutil.copy2(source, target)
        notice_records.append({'path': 'notices/' + target.name, 'sha256': sha(target), 'source': source_relative + '/' + notice})
    closure, header_notices = source_closure(work)
    closure_path = stage / 'SOURCE_CLOSURE.json'
    closure_path.write_text(json.dumps(closure, sort_keys=True, indent=2) + '\n')
    header_path = notices / 'SOURCE_HEADER_NOTICES.txt'
    header_path.write_text('Attribution and license comments retained from the exact linked compiler/header input closure.\nComplete sources and license files accompany this build.\n\n' + header_notices)
    notice_records.append({'path': 'notices/' + header_path.name, 'sha256': sha(header_path), 'source': 'SOURCE_CLOSURE.json'})
    provenance = {'version': 1, 'architecture': 'arm64', 'deployment_target': '26.0', 'adb_version': '37.0.0',
        'sources': records, 'patches': [{'path': 'sources/' + name, 'sha256': sha(REPO / 'scripts/patches' / name)} for name in PATCHES],
        'recipes': [{'path': 'sources/' + name, 'sha256': sha(REPO / 'scripts' / name)} for name in ('build-adb-runtime.sh', 'build-adb-runtime.py')],
        'static_dependencies': ['vendored BoringSSL', 'vendored fmt', 'protobuf 36.2', 'abseil 20260817.0'],
        'dynamic_dependencies': origins,
        'toolchain': {name: run(command).splitlines()[0] for name, command in [('clang', ['/usr/bin/clang', '--version']), ('cmake', ['cmake', '--version']), ('ninja', ['ninja', '--version'])]},
        'runtime_manifest_sha256': sha(stage / 'adb-runtime.json'),
        'source_tree_verification': 'freshly extracted pinned archives plus approved patches; verified before and after build',
        'source_closure': {'path': 'SOURCE_CLOSURE.json', 'sha256': sha(closure_path)}, 'notices': notice_records}
    (stage / 'BUILD_PROVENANCE.json').write_text(json.dumps(provenance, sort_keys=True, indent=2) + '\n')
    for path in stage.iterdir():
        if path.is_file():
            path.chmod(0o755 if path.name == 'adb' or path.suffix == '.dylib' else 0o644)
    # Offline validation: do not start a server, enumerate devices, or alter keys.
    version = run([stage / 'adb', 'version'], env={'PATH': '/usr/bin:/bin', 'HOME': str(Path.home())})
    if 'Version 37.0.0-android-tools' not in version:
        raise RuntimeError('Unexpected source-built ADB version')
    if output.exists():
        output.rename(output.parent / (output.name + '-previous-' + str(uuid.uuid4())))
    stage.rename(output)
    print(version, end='')
    print(f'Portable ADB: {output}; {len(files)-1} dynamic libraries, {sum(x["size"] for x in files):,} bytes')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', type=Path, default=REPO / '.build/adb-runtime-work')
    parser.add_argument('--output', type=Path, default=REPO / '.build/adb-runtime')
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    if platform.system() != 'Darwin' or platform.machine() != 'arm64' or not 1 <= args.jobs <= 8:
        raise SystemExit('This recipe requires arm64 macOS with a bounded 1...8 build jobs')
    work, output = args.work.resolve(), args.output.resolve()
    work.mkdir(parents=True, exist_ok=True)
    source_root = work / 'sources'
    source_root.mkdir(exist_ok=True)
    records = []
    for name, version, archive, url, digest, folder in SOURCES:
        cached = work / archive
        if not cached.exists():
            run(['/usr/bin/curl', '--fail', '--location', '--retry', '2', '--output', cached, url])
        if sha(cached) != digest:
            raise RuntimeError(f'Exact source digest mismatch: {archive}')
        records.append({'name': name, 'version': version, 'archive': archive, 'url': url, 'sha256': digest})
        destination = source_root / folder
        if not destination.exists():
            with tarfile.open(cached) as source:
                source.extractall(source_root, filter='data')
    android = source_root / 'android-tools-37.0.0'
    patch_identity = hashlib.sha256(''.join(sha(REPO / 'scripts/patches' / p) for p in PATCHES).encode()).hexdigest()
    marker = android / '.droidbridge-patches'
    if marker.exists() and marker.read_text().strip() != patch_identity:
        raise RuntimeError('Build patches changed; choose a fresh --work directory to preserve previous inputs')
    if not marker.exists():
        for patch in PATCHES:
            run(['/usr/bin/patch', '-d', android, '-p1', '--forward', '--input', REPO / 'scripts/patches' / patch])
        marker.write_text(patch_identity + '\n')
    expected_trees = verify_expanded_sources(work)
    for record, source in zip(records, SOURCES):
        inventory = expected_trees[source[-1]]
        record['tree_sha256'] = hashlib.sha256(json.dumps(inventory, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        record['tree_file_count'] = len(inventory)
    print('Expanded source caches match all pinned archives and approved patches.', flush=True)
    prefix = work / 'static-prefix'
    common = ['-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_OSX_ARCHITECTURES=arm64', '-DCMAKE_OSX_DEPLOYMENT_TARGET=26.0', '-DCMAKE_CXX_STANDARD=17', '-DCMAKE_INSTALL_PREFIX=' + str(prefix)]
    for folder, build_name, options in [
        ('abseil-cpp-20260817.0', 'abseil-release', ['-DBUILD_SHARED_LIBS=OFF', '-DABSL_PROPAGATE_CXX_STD=ON', '-DABSL_ENABLE_INSTALL=ON', '-DABSL_BUILD_TESTING=OFF']),
        ('protobuf-36.2', 'protobuf-release', ['-DCMAKE_PREFIX_PATH=' + str(prefix), '-DBUILD_SHARED_LIBS=OFF', '-Dprotobuf_BUILD_SHARED_LIBS=OFF', '-Dprotobuf_BUILD_TESTS=OFF', '-Dprotobuf_BUILD_PROTOC_BINARIES=ON', '-Dprotobuf_BUILD_LIBPROTOC=ON', '-Dprotobuf_FORCE_FETCH_DEPENDENCIES=OFF', '-Dprotobuf_LOCAL_DEPENDENCIES_ONLY=ON']),
    ]:
        build = work / build_name
        print(f'Building {folder}', flush=True)
        for command in [['cmake', '-S', source_root / folder, '-B', build] + common + options, ['cmake', '--build', build, '--parallel', str(args.jobs)], ['cmake', '--install', build]]:
            print(run(command), end='', flush=True)
    build = work / 'adb-release'
    options = ['-DCMAKE_PREFIX_PATH=' + str(prefix), '-DProtobuf_DIR=' + str(prefix / 'lib/cmake/protobuf'), '-Dabsl_DIR=' + str(prefix / 'lib/cmake/absl'), '-DProtobuf_USE_STATIC_LIBS=ON', '-DANDROID_TOOLS_USE_BUNDLED_FMT=ON', '-DANDROID_TOOLS_USE_BUNDLED_LIBUSB=OFF', '-DANDROID_TOOLS_PATCH_VENDOR=OFF', '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON', '-DDROIDBRIDGE_GOOGLETEST_INCLUDE=' + str(source_root / 'googletest-1.18.0/googletest/include')]
    print(run(['cmake', '-S', android, '-B', build] + common + options), end='', flush=True)
    print(run(['cmake', '--build', build, '--target', 'adb', '--parallel', str(args.jobs)]), end='', flush=True)
    for folder, expected in expected_trees.items():
        require_tree_match(source_root / folder, expected, exclude=('.droidbridge-patches',) if folder == 'android-tools-37.0.0' else ())
    package(build / 'vendor/adb', output, records, work)

if __name__ == '__main__':
    main()
