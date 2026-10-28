#!/usr/bin/env python3
"""Collect exact installed runtime notices; record origins for source compliance review."""
import json
import pathlib
import shutil
import subprocess
import sys

repo = pathlib.Path(__file__).resolve().parents[1]
runtime = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else repo / 'dist/DroidBridge.app/Contents/Resources/Runtime'
manifest = json.loads((runtime / 'dependencies.json').read_text())
output = repo / 'Resources/licenses'
output.mkdir(parents=True, exist_ok=True)
formulae = {}
for origin in manifest.values():
    parts = pathlib.Path(origin).parts
    if 'Cellar' not in parts:
        continue
    i = parts.index('Cellar')
    name, version = parts[i + 1:i + 3]
    prefix = pathlib.Path(*parts[:i + 3])
    files = []
    for candidate in prefix.iterdir():
        if candidate.is_file() and candidate.name.lower().startswith(('license', 'copying', 'copyright', 'notice')):
            target = output / (name + '-' + version + '-' + candidate.name)
            shutil.copy2(candidate, target)
            files.append(target.name)
    receipt = prefix / 'INSTALL_RECEIPT.json'
    if receipt.exists():
        shutil.copy2(receipt, output / (name + '-' + version + '-INSTALL_RECEIPT.json'))
    formulae[name] = {'version': version, 'installed_origin': str(prefix), 'notices': files}

sdk = pathlib.Path.home() / 'Library/Android/sdk/platform-tools'
notice = sdk / 'NOTICE.txt'
if notice.exists():
    shutil.copy2(notice, output / 'android-platform-tools-NOTICE.txt')
source = repo / 'Vendor/scrcpy/LICENSE'
if source.exists():
    shutil.copy2(source, output / 'scrcpy-Apache-2.0.txt')
metadata = subprocess.check_output(['brew', 'info', '--json=v2', *sorted(formulae)], text=True)
(output / 'homebrew-formulae.json').write_text(metadata)
(output / 'runtime-notices.json').write_text(json.dumps(formulae, indent=2) + '\n')
print(f'Collected runtime notices for {len(formulae)} formulae. Corresponding-source review remains required before public redistribution.')
