#!/usr/bin/env python3
"""Offline independent checks of frozen phase metrics and actual driver predicate."""
import argparse,ast,hashlib,json,pathlib
p=argparse.ArgumentParser();p.add_argument('evidence',type=pathlib.Path);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--include-adjacent-raw',action='store_true',help='Require a six-block steady interval, allowing at most 12 immediately adjacent raw blocks after the phase excerpt');a=p.parse_args();repo=pathlib.Path(__file__).resolve().parents[3]
source=repo/'scripts/verify-audio-native.py';tree=ast.parse(source.read_text());method=next(n for c in tree.body if isinstance(c,ast.ClassDef) and c.name=='NativeAudioTest' for n in c.body if isinstance(n,ast.FunctionDef) and n.name=='sample_phase');match=next(n for n in method.body if isinstance(n,ast.FunctionDef) and n.name=='matches');code=compile(ast.fix_missing_locations(ast.Module(body=[match],type_ignores=[])),str(source),'exec')
r=json.loads((a.evidence/'result.json').read_text());assert r['passed'] and r['acceptance'];checks=[]
for f in sorted(a.evidence.glob('*-metrics.json')):
 data=json.loads(f.read_text());s=data['summary'];samples=data['samples'];scope=dict(wanted=s['wanted_hz'],absent=s['absent_hz'],silence=s['silence'],thresholds={int(k):v for k,v in s['tone_presence_thresholds'].items()},silence_rms_limit=s['silence_rms_limit']);exec(code,scope);matches=[scope['matches'](row) for row in samples]
 assert samples and all(row['pid']==s['audio_pid'] and row['dropped_frames']==0 for row in samples)
 assert sum(matches)==s['matching'] and sum(matches)>=6,(f,sum(matches),s['matching'])
 final_six=all(matches[-6:]);adjacent=[]
 if not final_six and a.include_adjacent_raw:
  raw=[json.loads(line) for line in (a.evidence/'samples.jsonl').read_text().splitlines() if line.strip()]
  last=samples[-1];position=next(i for i,row in enumerate(raw) if row==last)
  for row in raw[position+1:position+13]:
   if row['pid']!=s['audio_pid'] or row['accepted_frames']!=(last['accepted_frames']+4800) or row['dropped_frames']!=0:break
   adjacent.append(row);last=row
  combined=matches+[scope['matches'](row) for row in adjacent]
  assert any(all(combined[i:i+6]) for i in range(len(combined)-5)),(f,'No six-block steady interval in bounded adjacent raw samples')
 else:assert final_six,(f,'No final six-block steady state')
 checks.append(dict(phase=s['phase'],audio_pid=s['audio_pid'],samples=len(samples),matching=sum(matches),final_six_consecutive_match=final_six,adjacent_raw_blocks=adjacent,ratio_bound=s['maximum_absent_to_wanted_ratio']))
assert checks
inputs=r.get('instrument_hashes',{})
if str(source) in inputs:assert inputs[str(source)]==hashlib.sha256(source.read_bytes()).hexdigest()
report=dict(passed=True,scope='Raw aggregate metrics, PID and phase controls only; no physical speaker proof',evidence=str(a.evidence),installed_sha256=r['installed_sha256'],driver_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),checks=checks)
a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
