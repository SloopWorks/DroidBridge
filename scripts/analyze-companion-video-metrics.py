#!/usr/bin/env python3
"""Analyze bounded metadata from actual installed native QA sessions.

This consumes qa_video_metrics, never images, text input or clipboard content.
Motion must be visibly enabled before the explicit measurement start boundary.
Configured ceiling, observed decoded rate and test sufficiency stay separate.
"""
import argparse
import json
import math
from pathlib import Path
import uuid

def analyze(paths, serial, session, expected_fps, start, end):
    identity = str(uuid.UUID(session))
    unique = {}
    for path in paths:
        assert path.is_file() and not path.is_symlink() and path.stat().st_size <= 4_194_304, 'Bounded regular session logs required'
        for line in path.read_text().splitlines():
            event = json.loads(line)
            if event.get('event') != 'qa_video_metrics' or str(uuid.UUID(event['session'])) != identity:
                continue
            assert event.get('device') == serial and event.get('backend') == 'native', 'The metrics do not belong to the exact native device/session'
            details = event['details']
            row = {k: float(details[k]) for k in ['frames', 'bytes', 'width', 'height', 'uptime', 'config_fps']}
            assert all(math.isfinite(v) for v in row.values()), 'Nonfinite metrics refused'
            assert row['frames'] >= 0 and row['bytes'] >= 0 and row['width'] > 0 and row['height'] > 0, 'Invalid native counters'
            assert row['config_fps'] == expected_fps, 'The actual installed descriptor has the wrong encoder ceiling'
            row['final'] = details.get('final') == 'true'
            key = (row['uptime'], row['final'])
            assert key not in unique or unique[key] == row, 'Conflicting metrics replay refused'
            unique[key] = row
    samples = sorted((r for r in unique.values() if not r['final'] and start <= r['uptime'] <= end), key=lambda r: r['uptime'])
    assert len(samples) >= 2, 'No sufficient actual periodic metrics in the requested interval'
    intervals, resize_intervals = [], 0
    for before, after in zip(samples, samples[1:]):
        elapsed = after['uptime'] - before['uptime']
        assert elapsed > 0 and after['frames'] >= before['frames'] and after['bytes'] >= before['bytes'], 'Native counters regressed'
        if (before['width'], before['height']) != (after['width'], after['height']):
            resize_intervals += 1
            continue
        intervals.append({'elapsed_seconds': elapsed, 'frames': after['frames'] - before['frames'], 'decoded_fps': (after['frames'] - before['frames']) / elapsed})
    duration = sum(i['elapsed_seconds'] for i in intervals)
    frames = sum(i['frames'] for i in intervals)
    sufficient = len(intervals) >= 4 and duration >= 4
    observed = frames / duration if duration else None
    motion_observed = observed is not None and observed >= expected_fps * .6
    ceiling_observed = observed is not None and observed <= expected_fps * 1.1 and all(i['decoded_fps'] <= expected_fps * 1.2 for i in intervals)
    rates = sorted(i['decoded_fps'] for i in intervals)
    return {'passed': sufficient and motion_observed and ceiling_observed, 'scope': 'Actual installed native session periodic decoded-frame metadata; explicit visible-motion measurement interval; no battery-savings claim', 'session': identity, 'serial': serial, 'configured_fps': expected_fps, 'configured_ceiling_verified': True, 'samples': len(samples), 'usable_intervals': len(intervals), 'resize_intervals_excluded': resize_intervals, 'duration_seconds': duration, 'decoded_frames': frames, 'observed_decoded_fps': observed, 'interval_fps_p50': rates[math.ceil(len(rates)*.5)-1] if rates else None, 'interval_fps_p95': rates[math.ceil(len(rates)*.95)-1] if rates else None, 'sufficient_duration': sufficient, 'motion_observed': motion_observed, 'ceiling_observed': ceiling_observed, 'intervals': intervals}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--log', type=Path, action='append', required=True)
    parser.add_argument('--serial', choices=['emulator-5580', 'emulator-5582'], required=True)
    parser.add_argument('--session', required=True)
    parser.add_argument('--expected-fps', type=int, choices=[15, 30, 60], required=True)
    parser.add_argument('--start-uptime', type=float, required=True)
    parser.add_argument('--end-uptime', type=float, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    assert math.isfinite(args.start_uptime) and math.isfinite(args.end_uptime) and args.end_uptime > args.start_uptime
    assert len(args.log) <= 8, 'Bounded session log cohort required'
    value = analyze(args.log, args.serial, args.session, args.expected_fps, args.start_uptime, args.end_uptime)
    assert not args.output.exists(), 'Retain the prior attempt instead of overwriting its evidence'
    args.output.write_text(json.dumps(value, indent=2))
    print(json.dumps({k: v for k, v in value.items() if k != 'intervals'}))
    if not value['passed']:
        raise SystemExit(1)

if __name__ == '__main__': main()
