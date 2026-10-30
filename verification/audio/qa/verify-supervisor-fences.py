#!/usr/bin/env python3
"""Real supervisor, bounded fake adb: exact cleanup and under-lock failure fence."""
import argparse,json,os,pathlib,signal,subprocess,tempfile,time
p=argparse.ArgumentParser();p.add_argument('--supervisor',type=pathlib.Path,default=pathlib.Path('.build/debug/DroidBridgeSupervisor'));p.add_argument('--output',type=pathlib.Path,default=pathlib.Path('verification/audio/qa/supervisor-fences.json'));args=p.parse_args();supervisor=args.supervisor.resolve();args.output.parent.mkdir(parents=True,exist_ok=True)
results=[]
with tempfile.TemporaryDirectory(prefix='qa-audio-fences-') as tmp:
 d=pathlib.Path(tmp);rows=d/'rows';calls=d/'calls';adb=d/'adb'
 adb.write_text('#!/usr/bin/python3\nimport pathlib,sys,json\nwith open('+repr(str(calls))+',"a") as f:f.write(json.dumps(sys.argv[1:])+"\\n")\nif sys.argv[-2:]==["forward","--list"]:print(pathlib.Path('+repr(str(rows))+').read_text(),end="")\n');adb.chmod(0o755)
 endpoint='tcp:46062';remote='localabstract:scrcpy_1abbccdd'
 for name,listing,removed in [('exact','qa-owned '+endpoint+' '+remote+'\n',True),('absent','',False),('foreign-remote','qa-owned '+endpoint+' localabstract:foreign\n',False),('foreign-serial','someone-else '+endpoint+' '+remote+'\n',False)]:
  rows.write_text(listing);calls.unlink(missing_ok=True)
  command=[str(supervisor),'--parent',str(os.getpid()),'--adb',str(adb),'--serial','qa-owned','--forward',endpoint,'--forward-remote',remote,'--','/usr/bin/true']
  result=subprocess.run(command,capture_output=True,text=True,timeout=7)
  assert result.returncode==0,(name,result.stderr)
  actions=[json.loads(line) for line in calls.read_text().splitlines()]
  removals=[a for a in actions if '--remove' in a]
  assert bool(removals)==removed,(name,actions,result.stderr)
  if removed:assert removals==[['-s','qa-owned','forward','--remove',endpoint]],removals
  if name=='foreign-remote':assert 'identity_changed' in result.stderr,result.stderr
  results.append({'case':name,'passed':True,'removed':removed,'commands':actions,'diagnostics':result.stderr})
 lock=d/'owner.lock';failure=d/'failed.json';launch=d/'launched';tag='a'*64
 failure.write_text(json.dumps({'tag':tag},separators=(',',':')));failure.chmod(0o600)
 command=[str(supervisor),'--parent',str(os.getpid()),'--owner-lock',str(lock),'--failure-file',str(failure),'--failure-tag',tag,'--','/usr/bin/touch',str(launch)]
 result=subprocess.run(command,capture_output=True,text=True,timeout=3)
 assert result.returncode==77 and 'supervisor_failure_latched' in result.stderr,result.stderr
 assert not launch.exists(),'Failed generation admitted a successor client'
 results.append({'case':'failure-fence-inside-owner-lock','passed':True,'exit':result.returncode,'client_not_started':True,'diagnostics':result.stderr})
 # An explicit different retry identity must remain admissible.
 command[command.index('--failure-tag')+1]='b'*64
 result=subprocess.run(command,capture_output=True,text=True,timeout=3)
 assert result.returncode==0 and launch.exists(),result.stderr
 results.append({'case':'new-retry-identity-admitted','passed':True,'exit':result.returncode})
 # Timeout publication is requested from the supervisor, not a late GUI writer.
 failure.unlink();launch.unlink();timeout_log=d/'timeout.log'
 with timeout_log.open('w') as log:
  process=subprocess.Popen([str(supervisor),'--parent',str(os.getpid()),'--owner-lock',str(lock),'--failure-file',str(failure),'--failure-tag',tag,'--','/bin/sleep','30'],stdout=log,stderr=log)
  try:
   deadline=time.monotonic()+3
   while 'supervisor_started' not in timeout_log.read_text() and time.monotonic()<deadline:time.sleep(.02)
   assert 'supervisor_started' in timeout_log.read_text()
   process.send_signal(signal.SIGUSR1);process.wait(timeout=5)
  finally:
   if process.poll() is None:process.terminate();process.wait(timeout=5)
 assert json.loads(failure.read_text())['tag']==tag
 command[command.index('--failure-tag')+1]=tag
 result=subprocess.run(command,capture_output=True,text=True,timeout=3)
 assert result.returncode==77 and not launch.exists(),result.stderr
 results.append({'case':'supervisor-timeout-latches-before-successor-admission','passed':True,'successor_exit':result.returncode,'diagnostics':timeout_log.read_text()})
report={'passed':True,'scope':'real supervisor/fake bounded adb; no Android or audio output acceptance','cases':results};args.output.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
