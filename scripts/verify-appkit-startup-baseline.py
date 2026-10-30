#!/usr/bin/env python3
"""Compile, or explicitly run, isolated public-AppKit startup lower bounds.

No ADB, companion broker, DroidBridge module or product preference is used.
Compilation is the default. --run opens transient windows and requires the
engineering team's separate quiet GUI handoff. This harness does not grant it.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import stat
import subprocess
import time


def owned_directory(path):
    path = path.absolute()
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o700 or path.resolve(strict=True) != path):
        raise ValueError('The explicit QA root must be a canonical user-owned mode-700 directory')
    return path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command):
    result = subprocess.run([str(x) for x in command], capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise RuntimeError(f'Baseline build/check failed ({result.returncode}): {result.stderr[-4096:]}')
    return result


def quantiles(values):
    values = sorted(values)
    return {'n': len(values), 'p50': values[math.ceil(len(values) * .5) - 1],
            'p95': values[math.ceil(len(values) * .95) - 1], 'minimum': values[0], 'maximum': values[-1]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--qa-root', type=Path, required=True)
    parser.add_argument('--output-name', required=True)
    parser.add_argument('--run', action='store_true', help='Open baseline windows only after the team hands over the quiet GUI window')
    parser.add_argument('--samples', type=int, default=20)
    parser.add_argument('--host-context', default='unspecified; no claim of quiet host')
    args = parser.parse_args()
    if not 5 <= args.samples <= 40:
        raise ValueError('Use 5...40 bounded samples per executable')
    if not args.output_name or len(args.output_name) > 100 or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for c in args.output_name):
        raise ValueError('Output name must be a short simple directory name')
    root = owned_directory(args.qa_root)
    output = root / args.output_name
    output.mkdir(mode=0o700, exist_ok=False)
    repo = Path(__file__).resolve().parents[1]
    source_names = ['verify-appkit-startup-baseline.m', 'verify-appkit-startup-baseline.swift', 'verify-appkit-startup-baseline.py', 'verify-companion-window-observer.m']
    observer = output / 'preview-observer.dylib'
    run(['xcrun', 'clang', '-dynamiclib', '-O2', '-fobjc-arc', '-framework', 'AppKit', repo/'scripts/verify-companion-window-observer.m', '-o', observer])
    variants = {}
    scope = hashlib.sha256(str(root).encode()).hexdigest()[:16]
    for kind, extension in [('objc', 'm'), ('swift', 'swift')]:
        app = output / f'AppKitBaseline-{kind}.app'
        executable = app / 'Contents/MacOS/AppKitBaseline'
        executable.parent.mkdir(parents=True, mode=0o700)
        info = {'CFBundleIdentifier': f'dev.sloopworks.DroidBridge.StartupBaseline.{scope}.{kind}',
                'CFBundleExecutable': executable.name, 'CFBundleName': f'AppKit Baseline {kind}',
                'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'NSHighResolutionCapable': True,
                'LSMinimumSystemVersion': '26.0', 'NSPrincipalClass': 'NSApplication'}
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        source = repo / f'scripts/verify-appkit-startup-baseline.{extension}'
        if kind == 'objc':
            command = ['xcrun', 'clang', '-O2', '-fobjc-arc', '-target', 'arm64-apple-macos26.0', '-framework', 'AppKit', source, '-o', executable]
        else:
            command = ['xcrun', 'swiftc', '-O', '-whole-module-optimization', '-target', 'arm64-apple-macos26.0', '-framework', 'AppKit', source, '-o', executable]
        run(command)
        run(['codesign', '--force', '--sign', '-', app])
        run(['codesign', '--verify', '--strict', app])
        variants[kind] = {'app': str(app), 'executable': str(executable), 'sha256': digest(executable),
                          'bytes': executable.stat().st_size,
                          'dependencies': run(['otool', '-arch', 'arm64', '-L', executable]).stdout.splitlines(),
                          'compile_arguments': [str(x) for x in command]}
    result = {'execution_passed': None, 'measurement_performed': args.run,
              'cold_preview_target_ms': 100, 'cold_preview_target_passed': None,
              'host_context': args.host_context, 'platform': platform.platform(),
              'macos': run(['sw_vers']).stdout, 'architecture': platform.machine(),
              'hardware_model_cpu_memory': run(['sysctl', '-n', 'hw.model', 'hw.physicalcpu', 'hw.memsize']).stdout.splitlines(),
              'compiler': run(['xcrun', 'swiftc', '--version']).stdout,
              'scope': 'Standalone lower bounds, no DroidBridge, ADB, companion broker, product preferences, Android session, or video',
              'sampling': 'Fresh process each sample, OS and filesystem caches uncontrolled; public NSWindow visibility polled every10ms by the identical passive product observer; includes spawn/dyld, not WindowServer paint or input readiness',
              'sources': {name: digest(repo/'scripts'/name) for name in source_names},
              'variants': variants, 'rows': []}
    result_path = output / 'results.json'
    result_path.write_text(json.dumps(result, indent=2) + '\n')
    if not args.run:
        print(json.dumps({'compiled': True, 'measurement_performed': False, 'results': str(result_path)}))
        return
    try:
        # Interleaved ABBA minimizes a single fixed order effect.
        for index in range(args.samples):
            for kind in (['objc', 'swift'] if index % 2 == 0 else ['swift', 'objc']):
                sample_root = output / f'sample-{index + 1}-{kind}'
                sample_root.mkdir(mode=0o700)
                observation, phases = sample_root/'observation.json', sample_root/'phases.json'
                env = os.environ.copy()
                env.update(DYLD_INSERT_LIBRARIES=str(observer), DROIDBRIDGE_PREVIEW_OBSERVATIONS=str(observation), DROIDBRIDGE_PREVIEW_TITLE='DroidBridge AppKit Baseline')
                with (sample_root/'stderr.log').open('wb') as log:
                    began = time.monotonic()
                    child = subprocess.Popen([variants[kind]['executable'], str(sample_root), str(phases)], env=env, stdout=log, stderr=log)
                    try:
                        deadline = began + 5
                        while time.monotonic() < deadline:
                            try:
                                value = json.loads(observation.read_text())
                                if value.get('first_visible_window_uptime') is not None:
                                    break
                            except (FileNotFoundError, json.JSONDecodeError):
                                pass
                            if child.poll() is not None:
                                raise RuntimeError(f'{kind} baseline exited {child.returncode} before observer visibility')
                            time.sleep(.002)
                        else:
                            raise RuntimeError(f'{kind} baseline did not become visible within five seconds')
                        assert value['pid'] == child.pid
                        assert 0 <= value['constructor_uptime'] - began < 5, 'Observer and parent clock boundaries differ'
                        phase_values = json.loads(phases.read_text())
                        row = {'variant': kind, 'sample': index + 1, 'local_preview_ms': (value['first_visible_window_uptime'] - began) * 1000,
                               'constructor_to_preview_ms': (value['first_visible_window_uptime'] - value['constructor_uptime']) * 1000,
                               'spawn_to_constructor_ms': (value['constructor_uptime'] - began) * 1000,
                               'phase_ms': {key: (value - began) * 1000 for key, value in phase_values.items() if key != 'pid'},
                               'load_average_1_5_15_min': os.getloadavg()}
                        result['rows'].append(row)
                    finally:
                        if child.poll() is None:
                            child.terminate()
                        try:
                            child.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            child.kill()
                            child.wait(timeout=5)
                time.sleep(.1)
        result['groups'] = {kind: {key: quantiles([row[key] for row in result['rows'] if row['variant'] == kind])
                                  for key in ['local_preview_ms', 'constructor_to_preview_ms', 'spawn_to_constructor_ms']}
                            for kind in variants}
        result['cold_preview_target_passed'] = all(group['local_preview_ms']['p95'] <= 100 for group in result['groups'].values())
        result['execution_passed'] = True
    except BaseException as error:
        result['execution_passed'] = False
        result['error'] = str(error)
        raise
    finally:
        result_path.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'results': str(result_path), 'groups': result['groups']}))


if __name__ == '__main__':
    main()
