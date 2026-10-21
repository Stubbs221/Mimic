#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Created by Василий Маслов on 05.10.2026.
"""Development lifecycle checks; subprocesses and the user's bridge are never invoked."""
import importlib.util
import contextlib
import fcntl
import os
import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('deploy', pathlib.Path(__file__).with_name('deploy-development.py'))
deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)


class DevelopmentDeployTests(unittest.TestCase):
    def test_bad_inventory_fails_closed(self):
        with patch.object(deploy.subprocess, 'run', return_value=subprocess.CompletedProcess([], 3, '', '')):
            with self.assertRaises(RuntimeError):
                deploy.process_ids('Mimic')

    def test_busy_timeout_does_not_quit_or_install(self):
        with patch.object(deploy, 'process_ids', return_value=['123']), patch.object(deploy, 'prepare_exit') as quit_owner:
            with self.assertRaises(RuntimeError):
                deploy.wait_for_exit(0)
            quit_owner.assert_not_called()

    def test_waits_for_busy_owner_then_confirmed_disappearance(self):
        with patch.object(deploy, 'process_ids', side_effect=[['123'], [], [], ['123'], [], [], [], [], []]), \
             patch.object(deploy, 'prepare_exit', side_effect=[False, True]) as quit_owner, patch.object(deploy.time, 'sleep'):
            deploy.wait_for_exit(30)
            self.assertEqual(quit_owner.call_count, 2)

    def test_bridge_failure_with_live_owner_aborts(self):
        with patch.object(deploy, 'process_ids', return_value=['123']), \
             patch.object(deploy, 'prepare_exit', side_effect=OSError('fixture connection failure')):
            with self.assertRaises(OSError):
                deploy.wait_for_exit(30)

    def test_reply_timeout_waits_for_confirmed_owner_disappearance(self):
        with patch.object(deploy, 'process_ids', side_effect=[['123'], [], [], [], [], []]), \
             patch.object(deploy, 'prepare_exit', side_effect=TimeoutError()) as quit_owner, \
             patch.object(deploy.time, 'sleep'):
            deploy.wait_for_exit(30)
            quit_owner.assert_called_once()

    def test_reply_timeouts_do_not_extend_the_original_deadline(self):
        with patch.object(deploy, 'process_ids', return_value=['123']), \
             patch.object(deploy, 'prepare_exit', side_effect=TimeoutError()), \
             patch.object(deploy.time, 'monotonic', side_effect=[0, 0, 31]), patch.object(deploy.time, 'sleep'):
            with self.assertRaises(RuntimeError):
                deploy.wait_for_exit(30)

    def test_socket_disappears_before_owner_exit(self):
        for failure in [FileNotFoundError(), ConnectionRefusedError()]:
            with self.subTest(failure=type(failure).__name__), \
                 patch.object(deploy, 'process_ids', side_effect=[['123'], [], [], [], [], []]), \
                 patch.object(deploy, 'prepare_exit', side_effect=failure), patch.object(deploy.time, 'sleep'):
                deploy.wait_for_exit(30)

    def test_missing_bridge_remains_bounded_by_original_deadline(self):
        with patch.object(deploy, 'process_ids', return_value=['123']), \
             patch.object(deploy, 'prepare_exit', side_effect=FileNotFoundError()), \
             patch.object(deploy.time, 'monotonic', side_effect=[0, 0, 31]), patch.object(deploy.time, 'sleep'):
            with self.assertRaises(RuntimeError):
                deploy.wait_for_exit(30)

    def test_invalid_bundle_never_requests_exit(self):
        with patch.object(deploy.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'fixture')), \
             patch.object(deploy, 'wait_for_exit') as wait:
            with self.assertRaises(subprocess.CalledProcessError):
                deploy.deploy(pathlib.Path('/tmp/fixture/Mimic.app'), pathlib.Path('/tmp/installed/Mimic.app'), 0)
            wait.assert_not_called()

    def test_source_cannot_be_installed_bundle(self):
        with patch.object(deploy.subprocess, 'run') as run:
            with self.assertRaises(RuntimeError):
                deploy.deploy(pathlib.Path('/tmp/Mimic.app'), pathlib.Path('/tmp/Mimic.app'), 0)
            run.assert_not_called()

    def test_validated_idle_install_launch_and_plugin_refresh_order(self):
        with tempfile.TemporaryDirectory(prefix='MimicDevelopmentFixture-') as directory:
            root = pathlib.Path(directory)
            manifest = root / 'CodexPlugin/plugins/mimic/.mcp.json'
            manifest.parent.mkdir(parents=True); manifest.write_text('{}')
            app = root / 'Source/Mimic.app'
            destination = root / 'Installed/Mimic.app'
            (destination / 'Contents').mkdir(parents=True)
            with (destination / 'Contents/Info.plist').open('wb') as file:
                deploy.plistlib.dump({}, file)
            events = []
            @contextlib.contextmanager
            def handoff(seconds):
                events.append('locked'); yield; events.append('unlocked')
            with patch.object(deploy, 'SUPPORT', root), \
                 patch.object(deploy.subprocess, 'run', side_effect=lambda command, **kwargs: events.append(command)), \
                 patch.object(deploy, 'native_handoff', side_effect=handoff), \
                 patch.object(deploy, 'verify_launch', side_effect=lambda path: events.append('launched')):
                deploy.deploy(app, destination, 30)
            self.assertEqual(events[0][-1], '--check-only')
            self.assertEqual(events[1], 'locked')
            self.assertEqual(events[2][-2:], ['--yes', '--defer-launch'])
            self.assertEqual(events[3], 'unlocked')
            self.assertEqual(events[4], ['/usr/bin/open', '-a', str(destination), '--args', '--mcp-background'])
            self.assertEqual(events[5], 'launched')
            self.assertEqual(events[6], [str(destination / 'Contents/MacOS/Mimic'), '--refresh-codex-plugin'])

    def test_handoff_excludes_another_owner_and_releases_on_failure(self):
        with tempfile.TemporaryDirectory(prefix='MimicHandoffFixture-') as directory:
            root = pathlib.Path(directory)
            with patch.object(deploy, 'SUPPORT', root), patch.object(deploy, 'wait_for_exit') as wait, \
                 patch.object(deploy, 'process_ids', return_value=[]):
                path = root / 'Bridge/native-instance.lock'
                with self.assertRaisesRegex(RuntimeError, 'fixture'):
                    with deploy.native_handoff(10):
                        descriptor = os.open(path, os.O_RDWR)
                        try:
                            with self.assertRaises(BlockingIOError):
                                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        finally:
                            os.close(descriptor)
                        raise RuntimeError('fixture')
                wait.assert_called_once()
                descriptor = os.open(path, os.O_RDWR)
                try:
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                finally:
                    os.close(descriptor)

    def test_handoff_rejects_symlink_without_touching_target(self):
        with tempfile.TemporaryDirectory(prefix='MimicHandoffLink-') as directory:
            root = pathlib.Path(directory); (root / 'Bridge').mkdir()
            target = root / 'target'; target.write_text('fixture')
            (root / 'Bridge/native-instance.lock').symlink_to(target)
            with patch.object(deploy, 'SUPPORT', root), self.assertRaises(OSError):
                with deploy.native_handoff(0): pass
            self.assertEqual(target.read_text(), 'fixture')


if __name__ == '__main__':
    unittest.main()
