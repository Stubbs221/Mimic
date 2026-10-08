#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Created by Василий Маслов on 04.10.2026.
"""Installer fixtures: no real application, credentials or Codex configuration."""
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent

class SetupScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='Mimic setup fixtures ')
        self.root = pathlib.Path(self.temp.name)
        self.app = self.root / 'Source with spaces.app'
        self.make_app(self.app)
        # Only process inventory is replaced; all validation and copy commands remain real.
        self.inventory = self.root / 'process-inventory'
        self.inventory.write_text('#!/bin/sh\nexit 1\n')
        self.inventory.chmod(0o700)
        self.script = self.root / 'setup-mimic.command'
        self.script.write_text((ROOT / 'setup-mimic.command').read_text().replace('/usr/bin/pgrep', str(self.inventory).replace(' ', '\\ ')))
        shutil.copy2(ROOT / 'setup-mimic.ru.plist', self.root)
        self.script.chmod(0o700)
    def make_app(self, app, executable='Mimic'):
        contents = app / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        (contents / 'Helpers').mkdir()
        with (contents / 'Info.plist').open('wb') as f:
            plistlib.dump({'CFBundleIdentifier': 'local.vmaslov.Mimic', 'CFBundleName': 'Mimic', 'CFBundleExecutable': executable, 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '8'}, f)
        for path in ['MacOS/' + executable, 'Helpers/TaskHost', 'Helpers/MimicMCP']:
            target = contents / path
            shutil.copy('/usr/bin/true', target)
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(target)], check=True, capture_output=True)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
    def tearDown(self):
        self.temp.cleanup()
    def run_script(self, *args, answer='yes\n'):
        return subprocess.run(['/bin/bash', str(self.script), '--app', str(self.app), *args], input=answer, text=True, capture_output=True, timeout=15)
    def test_spaces_and_repeated_install_removes_backups(self):
        destination = self.root / 'Installed apps' / 'Mimic.app'
        self.assertEqual(self.run_script('--check-only').returncode, 0)
        self.assertEqual(self.run_script('--destination', str(destination)).returncode, 0)
        self.assertTrue(destination.exists())
        self.assertEqual(self.run_script('--destination', str(destination)).returncode, 0)
        self.assertFalse(list(destination.parent.glob('Mimic.backup.*.app')))
        self.assertEqual(self.run_script('--destination', str(destination), '--uninstall-integration').returncode, 0)
        self.assertTrue(destination.exists())
    def test_cleanup_preserves_unrelated_bundles_symlinks_and_source(self):
        destination = self.root / 'Mimic.app'
        old = self.root / 'Mimic.backup.old.app'
        self.make_app(old)
        legacy = self.root / 'Mimic.backup.legacy.app'
        self.make_app(legacy)
        with (legacy / 'Contents/Info.plist').open('wb') as file:
            plistlib.dump({'CFBundleIdentifier': 'local.vmaslov.IVIToolbox', 'CFBundleName': 'Mimic', 'CFBundleExecutable': 'Mimic'}, file)
        unrelated = self.root / 'Mimic.backup.unrelated.app'
        self.make_app(unrelated)
        with (unrelated / 'Contents/Info.plist').open('wb') as file:
            plistlib.dump({'CFBundleIdentifier': 'another.app'}, file)
        link = self.root / 'Mimic.backup.link.app'
        link.symlink_to(self.app, target_is_directory=True)
        self.app = self.root / 'Mimic.backup.source.app'
        self.make_app(self.app)
        self.assertEqual(self.run_script('--destination', str(destination)).returncode, 0)
        self.assertFalse(old.exists())
        self.assertFalse(legacy.exists())
        self.assertTrue(unrelated.exists())
        self.assertTrue(link.is_symlink())
        self.assertTrue(self.app.exists())
    def test_missing_app_and_helper_and_bad_bundle(self):
        self.assertNotEqual(self.run_script('--app', str(self.root / 'missing.app'), '--check-only').returncode, 0)
        (self.app / 'Contents/Helpers/TaskHost').unlink()
        self.assertNotEqual(self.run_script('--check-only').returncode, 0)
        with (self.app / 'Contents/Info.plist').open('wb') as f:
            plistlib.dump({'CFBundleIdentifier': 'another.app'}, f)
        self.assertNotEqual(self.run_script('--check-only').returncode, 0)
    def test_running_owner_prevents_replacement(self):
        destination = self.root / 'Installed.app'
        shutil.copytree(self.app, destination)
        self.inventory.write_text('#!/bin/sh\nexit 0\n')
        self.assertNotEqual(self.run_script('--destination', str(destination)).returncode, 0)
        self.assertFalse(list(self.root.glob('Mimic.backup.*.app')))
    def test_inventory_failure_prevents_install(self):
        self.inventory.write_text('#!/bin/sh\nexit 3\n')
        destination = self.root / 'Mimic.app'
        self.assertNotEqual(self.run_script('--destination', str(destination)).returncode, 0)
        self.assertFalse(destination.exists())
    def test_architecture_mismatch(self):
        arch = self.root / 'architecture'
        arch.write_text('#!/bin/sh\necho unsupported_fixture_arch\n'); arch.chmod(0o700)
        self.script.write_text(self.script.read_text().replace('/usr/bin/lipo', str(arch).replace(' ', '\\ ')))
        self.assertNotEqual(self.run_script('--check-only').returncode, 0)
    def test_decline_does_not_install(self):
        destination = self.root / 'Mimic.app'
        self.assertEqual(self.run_script('--destination', str(destination), answer='no\n').returncode, 0)
        self.assertFalse(destination.exists())
    def test_yes_installs_without_stdin_and_still_checks_processes(self):
        destination = self.root / 'Mimic.app'
        self.assertEqual(self.run_script('--destination', str(destination), '--yes', answer='').returncode, 0)
        self.inventory.write_text('#!/bin/sh\nexit 0\n')
        self.assertNotEqual(self.run_script('--destination', str(destination), '--yes', answer='').returncode, 0)
        self.assertFalse(list(self.root.glob('Mimic.backup.*.app')))
    def test_background_launch_uses_installed_bundle(self):
        launch = self.root / 'open-fixture'
        launch.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n'); launch.chmod(0o700)
        self.script.write_text(self.script.read_text().replace('/usr/bin/open', str(launch).replace(' ', '\\ ')))
        destination = self.root / 'Applications' / 'Mimic.app'
        result = self.run_script('--destination', str(destination), '--yes', '--background', answer='')
        self.assertEqual(result.returncode, 0)
        self.assertIn(str(destination) + '\n--args\n--mcp-background', result.stdout)
    def test_process_appearing_after_staging_prevents_replacement(self):
        destination = self.root / 'Mimic.app'
        shutil.copytree(self.app, destination)
        counter = self.root / 'inventory-count'
        self.inventory.write_text('#!/bin/sh\n'
            f'count=$(cat "{counter}" 2>/dev/null || echo 0)\n'
            f'count=$((count + 1)); echo "$count" > "{counter}"\n'
            '[ "$count" -lt 4 ] && exit 1\nexit 0\n')
        result = self.run_script('--destination', str(destination), '--yes', answer='')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(destination.exists())
        self.assertFalse(list(self.root.glob('Mimic.backup.*.app')))
    def test_legacy_executable_still_installs(self):
        self.app = self.root / 'Legacy source.app'
        self.make_app(self.app, executable='Mimic')
        destination = self.root / 'Mimic.app'
        self.assertEqual(self.run_script('--check-only').returncode, 0)
        self.assertEqual(self.run_script('--destination', str(destination)).returncode, 0)
        self.assertTrue((destination / 'Contents/MacOS/Mimic').exists())
    def test_new_executable_replaces_legacy_bundle_without_backup(self):
        destination = self.root / 'Mimic.app'
        self.make_app(destination, executable='Mimic')
        self.assertEqual(self.run_script('--destination', str(destination)).returncode, 0)
        self.assertTrue((destination / 'Contents/MacOS/Mimic').exists())
        self.assertFalse(list(self.root.glob('Mimic.backup.*.app')))
    def test_arbitrary_executable_paths_are_rejected(self):
        plist = self.app / 'Contents/Info.plist'
        with plist.open('rb') as f:
            metadata = plistlib.load(f)
        with (ROOT / 'setup-mimic.ru.plist').open('rb') as f:
            helper_error = plistlib.load(f)['helper']
        for executable in ['../Helpers/TaskHost', '/usr/bin/true', 'Unexpected', '']:
            with self.subTest(executable=executable):
                metadata['CFBundleExecutable'] = executable
                with plist.open('wb') as f:
                    plistlib.dump(metadata, f)
                result = self.run_script('--check-only')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(helper_error, result.stderr)

if __name__ == '__main__':
    unittest.main()
