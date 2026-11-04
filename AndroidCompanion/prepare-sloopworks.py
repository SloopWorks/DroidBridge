#!/usr/bin/env python3
"""Build actual sibling SDK sources into an isolated, ignored development Maven repo.

This proves source compatibility, never publication. No global Maven cache is overwritten.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--workspace', type=Path, required=True)
parser.add_argument('--check-generated', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parent
workspace = args.workspace.resolve()
swip = workspace / 'sloopworksinstrumentationplatform' / 'sdk-kmp'
drawer = workspace / 'debugdrawer'
generated = Path('src/commonMain/kotlin/works/sloop/swip/schema/droidbridge')
snapshot = root / 'app/src/debug/java/works/sloop/swip/schema/droidbridge'
canonical = swip / 'schema-droidbridge' / generated
expected = {'Events.kt', 'Init.kt', 'AnonymousSafe.kt', 'Critical.kt', 'PseudonymousStrip.kt'}
if {p.name for p in canonical.glob('*.kt')} != expected or {p.name for p in snapshot.glob('*.kt')} != expected:
    raise SystemExit('Canonical SWIP or consumer generated contract file set is missing or unexpected.')
for source in canonical.glob('*.kt'):
    if source.read_bytes() != (snapshot / source.name).read_bytes():
        raise SystemExit(f'Generated contract snapshot differs: {source.name}; run SWIP codegen and copy exact output.')
if args.check_generated:
    print('Generated DroidBridge Kotlin contracts match canonical SWIP output.')
    raise SystemExit(0)
repo = root / 'build/sloopworks-maven'
repo.mkdir(parents=True, exist_ok=True)
java = os.environ.get('JAVA_HOME', '/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home')
env = dict(os.environ, JAVA_HOME=java)
with tempfile.TemporaryDirectory(prefix='droidbridge-sloopworks-') as temporary:
    init = Path(temporary) / 'local-repository.gradle'
    # JSON quoting is valid for the Groovy string literal; never interpolated into a shell.
    init.write_text('allprojects { plugins.withId("maven-publish") { publishing.repositories.maven { name = "DroidBridgeLocal"; url = uri(' + json.dumps(str(repo)) + ') } } }\n')
    for project, modules, extra in [(swip, ['swip-core', 'swip-debug'], []), (drawer, ['debugdrawer', 'debugdrawer-swip'], [f'-PswipSourcePath={swip}'])]:
        tasks = [f':{module}:publish{publication}PublicationToDroidBridgeLocalRepository' for module in modules for publication in ['AndroidRelease', 'KotlinMultiplatform']]
        subprocess.run([str(project / 'gradlew'), '-p', str(project), '--no-daemon', '--console=plain', '-I', str(init), *extra, *tasks], check=True, env=env)
receipts = []
for project in [swip.parent, drawer]:
    revision = subprocess.check_output(['git', '-C', str(project), 'rev-parse', 'HEAD'], text=True).strip()
    dirty = bool(subprocess.check_output(['git', '-C', str(project), 'status', '--porcelain'], text=True))
    receipts.append({'repository': project.name, 'revision': revision, 'dirty': dirty})
artifacts = {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(repo.rglob('*')) if p.suffix in ['.aar', '.jar', '.pom', '.module']}
(root / 'build/sloopworks-source-receipt.json').write_text(json.dumps({'source_builds': receipts, 'artifacts': artifacts}, indent=2) + '\n')
print(f'Source artifacts ready. Build with -PsloopworksLocalMaven={repo}')
