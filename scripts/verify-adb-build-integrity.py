#!/usr/bin/env python3
"""Focused regressions for release-source cache and embedded-notice admission."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('adb_builder', Path(__file__).with_name('build-adb-runtime.py'))
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class ADBBuildIntegrityTests(unittest.TestCase):
    def test_same_mtime_source_edit_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'code.c'
            source.write_text('int x;')
            expected = builder.tree_inventory(root)
            builder.require_tree_match(root, expected)
            metadata = source.stat()
            source.write_text('int y;')
            os.utime(source, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
            with self.assertRaisesRegex(RuntimeError, 'changed=.*code.c'):
                builder.require_tree_match(root, expected)

    def test_extra_source_file_mode_and_symlink_drift_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'code.c'
            source.write_text('int x;')
            link = root / 'current.h'
            link.symlink_to('code.c')
            expected = builder.tree_inventory(root)
            extra = root / 'unrecorded.h'
            extra.write_text('int injected;')
            with self.assertRaisesRegex(RuntimeError, 'added=.*unrecorded.h'):
                builder.require_tree_match(root, expected)
            extra.unlink()
            source.chmod(source.stat().st_mode ^ 0o100)
            with self.assertRaisesRegex(RuntimeError, 'changed=.*code.c'):
                builder.require_tree_match(root, expected)
            source.chmod(source.stat().st_mode ^ 0o100)
            link.unlink()
            link.symlink_to('missing.h')
            with self.assertRaisesRegex(RuntimeError, 'changed=.*current.h'):
                builder.require_tree_match(root, expected)

    def test_embedded_c_cpp_and_assembly_license_blocks_are_retained(self):
        text = '/* Copyright C author.\nRedistribution permitted. */\nint x;\n// Copyright C++ author.\n// Licensed under Apache 2.0.\nint y;\n# Copyright assembly author.\n# Permission is hereby granted.\n'
        comments = builder.notice_comments(text)
        self.assertEqual(len(comments), 3)
        self.assertTrue(all('author' in block for block in comments))
        self.assertFalse(any('int x' in block or 'int y' in block for block in comments))


if __name__ == '__main__':
    unittest.main(verbosity=2)
