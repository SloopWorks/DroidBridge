#!/usr/bin/env python3
"""Offline fixture: never launches bundled code, installed apps, UI, or ADB."""
from pathlib import Path
import hashlib,json,shutil,subprocess,zipfile,sys
repo=Path(__file__).resolve().parents[3]; repo=repo.parent if not (repo/'scripts').exists() else repo
source=Path('/Users/patrick/Applications/DroidBridge Companion QA11.app')
stage=repo/'.build/player-signing-proof'; evidence=Path(__file__).resolve().parent
fixed=stage/'Runtime/Player.app'; verifier=repo/'scripts/verify-package.py'
results={}
def check_case(name, mutate, expected):
    case=stage/name/'Player.app'; case.parent.mkdir(exist_ok=True); shutil.rmtree(case,ignore_errors=True); shutil.copytree(fixed,case,symlinks=True)
    mutate(case)
    if name!='escaping-link': subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(case)],check=True,capture_output=True)
    result=subprocess.run([sys.executable,str(verifier),str(case),'--player-only','--output',str(stage/name/'unexpected.json')],capture_output=True,text=True)
    log=result.stdout+result.stderr; (evidence/(name+'.log')).write_text(log)
    assert result.returncode!=0 and expected in log,(name,log)
    results[name]={'rejected':True,'reason':expected}
def escaping(case):
    shutil.rmtree(case/'Contents/lib'); (case/'Contents/lib').symlink_to('../../lib')
check_case('escaping-link',escaping,'must be a real internal directory')
check_case('missing-library',lambda p:(p/'Contents/lib/libavformat.63.dylib').unlink(),'missing dependency')
def tamper(case):
    path=case/'Contents/lib/libavformat.63.dylib'; path.chmod(0o755)
    with path.open('r+b') as stream:
        stream.seek(4096); byte=stream.read(1); stream.seek(4096);stream.write(bytes([byte[0]^1]))
check_case('tampered-library',tamper,'codesign')
def load_path(case,old,new):
    exe=case/'Contents/MacOS/scrcpy'; exe.chmod(0o755)
    subprocess.run(['/usr/bin/install_name_tool','-change',old,new,str(exe)],check=True,capture_output=True)
check_case('external-rpath',lambda p:load_path(p,'@loader_path/../lib/libavformat.63.dylib','@rpath/libavformat.63.dylib'),'external or unsupported rpath')
check_case('escaping-executable-path',lambda p:load_path(p,'@loader_path/../lib/libavformat.63.dylib','@executable_path/../../../lib/libavformat.63.dylib'),'dependency escapes bundle')
def mixed_rpath(case):
    load_path(case,'@loader_path/../lib/libavformat.63.dylib','@rpath/libavformat.63.dylib')
    exe=case/'Contents/MacOS/scrcpy'
    subprocess.run(['/usr/bin/install_name_tool','-rpath','/opt/homebrew/lib','/tmp/droidbridge-foreign','-add_rpath','@loader_path/../lib',str(exe)],check=True,capture_output=True)
check_case('external-first-local-later-rpath',mixed_rpath,'external or unsupported rpath')
check_case('system-prefix-traversal',lambda p:load_path(p,'@loader_path/../lib/libavformat.63.dylib','/usr/lib/../../tmp/evil.dylib'),'noncanonical system dependency')
# Focused admission regression: sparse oversized library, instrument digest to
# prove refusal occurs before any hash/copy. No 256MiB allocation is performed.
import importlib.util
spec=importlib.util.spec_from_file_location('package_validator',verifier)
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
cap=stage/'oversized'; shutil.rmtree(cap,ignore_errors=True)
runtime=cap/'Runtime'; (runtime/'bin').mkdir(parents=True); (runtime/'lib').mkdir()
player=runtime/'Player.app'; (player/'Contents/MacOS').mkdir(parents=True); (player/'Contents/Resources').mkdir()
shutil.copy2(stage/'Runtime/bin/scrcpy',runtime/'bin/scrcpy');shutil.copy2(runtime/'bin/scrcpy',player/'Contents/MacOS/scrcpy')
huge=runtime/'lib/libavformat.63.dylib'
shutil.copy2(fixed/'Contents/lib/libavformat.63.dylib',huge);huge.chmod(0o755)
with huge.open('r+b') as stream:stream.truncate(module.MAX_PLAYER_LIBRARY_BYTES+1)
hash_calls=[]
def refuse_hash(path):
    hash_calls.append(str(path)); raise RuntimeError('hash invoked before admission')
module.sha256_file=refuse_hash
try:module.stage_player_libraries(runtime,player)
except AssertionError as error:assert 'exceeds bounds' in str(error)
else:raise AssertionError('oversized stage accepted')
assert not hash_calls and not list((player/'Contents/lib').iterdir())
results['oversized-staging-preflight']={'rejected':True,'hash_calls':0,'copies':0,'sparse_library_bytes':huge.stat().st_size}
# Isolate inventory admission from signature checks: strict signatures are tested
# above; this instrumented unit case proves its byte guard precedes hashing.
shutil.copy2(fixed/'Contents/Info.plist',player/'Contents/Info.plist')
shutil.move(huge,player/'Contents/lib/libavformat.63.dylib')
(player/'Contents/Resources/dylib-inventory.json').write_text(json.dumps({'schema':1,'files':[{'name':'libavformat.63.dylib','size':module.MAX_PLAYER_LIBRARY_BYTES+1,'source':'lib/libavformat.63.dylib','sha256':'0'*64}],'logical_bytes':module.MAX_PLAYER_LIBRARY_BYTES+1}))
module.run=lambda *args:''
module.verify_machos=lambda *args:{}
try:module.verify_player_bundle(player)
except AssertionError as error:assert 'inventory exceeds bounds' in str(error)
else:raise AssertionError('oversized inventory accepted')
assert not hash_calls
results['oversized-inventory-preflight']={'rejected':True,'hash_calls':0,'isolated_unit_case':True}
app=stage/'DroidBridge.app'; shutil.rmtree(app,ignore_errors=True); shutil.copytree(source,app,symlinks=True)
target=app/'Contents/Resources/Runtime/Player.app'; shutil.rmtree(target); shutil.copytree(fixed,target)
subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
subprocess.run([sys.executable,str(verifier),str(app),'--signatures-only','--output',str(evidence/'all-macho-fixed.json')],check=True)
full=json.loads((evidence/'all-macho-fixed.json').read_text()); assert len(full['dependencies'])==48
results['full-app']={'independent_macho_strict_checks':len(full['dependencies']),'nested_player_strict':True}
inventory=json.loads((fixed/'Contents/Resources/dylib-inventory.json').read_text())
for entry in inventory['files']:
    assert hashlib.sha256((source/'Contents/Resources/Runtime'/entry['source']).read_bytes()).hexdigest()==entry['sha256']
results['copied-byte-identity']={'count':len(inventory['files']),'all_source_hashes_equal':True,'logical_bytes':inventory['logical_bytes']}
# Comparable zip fixtures contain the same Runtime/lib plus old/new Player. Store
# symlink text, never dereference the old escaping symlink or launch any code.
def archive_player(label,player):
    archive=stage/(label+'.zip')
    with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as output:
        for tree,prefix in ((source/'Contents/Resources/Runtime/lib','Runtime/lib'),(player,'Runtime/Player.app')):
            for path in sorted(tree.rglob('*')):
                name=str(Path(prefix)/path.relative_to(tree))
                if path.is_symlink():
                    import os
                    info=zipfile.ZipInfo(name);info.create_system=3;info.external_attr=0o120777<<16
                    output.writestr(info,os.readlink(path))
                elif path.is_file():output.write(path,name)
    return archive.stat().st_size
old_size=archive_player('old-layout',source/'Contents/Resources/Runtime/Player.app'); new_size=archive_player('fixed-layout',fixed)
results['payload']={'fixture_zip_deflate9_old_bytes':old_size,'fixture_zip_deflate9_fixed_bytes':new_size,'fixture_zip_delta_bytes':new_size-old_size,'additional_dylib_logical_bytes':inventory['logical_bytes'],'final_dmg_zip_measurement':'pending root build12'}
results['scripts_sha256']={str(p.relative_to(repo)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (repo/'scripts/package.sh',verifier)}
(evidence/'regression-results.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
