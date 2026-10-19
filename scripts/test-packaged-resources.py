#!/usr/bin/env python3
# Created by Василий Маслов on 13.10.2026.
"""Regression checks for release resource access and fail-closed packaging."""
import importlib.util
import pathlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('resources', pathlib.Path(__file__).with_name('check-packaged-resources.py'))
resources = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resources)


class PackagedResourcesTests(unittest.TestCase):
    def check_source(self, text):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / 'Sources').mkdir()
            (root / 'Sources/Resources.swift').write_text(text)
            resources.check_sources(root)

    def test_release_accessor_is_rejected_even_when_debug_fallback_exists(self):
        with self.assertRaisesRegex(RuntimeError, 'release Bundle.module'):
            self.check_source('#if DEBUG\nlet a = Bundle.module\n#endif\nlet b = Bundle.module\n')

    def test_release_else_accessor_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'release Bundle.module'):
            self.check_source('#if DEBUG\nlet a = Bundle.main\n#else\nlet a = Bundle.module\n#endif\n')

    def test_debug_fallback_and_comment_are_allowed(self):
        self.check_source('// Bundle.module must not ship\n#if DEBUG\nlet a = Bundle.module\n#endif\n')

    def test_missing_bundle_fails_before_any_probe(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(resources.subprocess, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'Missing packaged resource bundle'):
                resources.check_app(pathlib.Path(directory) / 'Mimic.app')
            run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
