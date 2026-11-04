#!/usr/bin/env python3
"""Real local signature checks and hostile release-configuration regressions."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from release_signing import configuration, preflight, run, sign, source_revision, verify


class ReleaseSigningTests(unittest.TestCase):
    def test_source_identity_requires_a_committed_candidate(self):
        with tempfile.TemporaryDirectory(prefix='droidbridge-source-identity-') as directory:
            root = Path(directory)
            run(['/usr/bin/git', '-C', root, 'init', '-q'])
            source = root / 'source.swift'
            source.write_text('// exact candidate\n')
            run(['/usr/bin/git', '-C', root, 'add', 'source.swift'])
            run(['/usr/bin/git', '-C', root, '-c', 'user.name=DroidBridge Test',
                 '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false',
                 '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'Candidate'])
            expected = run(['/usr/bin/git', '-C', root, 'rev-parse', 'HEAD']).strip()
            (root / 'verification').mkdir()
            (root / 'verification' / 'test.log').write_text('Evidence is not source\n')
            self.assertEqual(source_revision(root), expected)
            source.write_text('// changed after candidate freeze\n')
            with self.assertRaisesRegex(ValueError, 'committed source'):
                source_revision(root)
            source.write_text('// exact candidate\n')
            (root / 'untracked.swift').write_text('// omitted source\n')
            with self.assertRaisesRegex(ValueError, 'committed source'):
                source_revision(root)

    def test_release_cannot_fall_back_to_development_identity(self):
        for values in [
            {'DROIDBRIDGE_SIGNING_MODE': 'release'},
            {'DROIDBRIDGE_SIGNING_MODE': 'developer-id'},
            {'DROIDBRIDGE_SIGNING_MODE': 'developer-id', 'DROIDBRIDGE_SIGNING_IDENTITY': '-'},
            {'DROIDBRIDGE_SIGNING_MODE': 'developer-id', 'DROIDBRIDGE_SIGNING_IDENTITY': 'a' * 40,
             'DROIDBRIDGE_DEVELOPMENT_TEAM': 'AAAAAAAAAA', 'DROIDBRIDGE_NOTARY_PROFILE': '../unsafe'},
        ]:
            with self.subTest(values=values), self.assertRaises(ValueError):
                configuration(values)
        config = configuration({'DROIDBRIDGE_SIGNING_MODE': 'developer-id',
            'DROIDBRIDGE_SIGNING_IDENTITY': '0' * 40, 'DROIDBRIDGE_DEVELOPMENT_TEAM': 'AAAAAAAAAA',
            'DROIDBRIDGE_NOTARY_PROFILE': 'not-a-real-release-profile'})
        with self.assertRaises(ValueError):
            preflight(config)

    def test_real_adhoc_code_is_not_a_developer_id_release(self):
        with tempfile.TemporaryDirectory(prefix='droidbridge-signing-test-') as directory:
            root = Path(directory)
            source, executable = root / 'main.c', root / 'probe'
            source.write_text('int main(void) { return 0; }\n')
            run(['/usr/bin/clang', source, '-o', executable])
            sign(executable, configuration({}))
            run(['/usr/bin/codesign', '--verify', '--strict', executable])
            with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                verify(executable, 'AAAAAAAAAA')

    def test_package_fails_before_output_on_missing_release_credentials(self):
        with tempfile.TemporaryDirectory(prefix='droidbridge-package-refusal-') as directory:
            output = Path(directory) / 'candidate'
            env = {k: v for k, v in os.environ.items() if not k.startswith('DROIDBRIDGE_')}
            env.update(DROIDBRIDGE_SIGNING_MODE='developer-id', DROIDBRIDGE_OUTPUT_DIR=str(output))
            result = subprocess.run(['/bin/bash', str(Path(__file__).with_name('package.sh'))],
                env=env, capture_output=True, text=True, timeout=30)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('certificate SHA-1 fingerprint', result.stderr)
            self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
