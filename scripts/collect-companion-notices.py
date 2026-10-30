#!/usr/bin/env python3
"""Copy the notices from the exact bundled APK, never from a different build."""
import argparse, hashlib, json, pathlib, zipfile
if not __debug__:
    raise SystemExit('Companion notice validation requires Python assertions; remove -O/PYTHONOPTIMIZE.')

p = argparse.ArgumentParser()
p.add_argument('apk', type=pathlib.Path)
p.add_argument('destination', type=pathlib.Path)
a = p.parse_args()
names = {'Apache-2.0.txt', 'COMPONENTS.txt', 'NOTICE.txt', 'zxing-NOTICE.txt', 'kotlin-NOTICE.txt', 'SOURCES.json'}
with zipfile.ZipFile(a.apk) as archive:
    entries = {}
    for name in names:
        entry = archive.getinfo('assets/licenses/' + name)
        assert 0 < entry.file_size <= 65_536, 'Missing or oversized companion notice: ' + name
        entries[name] = archive.read(entry)
    for source in json.loads(entries['SOURCES.json']):
        assert source['file'] in names
        assert hashlib.sha256(entries[source['file']]).hexdigest() == source['sha256'], 'Companion notice source hash mismatch'
a.destination.mkdir(parents=True, exist_ok=True)
for name, data in entries.items():
    (a.destination / name).write_bytes(data)
print('Copied exact companion APK notices.')
