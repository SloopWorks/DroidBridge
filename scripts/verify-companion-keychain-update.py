#!/usr/bin/env python3
"""Actual differently signed/path Core helpers; one random QA Keychain item only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--disable-keychain-ui', action='store_true', help='Experiment only: require process-local legacy file-Keychain noninteractive policy')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=False)
    scratch = Path(tempfile.mkdtemp(prefix='droidbridge-keychain-update-', dir=repo / '.build'))
    scope = scratch / 'qa'; scope.mkdir(mode=0o700)
    subprocess.run(['swift','build','--target','DroidBridgeCore'],cwd=repo,check=True)
    binary_dir = Path(subprocess.check_output(['swift','build','--show-bin-path'],cwd=repo,text=True).strip())
    objects = sorted((binary_dir / 'DroidBridgeCore.build').glob('*.swift.o')); assert objects
    source = repo / 'scripts/verify-companion-keychain-update.swift'
    snapshots = {str(p.relative_to(repo)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((repo/'Sources/DroidBridgeCore').glob('*.swift'))}
    helpers = {}
    report = {'scope':'Different-code-hash and different-path ad-hoc-signed Core-linked helpers using one random isolated QA service/account; not yet installed broker update evidence','unrelated_keychain_record_access':False,'legacy_process_ui_policy_disabled':args.disable_keychain_ui,'source_sha256':snapshots,'source_driver_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'helpers':{},'actions':[]}
    for generation in ['A','B']:
        target = scratch / ('generation-' + generation) / 'DroidBridgeCompanionBroker'; target.parent.mkdir()
        command = ['swiftc','-parse-as-library','-I',str(binary_dir/'Modules'),str(source),*map(str,objects),'-o',str(target)]
        if generation == 'B': command[1:1] = ['-D','GENERATION_B']
        if args.disable_keychain_ui: command[1:1] = ['-D','NO_KEYCHAIN_UI']
        subprocess.run(command,cwd=repo,check=True)
        subprocess.run(['/usr/bin/codesign','--force','--sign','-','--identifier','dev.droidbridge.companion.broker',str(target)],capture_output=True,check=True)
        subprocess.run(['/usr/bin/codesign','--verify','--strict',str(target)],capture_output=True,check=True)
        display = subprocess.run(['/usr/bin/codesign','-d','--verbose=4',str(target)],capture_output=True,text=True,check=True).stderr
        cdhash = next(line.removeprefix('CDHash=') for line in display.splitlines() if line.startswith('CDHash='))
        report['helpers'][generation]={'sha256':hashlib.sha256(target.read_bytes()).hexdigest(),'cdhash':cdhash,'relative_path':str(target.relative_to(scratch)),'signing':'ad_hoc_strict_verified'}
        helpers[generation]=target
    assert report['helpers']['A']['cdhash'] != report['helpers']['B']['cdhash']
    record = dict(version=1,deviceID=str(uuid.uuid4()),trustID=str(uuid.uuid4()),credential=secrets.token_urlsafe(32),serverPin=secrets.token_hex(32))
    def action(generation,mode,current=record):
        try:
            result = subprocess.run([str(helpers[generation]),'--companion-qa-root',str(scope),'--serial','emulator-5580'],input=json.dumps({'mode':mode,'record':current}).encode(),capture_output=True,timeout=10,check=True)
            value=json.loads(result.stdout)
        except subprocess.TimeoutExpired:
            value={'status':'timeout','code':'credential_operation_timeout','timeout_seconds':10}
        assert not any(k in value for k in ['credential','serverPin','record'])
        report['actions'].append(dict(helper=generation,mode=mode,result=value))
        return value
    try:
        assert action('A','save')['status']=='ok'
        assert action('A','load')['status']=='ok'
        other=action('B','load')
        if other['status']=='ok':
            updated={**record,'credential':secrets.token_urlsafe(32)}
            assert action('B','save',updated)['status']=='ok'
            assert action('B','load',updated)['status']=='ok'
            same=action('A','load',updated)
            report['observed_cross_generation_read']='allowed_without_interaction'
            report['old_generation_can_read_updated_record']=same['status']=='ok'
        else:
            assert other.get('code')=='credential_unavailable',other
            report['observed_cross_generation_read']='refused_without_interaction_requires_explicit_repair'
            forgotten=action('B','delete')
            report['new_generation_explicit_forget_succeeded']=forgotten['status']=='ok' and forgotten.get('keychain_status_after')=='-25300'
            assert report['new_generation_explicit_forget_succeeded'],forgotten
            replacement={**record,'credential':secrets.token_urlsafe(32)}
            assert action('B','save',replacement)['status']=='ok'
            assert action('B','load',replacement)['status']=='ok'
            report['new_generation_fresh_credential_save_read_succeeded']=True
        report['acceptance']=True
    finally:
        cleanup=action('A','delete')
        if cleanup['status']!='ok': cleanup=action('B','delete')
        report['exact_random_item_cleanup']=cleanup['status']=='ok' and cleanup.get('keychain_status_after')=='-25300'
        assert report['exact_random_item_cleanup'],cleanup
        report['source_unchanged']=snapshots=={name:hashlib.sha256((repo/name).read_bytes()).hexdigest() for name in snapshots}
        (output/'result.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:report[k] for k in ['acceptance','observed_cross_generation_read','exact_random_item_cleanup','source_unchanged']}))

if __name__=='__main__':main()
