#!/usr/bin/env python3
"""Stage exact installed Homebrew source plus recipes; never substitute latest.

Downloads are verified by Homebrew and re-hashed here. This produces reviewable
source inputs, not an assertion of license compliance or an automatic upload.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--runtime', type=Path, default=Path('dist/DroidBridge.app/Contents/Resources/Runtime'))
parser.add_argument('--output', type=Path, default=Path('.build/corresponding-source'))
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
environment = dict(os.environ, HOMEBREW_NO_AUTO_UPDATE='1', HOMEBREW_NO_ANALYTICS='1')

def run(argv):
    return subprocess.check_output(argv, env=environment, text=True, stderr=subprocess.STDOUT, timeout=600).strip()

def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()

origins = set()
for origin in json.loads((args.runtime / 'dependencies.json').read_text()).values():
    parts = Path(origin).parts
    if 'Cellar' not in parts:
        raise SystemExit(f'Unmapped non-system dependency origin: {origin}')
    index = parts.index('Cellar')
    origins.add(Path(*parts[:index + 3]))

def collect(origin):
    name, version = origin.parent.name, origin.name
    recipe = origin / '.brew' / (name + '.rb')
    if not recipe.is_file():
        raise RuntimeError(f'Exact installed recipe missing: {origin}')
    target = args.output / (name + '-' + version)
    target.mkdir(exist_ok=True)
    metadata = json.loads(run(['brew', 'info', '--json=v2', '--formula', str(recipe)]))['formulae'][0]
    source = metadata['urls']['stable']
    (target / 'formula.json').write_text(json.dumps(metadata, indent=2) + '\n')
    shutil.copy2(recipe, target / recipe.name)
    for file in ('INSTALL_RECEIPT.json', 'sbom.spdx.json'):
        if (origin / file).is_file():
            shutil.copy2(origin / file, target / file)
    fetched = run(['brew', 'fetch', '--build-from-source', '--formula', str(recipe)])
    (target / 'fetch.log').write_text(fetched + '\n')
    cache = Path(run(['brew', '--cache', '--build-from-source', '--formula', str(recipe)]).splitlines()[-1])
    if cache.is_file():
        if source.get('checksum') != sha(cache):
            raise RuntimeError(f'Exact source checksum mismatch: {name}')
        staged = target / cache.name.split('--', 1)[-1]
        shutil.copy2(cache, staged)
    elif cache.is_dir() and source.get('revision'):
        revision = source['revision']
        actual = run(['git', '-C', str(cache), 'rev-parse', revision + '^{commit}'])
        if actual != revision:
            raise RuntimeError(f'Exact Git source revision mismatch: {name}')
        staged = target / (name + '-' + revision + '.tar')
        with staged.open('wb') as output:
            subprocess.run(['git', '-C', str(cache), 'archive', '--format=tar', '--prefix=' + name + '/', revision], stdout=output, env=environment, check=True, timeout=120)
        # Some build scripts derive version headers from Git history. Preserve
        # the verified cache's reachable history as a bundle, not a live config
        # that might contain credentials or mutable remote settings.
        bundle = target / (name + '-source.git.bundle')
        subprocess.run(['git', '-C', str(cache), 'bundle', 'create', str(bundle.resolve()), '--all', 'HEAD'], env=environment, stdout=subprocess.DEVNULL, check=True, timeout=120)
        subprocess.run(['git', '-C', str(cache), 'bundle', 'verify', str(bundle.resolve())], env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=120)
    else:
        raise RuntimeError(f'Unsupported exact source cache: {name}')
    # External patches must be staged too, rather than leaving only URLs.
    patches = metadata.get('patches') or []
    if patches:
        raise RuntimeError(f'External patch staging requires explicit review: {name}: {patches}')
    return {'name': name, 'version': version, 'url': source['url'],
            'revision': source.get('revision'), 'source': str(staged.relative_to(args.output)),
            'git_bundle': str(bundle.relative_to(args.output)) if cache.is_dir() else None,
            'git_bundle_sha256': sha(bundle) if cache.is_dir() else None,
            'source_sha256': sha(staged), 'recipe_sha256': sha(recipe)}

results = []
with ThreadPoolExecutor(max_workers=2) as pool:
    for item in pool.map(collect, sorted(origins)):
        results.append(item)
        print(f"Verified source {item['name']} {item['version']}", flush=True)
(args.output / 'MANIFEST.json').write_text(json.dumps(results, indent=2) + '\n')
print('Source staging complete; packaging and independent distribution review remain required.')
