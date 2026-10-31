#!/usr/bin/env python3
"""Independent, device-free adversarial checks for release validation boundaries."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
STAGE = ROOT / 'scripts/stage-adb-runtime.py'
RUNTIME = ROOT / '.build/adb-runtime'
APP = ROOT / 'dist/DroidBridge.app'
PACKAGER = ROOT / 'scripts/package-corresponding-source.py'
GUARDED = ('stage-adb-runtime.py', 'package-corresponding-source.py',
           'create-release-manifest.py', 'collect-companion-notices.py',
           'verify-package.py', 'build-companion-client-probe.py')


def run(arguments, **kwargs):
    return subprocess.run([sys.executable, *map(str, arguments)], cwd=ROOT,
                          capture_output=True, text=True, timeout=30, **kwargs)


class DistributionSecurityTests(unittest.TestCase):
    def test_validation_scripts_refuse_optimized_interpreter_before_admission(self):
        for name in GUARDED:
            with self.subTest(script=name, mode='-O'):
                result = run(['-O', ROOT / 'scripts' / name, '--help'])
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('optim', (result.stdout + result.stderr).lower())
            with self.subTest(script=name, mode='environment'):
                environment = dict(os.environ, PYTHONOPTIMIZE='1')
                result = run([ROOT / 'scripts' / name, '--help'], env=environment)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('optim', (result.stdout + result.stderr).lower())

    def test_valid_runtime_is_accepted_without_starting_adb(self):
        self.assertTrue((RUNTIME / 'adb-runtime.json').is_file(), 'Build the pinned runtime first')
        result = run([STAGE, '--adb', RUNTIME / 'adb'])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(json.loads(result.stdout)['verified_signatures_and_load_closure'])

    def test_signed_runtime_with_conflicting_hash_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix='distribution-hash-security-') as directory:
            target = Path(directory)
            inventory = json.loads((RUNTIME / 'adb-runtime.json').read_text())
            for entry in inventory['files']:
                shutil.copy2(RUNTIME / entry['name'], target / entry['name'])
            # Keep every signed binary untouched. Only the expected hash conflicts.
            inventory['files'][0]['sha256'] = '0' * 64
            (target / 'adb-runtime.json').write_text(json.dumps(inventory))
            result = run([STAGE, '--adb', target / 'adb'])
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('hash mismatch', result.stderr.lower())

    def test_missing_formula_source_refuses_archive_before_git_staging(self):
        with tempfile.TemporaryDirectory(prefix='distribution-coverage-security-') as directory:
            target = Path(directory)
            dependencies = target / 'dependencies'
            dependencies.mkdir()
            # The declared list is deliberately incomplete. No archive should be
            # written, even though the installed app itself is validly signed.
            (dependencies / 'MANIFEST.json').write_text(json.dumps([{'name': 'unrelated', 'version': '1'}]))
            output = target / 'source.tar.gz'
            result = run([PACKAGER, '--commit', 'HEAD', '--dependencies', dependencies,
                          '--adb-runtime', RUNTIME, '--app', APP, '--output', output])
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('formula/version cohort differs', result.stderr)
            self.assertFalse(output.exists())

    def test_signed_replacement_adb_cannot_be_bound_by_old_manifest(self):
        with tempfile.TemporaryDirectory(prefix='distribution-app-security-') as directory:
            target = Path(directory)
            app = target / 'DroidBridge.app'
            shutil.copytree(APP, app, symlinks=True)
            adb = app / 'Contents/Resources/Runtime/bin/adb'
            # A new valid ad-hoc signature changes the file identity without
            # changing adb-runtime.json. Deep app signature validation must pass;
            # exact inventory validation must still refuse this different cohort.
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier',
                            'dev.droidbridge.security.changed-adb', str(adb)], check=True, capture_output=True)
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
            subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True, capture_output=True)
            output = target / 'source.tar.gz'
            result = run([PACKAGER, '--commit', 'HEAD', '--app', app,
                          '--adb-runtime', RUNTIME, '--output', output])
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('stage-adb-runtime.py', result.stderr)
            self.assertFalse(output.exists())

    def test_duplicate_manifest_identity_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix='distribution-duplicate-security-') as directory:
            target = Path(directory)
            shutil.copy2(RUNTIME / 'adb', target / 'adb')
            inventory = (RUNTIME / 'adb-runtime.json').read_text()
            inventory = inventory.replace('"version": 1', '"version": 1, "version": 1')
            (target / 'adb-runtime.json').write_text(inventory)
            result = run([STAGE, '--adb', target / 'adb'])
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('duplicate', result.stderr.lower())


if __name__ == '__main__':
    unittest.main(verbosity=2)
