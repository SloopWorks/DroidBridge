#!/usr/bin/env python3
"""Real supervisor/fake tools only: crash independent ownership through cleanup."""
import argparse,fcntl,json,os,pathlib,signal,subprocess,tempfile,time
p=argparse.ArgumentParser();p.add_argument('--supervisor',type=pathlib.Path,default=pathlib.Path('.build/debug/DroidBridgeSupervisor'));p.add_argument('--output',type=pathlib.Path,default=pathlib.Path('verification/audio/qa/supervisor-lease.json'));args=p.parse_args()
supervisor=args.supervisor.resolve();args.output.parent.mkdir(parents=True,exist_ok=True)
def wait(label,fn,seconds=6):
 end=time.monotonic()+seconds
 while time.monotonic()<end:
  value=fn()
  if value:return value
  time.sleep(.02)
 raise AssertionError('Timeout '+label)
with tempfile.TemporaryDirectory(prefix='droidbridge-qa-audio-lease-') as tmp:
 d=pathlib.Path(tmp);lock=d/'owner.lock';log=d/'supervisor.log';started=d/'started';cleanup=d/'cleanup';release=d/'release';pids=d/'pids.json';unexpected=d/'unexpected'
 fake=d/'adb';fake.write_text('#!/usr/bin/python3\nimport pathlib,time\np=pathlib.Path('+repr(str(cleanup))+');p.write_text("cleanup entered")\nend=time.monotonic()+4\nwhile not pathlib.Path('+repr(str(release))+').exists() and time.monotonic()<end:time.sleep(.02)\n');fake.chmod(0o755)
 child=d/'audio';child.write_text('#!/bin/sh\necho $$ > '+str(started)+'\nexec /bin/sleep 30\n');child.chmod(0o755)
 parent=d/'parent.py'
 # An exact direct-parent PID is required by the shipping supervisor.
 parent.write_text('import subprocess,os,json,pathlib,time\nlog=open('+repr(str(log))+',"w")\nargv='+repr([str(supervisor),'--owner-lock',str(lock),'--adb',str(fake),'--serial','qa-owned','--remote','/data/local/tmp/qa-owned-audio','--',str(child)])+'\nargv[1:1]=["--parent",str(os.getpid())]\np=subprocess.Popen(argv,stdout=log,stderr=log)\npathlib.Path('+repr(str(pids))+').write_text(json.dumps({"supervisor":p.pid,"parent":os.getpid()}))\nwhile True:time.sleep(1)\n')
 proc=subprocess.Popen(['/usr/bin/python3',str(parent)]);fd=None;report={'passed':False,'scope':'real supervisor, fake bounded adb/client, no emulator or audio output'}
 try:
  wait('child started',started.exists);ids=json.loads(pids.read_text());client_pid=int(started.read_text())
  fd=os.open(lock,os.O_RDWR)
  def busy():
   try:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);fcntl.flock(fd,fcntl.LOCK_UN);return False
   except BlockingIOError:return True
  assert busy(),'Audio lease missing while client runs'
  os.kill(proc.pid,signal.SIGKILL);proc.wait(timeout=3)
  wait('post-crash cleanup entered',cleanup.exists)
  assert busy(),'GUI death released audio lease before supervisor cleanup'
  second=subprocess.run([str(supervisor),'--parent',str(os.getpid()),'--owner-lock',str(lock),'--','/usr/bin/touch',str(unexpected)],capture_output=True,text=True,timeout=3)
  assert second.returncode==76 and 'supervisor_owner_busy' in second.stderr,second
  assert not unexpected.exists(),'Successor audio process started during old owner cleanup'
  release.write_text('allow exact cleanup to finish')
  wait('lease released after cleanup',lambda:not busy())
  text=log.read_text();assert '"reason":"parent_exit"' in text,text
  try:os.kill(client_pid,0)
  except ProcessLookupError:pass
  else:raise AssertionError('Owned audio child remained after cleanup')
  report.update(passed=True,lease_held_during_client=True,lease_held_after_gui_sigkill=True,successor_refused_during_cleanup=True,lease_released_after_cleanup=True,child_reaped=True,supervisor_diagnostics=text)
 finally:
  release.touch()
  if proc.poll() is None:proc.kill();proc.wait(timeout=3)
  if fd is not None:os.close(fd)
 args.output.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
