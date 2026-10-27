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
    def test_staging_excludes_stale_files_and_preserves_localized_resources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / 'Sources/Mimic/Resources'
            product = root / 'products/Mimic_Mimic.bundle'
            for base in (source, product):
                (base / 'ru.lproj').mkdir(parents=True)
                (base / 'tool.svg').write_text('current')
                (base / 'ru.lproj/Localizable.strings').write_text('localized')
            (product / 'Info.plist').write_text('generated')
            (product / 'removed-team-adapter.rb').write_text('private stale resource')
            resources.stage_project_bundle(root, product.parent, root / 'staged', 'Mimic')
            staged = root / 'staged/Mimic_Mimic.bundle'
            self.assertEqual({p.relative_to(staged).as_posix() for p in staged.rglob('*') if p.is_file()},
                             {'Info.plist', 'tool.svg', 'ru.lproj/Localizable.strings'})

    def test_staging_rejects_missing_declared_resource(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / 'Sources/Mimic/Resources'
            product = root / 'products/Mimic_Mimic.bundle'
            source.mkdir(parents=True); product.mkdir(parents=True)
            (source / 'required.svg').write_text('required')
            (product / 'Info.plist').write_text('generated')
            with self.assertRaisesRegex(RuntimeError, 'Missing or invalid declared resource'):
                resources.stage_project_bundle(root, product.parent, root / 'staged', 'Mimic')

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
