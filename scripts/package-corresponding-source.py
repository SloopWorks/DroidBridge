#!/usr/bin/env python3
"""Package exact reviewed source inputs beside release binaries; no uploading."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

if not __debug__:
    raise SystemExit('Corresponding-source validation requires Python assertions; remove -O/PYTHONOPTIMIZE.')

parser=argparse.ArgumentParser()
parser.add_argument('--commit', required=True, help='Exact committed DroidBridge candidate')
parser.add_argument('--dependencies', type=Path, default=Path('.build/corresponding-source'))
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--adb-runtime', type=Path, default=Path('.build/adb-runtime'))
parser.add_argument('--app', type=Path, default=Path('dist/DroidBridge.app'))
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(args.app.resolve())],check=True,capture_output=True)
for candidate in (args.adb_runtime.resolve()/'adb',args.app.resolve()/'Contents/Resources/Runtime/bin/adb'):
    subprocess.run(['python3',str(root/'scripts/stage-adb-runtime.py'),'--adb',str(candidate)],check=True,capture_output=True)
def run(argv): return subprocess.check_output(argv,cwd=root,text=True).strip()
def digest(path):
    value=hashlib.sha256()
    with path.open('rb') as file:
        for block in iter(lambda:file.read(1048576),b''):value.update(block)
    return value.hexdigest()
commit=run(['git','rev-parse',args.commit+'^{commit}'])
manifest=json.loads((args.dependencies/'MANIFEST.json').read_text())
assert len(manifest)>=1,'No verified dependency source'
origins=json.loads((args.app/'Contents/Resources/Runtime/dependencies.json').read_text())
required=set()
for origin in origins.values():
    parts=Path(origin).parts
    assert 'Cellar' in parts,'Unmapped non-system dependency origin'
    index=parts.index('Cellar')
    assert len(parts)>index+3,'Incomplete dependency origin'
    required.add((parts[index+1],parts[index+2]))
provided={(item['name'],item['version']) for item in manifest}
assert len(provided)==len(manifest),'Duplicate corresponding-source formula identity'
assert provided==required,'Corresponding-source formula/version cohort differs from the packaged runtime'
for item in manifest:
    source=(args.dependencies/item['source']).resolve()
    assert source.is_relative_to(args.dependencies.resolve()) and source.is_file(),'Unsafe source entry'
    assert digest(source)==item['source_sha256'],'Source hash changed'
    recipe=args.dependencies/(item['name']+'-'+item['version'])/(item['name']+'.rb')
    assert digest(recipe)==item['recipe_sha256'],'Recipe hash changed'
    if item.get('git_bundle'):
        bundle=(args.dependencies/item['git_bundle']).resolve()
        assert bundle.is_relative_to(args.dependencies.resolve()) and digest(bundle)==item['git_bundle_sha256'],'Git source history changed'
adb_root=args.adb_runtime.resolve()
adb_provenance=adb_root/'BUILD_PROVENANCE.json'
adb_manifest=adb_root/'adb-runtime.json'
adb_info=json.loads(adb_provenance.read_text())
assert adb_info['version']==1 and adb_info['runtime_manifest_sha256']==digest(adb_manifest),'ADB source provenance differs from runtime'
assert (args.app/'Contents/Resources/Runtime/bin/adb-runtime.json').read_bytes()==adb_manifest.read_bytes(),'Packaged ADB is not this source-built runtime'
assert (args.app/'Contents/Resources/licenses/adb-source-runtime/BUILD_PROVENANCE.json').read_bytes()==adb_provenance.read_bytes(),'Packaged ADB provenance differs'
adb_inputs=[]
closure=adb_info['source_closure']
assert closure['path']=='SOURCE_CLOSURE.json' and re.fullmatch(r'[a-f0-9]{64}',closure['sha256']),'Unsafe ADB source closure'
adb_inputs.append((closure['path'],closure['sha256']))
adb_notice_paths=set()
for item in adb_info['notices']:
    path,sha=item['path'],item['sha256']
    assert re.fullmatch(r'notices/[A-Za-z0-9_.-]{1,120}',path) and path not in adb_notice_paths,'Unsafe/duplicate ADB notice'
    assert re.fullmatch(r'[a-f0-9]{64}',sha),'Invalid ADB notice hash'
    adb_notice_paths.add(path)
    source_notice=adb_root/path
    assert source_notice.is_file() and not source_notice.is_symlink() and digest(source_notice)==sha,'ADB source notice changed'
    assert (args.app/'Contents/Resources/licenses/adb-source-runtime'/Path(path).name).read_bytes()==source_notice.read_bytes(),'Packaged ADB notice differs'
assert {str(p.relative_to(adb_root)) for p in (adb_root/'notices').rglob('*') if p.is_file()}==adb_notice_paths,'ADB notice cohort differs'
assert (args.app/'Contents/Resources/licenses/adb-source-runtime'/closure['path']).read_bytes()==(adb_root/closure['path']).read_bytes(),'Packaged source closure differs'
for item in adb_info['sources']:
    adb_inputs.append((item['staged_source'],item['sha256']))
for category, repository_directory in [('patches','scripts/patches'),('recipes','scripts')]:
    for item in adb_info[category]:
        path=item['path']; adb_inputs.append((path,item['sha256']))
        committed=subprocess.check_output(['git','show',commit+':'+repository_directory+'/'+Path(path).name],cwd=root)
        assert hashlib.sha256(committed).hexdigest()==item['sha256'],'Source ADB recipe/patch differs from committed candidate'
assert len(adb_info['sources'])==4 and len(adb_inputs)<=16,'Unexpected source ADB input cohort'
for relative, sha in adb_inputs:
    path=(adb_root/relative).resolve()
    assert path.is_relative_to(adb_root) and path.is_file() and not (adb_root/relative).is_symlink(),'Unsafe ADB source input'
    assert digest(path)==sha,'Source ADB archive/recipe/patch hash changed'
args.output.parent.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='droidbridge-source-',dir=root/'.build') as temp:
    stage=Path(temp);package=stage/'DroidBridge-Corresponding-Source';package.mkdir()
    paths=[p for p in run(['git','ls-tree','--name-only',commit]).splitlines() if p not in {'verification','dist','Vendor'}]
    archive=stage/'original.tar'
    with archive.open('wb') as out:subprocess.run(['git','archive','--format=tar','--prefix=DroidBridge/',commit,*paths],cwd=root,stdout=out,check=True)
    # Git's tracked tree is trusted repository input. No network archive extraction.
    with tarfile.open(archive) as tree:tree.extractall(package,filter='data')
    shutil.copytree(args.dependencies,package/'runtime-sources')
    adb_source=package/'adb-source-runtime'; adb_source.mkdir()
    shutil.copy2(adb_provenance,adb_source/adb_provenance.name)
    shutil.copy2(adb_manifest,adb_source/adb_manifest.name)
    for relative, _ in adb_inputs:
        target=adb_source/relative
        target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(adb_root/relative,target)
    shutil.copytree(adb_root/'notices',adb_source/'notices')
    scrcpy_commit='a60891aea193d92e7e5c3942700eca63f9d19a5f'
    scrcpy=package/'scrcpy-5.0.1.tar'
    with scrcpy.open('wb') as out:subprocess.run(['git','-C',str(root/'Vendor/scrcpy'),'archive','--format=tar','--prefix=scrcpy-5.0.1/',scrcpy_commit],stdout=out,check=True)
    build_info={'droidbridge_commit':commit,'scrcpy_commit':scrcpy_commit,'scrcpy_source_sha256':digest(scrcpy),'runtime_manifest_sha256':digest(args.dependencies/'MANIFEST.json'),'adb_source_provenance_sha256':digest(adb_provenance),'adb_runtime_manifest_sha256':digest(adb_manifest),'xcode':run(['xcodebuild','-version']),'swift':run(['swift','--version']),'homebrew':run(['brew','--version'])}
    (package/'BUILD_IDENTITIES.json').write_text(json.dumps(build_info,indent=2)+'\n')
    (package/'README.txt').write_text('''DroidBridge corresponding source inputs

DroidBridge/ contains the exact committed candidate identified in BUILD_IDENTITIES.json,
including build/install scripts, original helper sources, Android sources and the
tracked audio client patch. Verification media are excluded; they are not source.

runtime-sources/ contains byte-verified upstream source archives (or exact Git
revision archive), the installed Homebrew Ruby recipes, installation/build receipts
and source hashes for the dynamically bundled runtime. Preserve upstream licenses
inside each archive. Formula recipes contain the build configuration and inreplace
patches; no external patch may be omitted by the collector.

scrcpy-5.0.1.tar is the pinned unmodified upstream source. The original video client
uses it unchanged. For the audio client apply DroidBridge/scripts/patches/
audio-output-ready.patch, then follow scripts/build-audio-client.sh. The packaging
scripts describe binary relocation and ad-hoc signing, which change Mach-O bytes.

Follow DroidBridge/BUILD.md for the host build and AndroidCompanion/README.md for
the phone build. Build runtime dependencies with the enclosed exact Ruby recipes,
not the current latest formulas; their INSTALL_RECEIPT.json records compiler and
runtime versions. For Git-derived builds, clone the enclosed *.git.bundle and checkout the exact
revision in MANIFEST.json; this preserves Git-derived version headers.
General-purpose Apple system frameworks/tools are not copied.
adb-source-runtime/ includes the exact four verified source archives for the
source-built ADB, static protobuf/Abseil and build-only Googletest headers, its
three patches, build recipes, source/runtime provenance and upstream notices.
The corresponding Android-tools archive includes vendored AOSP, BoringSSL and
fmt source. From DroidBridge/ run:
    mkdir -p .build
    scripts/build-adb-runtime.sh --work ../adb-source-runtime/sources --output .build/adb-runtime
This uses the enclosed archives with the committed recipe and patch paths;
libusb remains dynamically linked and independently replaceable. Its exact
Homebrew source and recipe are also in runtime-sources/. No Google SDK ADB
binary is substituted for this source-built release cohort.
Independent review must check this archive against the exact released artifact;
producing this file alone is not a claim of license compliance.
''')
    checks=[]
    for file in sorted(package.rglob('*')):
        if file.is_file() and not file.is_symlink():checks.append(digest(file)+'  '+str(file.relative_to(package)))
    (package/'SOURCE-SHA256SUMS').write_text('\n'.join(checks)+'\n')
    temporary=args.output.with_name(args.output.name+'.staging')
    try:
        with tarfile.open(temporary,'w:gz',compresslevel=6) as output:output.add(package,arcname=package.name)
        temporary.replace(args.output)
    finally:temporary.unlink(missing_ok=True)
print(digest(args.output)+'  '+str(args.output))
