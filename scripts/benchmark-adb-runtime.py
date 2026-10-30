#!/usr/bin/env python3
"""Measure offline version startup; never enumerate/connect/start an ADB server."""
import argparse
import importlib.util
import json
import math
import os
from pathlib import Path
import statistics
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', action='append', required=True, help='label=/absolute/path/to/adb')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
spec = importlib.util.spec_from_file_location('adb_builder', Path(__file__).with_name('build-adb-runtime.py'))
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)
results = {}
for value in args.binary:
    name, path = value.split('=', 1)
    path = Path(path).resolve()
    samples = []
    for _ in range(20):
        started = time.perf_counter()
        completed = subprocess.run([str(path), 'version'], env={'PATH': '/usr/bin:/bin', 'HOME': str(Path.home()), 'LC_ALL': 'C'}, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=5)
        samples.append((time.perf_counter() - started) * 1000)
    dependencies = {}
    pending = [path]
    visited = {path}
    while pending:
        current = pending.pop()
        for dependency in builder.dependencies(current):
            if dependency.startswith(('/usr/lib/', '/System/Library/')):
                continue
            original = builder.resolve_dependency(dependency, current)
            if original in visited:
                continue
            visited.add(original)
            dependencies[str(original)] = original.stat().st_size
            pending.append(original)
    warm = samples[1:]
    results[name] = {'binary': str(path), 'binary_bytes': path.stat().st_size, 'first_ms': samples[0], 'warm_n': len(warm),
        'warm_median_ms': statistics.median(warm), 'warm_p95_ms': sorted(warm)[math.ceil(.95 * len(warm)) - 1], 'samples_ms': samples,
        'dependency_count': len(dependencies), 'dependency_bytes': sum(dependencies.values()), 'dependencies': dependencies,
        'version': completed.stdout, 'environment': 'PATH=/usr/bin:/bin, no DYLD overrides; no server commands; first invocation plus 19 subsequent processes; OS caches intentionally not flushed'}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(results, indent=2) + '\n')
for name, result in results.items():
    print(name, {key: result[key] for key in ('binary_bytes', 'first_ms', 'warm_median_ms', 'warm_p95_ms', 'dependency_count', 'dependency_bytes')})
