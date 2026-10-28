#!/usr/bin/env python3
"""Installed per-user helper test. Requires exclusive preferences/LaunchAgent window.
Runs no Android app; optional emulator restart is intentionally separate.
"""
import json, os, re, signal, subprocess, time
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
OUTPUT=ROOT/'verification/onboarding/final-agent.json'
STATUS=ROOT/'.build/verify-managed-availability'
SERVICE=f'gui/{os.getuid()}/app.droidbridge.availability'
PREFERENCES=Path.home()/'Library/Application Support/DroidBridge/preferences.json'
LOG=Path.home()/'Library/Application Support/DroidBridge/ManagedApps.noindex/availability/availability.jsonl'

def call(*args):return subprocess.check_output(args,text=True,stderr=subprocess.STDOUT)
class TransientBusy(Exception):pass

def snapshot():
    try:text=call(str(STATUS),'status')
    except subprocess.CalledProcessError as error:
        if error.returncode==2 and 'BUSY:' in error.output:raise TransientBusy() from error
        raise
    match=re.search(r'accepted=(\d+) active=(\d+) hidden=(\d+)',text)
    assert match,text
    return dict(zip(('accepted','active','hidden'),map(int,match.groups())))
def wait_for(predicate,limit=90):
    start=time.monotonic()
    while time.monotonic()-start<limit:
        try:value=predicate()
        except TransientBusy:value=None
        if value:return value,round(time.monotonic()-start,3)
        time.sleep(.2)
    raise AssertionError('Timed out waiting for finite helper transition')
def pid():
    try:
        match=re.search(r'\n\s*pid = (\d+)',call('/bin/launchctl','print',SERVICE))
        return int(match.group(1)) if match else None
    except subprocess.CalledProcessError:return None

def main():
    before=json.loads(PREFERENCES.read_text()) if PREFERENCES.exists() else {}
    original=before.get('bulkWrapperOnboardingEnabled',True)
    result={}
    try:
        initial,_=wait_for(snapshot);assert initial['accepted']>0 and initial['active']==initial['accepted'],initial
        count=initial['accepted'];old_pid=pid();assert old_pid
        result['initial']=initial;result['initialPID']=old_pid
        call(str(STATUS),'off')
        state,seconds=wait_for(lambda:(s if (s:=snapshot())['hidden']==count and s['active']==0 else None))
        result['featureOff']={'state':state,'seconds':seconds}
        last=json.loads(LOG.read_text().splitlines()[-1]);assert last['enabled'] is False and last['probed']==0,last
        result['featureOffCycle']=last
        # SIGTERM must finish its current finite operation and exit. launchd
        # restarts the exact installed job without depending on a GUI lifetime.
        os.kill(old_pid,signal.SIGTERM)
        _,seconds=wait_for(lambda:(subprocess.run(['/bin/kill','-0',str(old_pid)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode!=0),10)
        result['terminationSeconds']=seconds
        new_pid,seconds=wait_for(lambda:(p if (p:=pid()) and p!=old_pid else None),90)
        result['restartedPID']=new_pid;result['restartSeconds']=seconds
        call(str(STATUS),'on')
        state,seconds=wait_for(lambda:(s if (s:=snapshot())['active']==count and s['hidden']==0 else None))
        result['featureOn']={'state':state,'seconds':seconds}
        result['parentPID']=int(call('/bin/ps','-p',str(new_pid),'-o','ppid=').strip());assert result['parentPID']==1
        result['status']='PASS'
    finally:
        call(str(STATUS),'on' if original else 'off')
        OUTPUT.parent.mkdir(parents=True,exist_ok=True);OUTPUT.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))
if __name__=='__main__':main()
