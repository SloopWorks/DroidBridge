#!/usr/bin/env python3
"""Offline synthetic PCM controls; not device/audio acceptance.

Use direct complex Fourier sums, independently of the observer's Goertzel
recurrence. Apply the actual driver's matching predicate extracted from its
trusted source, so the calibration cannot silently use a different threshold.
"""
import ast,cmath,hashlib,json,math,pathlib
repo=pathlib.Path(__file__).resolve().parents[3]
source=repo/'scripts/verify-audio-native.py';tree=ast.parse(source.read_text())
method=next(n for c in tree.body if isinstance(c,ast.ClassDef) and c.name=='NativeAudioTest' for n in c.body if isinstance(n,ast.FunctionDef) and n.name=='sample_phase')
matcher=next(n for n in method.body if isinstance(n,ast.FunctionDef) and n.name=='matches')
module=ast.fix_missing_locations(ast.Module(body=[matcher],type_ignores=[]))
N=4800;rate=48000
kernels={hz:[cmath.exp(-2j*math.pi*hz*i/rate) for i in range(N)] for hz in (997,1499)}
def row(parts,gain=1):
 data=[sum(int(2048*math.sin(2*math.pi*hz*i/rate+phase))/32768 for hz,phase in parts)*gain for i in range(N)]
 return dict(rms=math.sqrt(sum(x*x for x in data)/N),**{'tone'+str(hz):2*abs(sum(x*k for x,k in zip(data,kernel)))/N for hz,kernel in kernels.items()})
def accepts(sample,wanted=(997,),absent=(1499,),silence=False):
 scope=dict(wanted=wanted,absent=absent,silence=silence,thresholds={997:.00002,1499:.00002},silence_rms_limit=.00002)
 exec(compile(module,str(source),'exec'),scope)
 return scope['matches'](sample)
results=[];max_leak=0
for phase in [0,.3,1.2,2.7,4.9]:
 for gain in [1,.02365]:
  a=row([(997,phase)],gain);b=row([(1499,phase)],gain);mixed=row([(997,phase),(1499,phase+.7)],gain)
  leak=a['tone1499']/a['tone997'];max_leak=max(max_leak,leak)
  checks={'valid997':accepts(a),'wrong1499_rejected':not accepts(b),'mixed_rejected_when1499_absent':not accepts(mixed),'valid1499':accepts(b,wanted=(1499,),absent=(997,)),'both_desired':accepts(mixed,wanted=(997,1499),absent=())}
  assert all(checks.values()),(phase,gain,checks,a,b,mixed)
  results.append(dict(phase=phase,gain=gain,checks=checks,tone997=a,wrong1499=b,mixed=mixed,unwanted_to_wanted_ratio=leak))
zero=row([]);assert not accepts(zero) and accepts(zero,wanted=(),absent=(),silence=True)
report=dict(passed=True,scope='offline synthetic PCM and real test predicate; no audio device proof',driver_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),normalization='2*abs(direct complex DFT)/4800; same quantized fixture frequencies',maximum_observed_rectangular_leak_ratio=max_leak,accepted_leak_ratio_bound=.02,limitations='2% bounds measurement cross-bin leakage; it is not mathematical zero unwanted energy',cases=results,silence_rejected_as_tone=True,silence_accepted_as_silence=True)
pathlib.Path(__file__).with_suffix('.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:v for k,v in report.items() if k!='cases'},indent=2))
