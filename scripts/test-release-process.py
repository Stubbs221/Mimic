#!/usr/bin/env python3
# Created by Василий Маслов on 08.10.2026.
"""Disposable release transaction fixtures; no Apple, Keychain or GitHub writes."""
import argparse
import hashlib
import importlib.util
import json
import pathlib
import subprocess
import tempfile
import unittest
import urllib.error
import zipfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('release_process', pathlib.Path(__file__).with_name('release.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseProcessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.args = argparse.Namespace(release_dir=self.root, submission_id=None, sparkle_tools=self.root, gh='fixture-gh')
        self.state = dict(schema=1, stage='built', version='1.3.1', build='131', tag='v1.3.1', commit='a' * 40,
                          config={'repository': 'fixture/Mimic', 'keyAccount': 'fixture', 'feedURL': 'https://example.invalid/appcast.xml'},
                          firstRelease=False, previousFeedSHA256='previous', keychainProfile='fixture', submissionID='existing-id')

    def save(self):
        release.save(self.root, self.state)

    def test_pending_notarization_reuses_submission(self):
        self.save()
        with patch.object(release, 'run', return_value=json.dumps({'status': 'In Progress'})) as run:
            release.resume(self.args)
        self.assertEqual(run.call_count, 1)
        self.assertIn('info', run.call_args.args)
        self.assertEqual(release.read_state(self.root)['submissionID'], 'existing-id')

    def test_accepted_resume_staples_and_qualifies_without_submission(self):
        self.save()
        with patch.object(release, 'run', return_value=json.dumps({'status': 'Accepted'})) as run, \
             patch.object(release, 'qualify') as qualify:
            release.resume(self.args)
        self.assertEqual(run.call_count, 2)
        self.assertIn('staple', run.call_args.args)
        qualify.assert_called_once()

    def test_ambiguous_submission_cannot_be_resent(self):
        self.state.update(stage='submitting', submissionID=None)
        self.save()
        with patch.object(release, 'run') as run, self.assertRaisesRegex(ValueError, 'outcome unknown'):
            release.resume(self.args)
        run.assert_not_called()

    def test_submission_failure_leaves_durable_ambiguity_marker(self):
        self.state['submissionID'] = None
        self.save()
        def command(*args):
            if 'submit' in args:
                self.assertEqual(release.read_state(self.root)['stage'], 'submitting')
                raise subprocess.CalledProcessError(1, 'fixture-notarytool')
            return ''
        with patch.object(release, 'run', side_effect=command), self.assertRaises(subprocess.CalledProcessError):
            release.resume(self.args)
        self.assertEqual(release.read_state(self.root)['stage'], 'submitting')

    def test_rejected_notarization_never_packages(self):
        self.save()
        with patch.object(release, 'run', return_value=json.dumps({'status': 'Invalid'})), \
             patch.object(release, 'qualify') as qualify, self.assertRaisesRegex(ValueError, 'did not accept'):
            release.resume(self.args)
        qualify.assert_not_called()

    def test_cannot_replace_known_submission(self):
        self.save()
        self.args.submission_id = 'other-id'
        with self.assertRaisesRegex(ValueError, 'Cannot replace'):
            release.resume(self.args)

    def test_only_first_release_allows_missing_feed(self):
        error = urllib.error.HTTPError('https://example.invalid', 404, 'missing', None, None)
        with patch.object(release, 'fetch', side_effect=error):
            self.assertIsNone(release.previous_feed(self.root, self.args, self.state['config'], first=True))
            with self.assertRaises(urllib.error.HTTPError):
                release.previous_feed(self.root, self.args, self.state['config'])

    def test_existing_feed_must_be_verified_before_use(self):
        with patch.object(release, 'fetch', return_value=b'<rss/>'), \
             patch.object(release, 'verify_feed', side_effect=ValueError('signature failed')), \
             self.assertRaisesRegex(ValueError, 'signature failed'):
            release.previous_feed(self.root, self.args, self.state['config'])

    def test_concurrent_public_feed_change_is_rejected(self):
        with patch.object(release, 'current_feed_hash', return_value='someone-else'), \
             self.assertRaisesRegex(ValueError, 'changed since preparation'):
            release.check_feed_base(self.state, 'desired')
        for current in ['previous', 'desired']:
            with patch.object(release, 'current_feed_hash', return_value=current):
                release.check_feed_base(self.state, 'desired')

    def test_remote_tag_mismatch_never_updates_ref(self):
        class Service:
            def api(inner, path, *args, **kwargs):
                self.assertEqual(path, 'git/ref/tags/v1.3.1')
                self.assertFalse(args)
                return {'object': {'type': 'commit', 'sha': 'b' * 40}}
        with self.assertRaisesRegex(ValueError, 'different commit'):
            release.ensure_tag(Service(), self.state)

    def test_remote_archive_digest_mismatch_blocks_publication(self):
        assets = self.root / 'assets'; assets.mkdir()
        (assets / 'Mimic-1.3.1.zip').write_bytes(b'archive')
        self.state['hashes'] = {'Mimic-1.3.1.zip': release.digest(assets / 'Mimic-1.3.1.zip')}
        remote = {'assets': [{'name': 'Mimic-1.3.1.zip', 'state': 'uploaded', 'size': 7, 'digest': 'sha256:wrong'}]}
        with self.assertRaisesRegex(ValueError, 'SHA-256 differs'):
            release.verify_remote_assets(None, self.state, remote, self.root)

    def test_pages_ref_race_cannot_force_push(self):
        feed = self.root / 'appcast.xml'; feed.write_text('<rss/>')
        mutations = []
        calls = []
        class Service:
            def api(inner, path, method='GET', body=None, **kwargs):
                calls.append(path)
                if path == 'git/ref/heads/gh-pages':
                    return None if calls.count(path) == 1 else {'object': {'sha': 'concurrent'}}
                mutations.append((path, method, body))
                return {'sha': 'fixture-object'}
        with self.assertRaisesRegex(ValueError, 'Concurrent Pages update'):
            release.deploy_feed(Service(), self.root, self.state, feed)
        self.assertFalse(any(path.startswith('git/refs') for path, _, _ in mutations))

    def test_pages_tree_with_unrelated_content_is_preserved(self):
        feed = self.root / 'appcast.xml'; feed.write_text('<rss/>')
        class Service:
            def api(inner, path, *args, **kwargs):
                self.assertFalse(args)
                if path.startswith('git/ref/'):
                    return {'object': {'sha': 'old'}}
                if path.startswith('git/commits/'):
                    return {'tree': {'sha': 'tree'}}
                return {'tree': [{'path': 'unrelated.html', 'sha': 'blob'}]}
        with self.assertRaisesRegex(ValueError, 'unrelated files'):
            release.deploy_feed(Service(), self.root, self.state, feed)

    def test_pages_with_https_enabled_needs_no_certificate_mutation(self):
        class Service:
            def api(inner, path, method='GET', body=None, **kwargs):
                self.assertEqual((path, method), ('pages', 'GET'))
                return {'build_type': 'legacy', 'source': {'branch': 'gh-pages', 'path': '/'}, 'https_enforced': True}
        release.ensure_pages(Service())

    def test_pages_certificate_provisioning_preserves_retryable_error(self):
        class Service:
            def api(inner, path, method='GET', body=None, **kwargs):
                if method == 'PUT':
                    raise RuntimeError('gh: The certificate does not exist yet (HTTP 404)')
                return {'build_type': 'legacy', 'source': {'branch': 'gh-pages', 'path': '/'}, 'https_enforced': False}
        with self.assertRaisesRegex(ValueError, 'after provisioning'):
            release.ensure_pages(Service())

    def test_published_retry_does_not_upload_or_publish_again(self):
        self.state.update(stage='published', hashes={'appcast.xml': 'desired'})
        self.save()
        calls = []
        class Service:
            repository = 'fixture/Mimic'
            def api(inner, path, method='GET', body=None, **kwargs):
                calls.append((path, method, body))
                if path == 'immutable-releases':
                    return {'enabled': True}
                return {'id': 1, 'draft': False, 'immutable': True, 'assets': [], 'html_url': 'https://example.invalid/release'}
            def command(inner, *args):
                self.fail('Retry must not upload archives.')
        with patch.object(release, 'verify_assets'), patch.object(release, 'github', return_value=Service()), \
             patch.object(release, 'ensure_tag'), patch.object(release, 'verify_remote_assets', return_value=set()), \
             patch.object(release, 'current_feed_hash', return_value='desired'), \
             patch.object(release, 'deploy_feed'), patch.object(release, 'ensure_pages'):
            release.publish(self.args)
        self.assertFalse(any(method == 'PATCH' and path.startswith('releases/') for path, method, body in calls))

    def test_changed_local_assets_block_before_signer_access(self):
        assets = self.root / 'assets'; assets.mkdir()
        (assets / 'Mimic.zip').write_bytes(b'changed')
        self.state['hashes'] = {'Mimic.zip': hashlib.sha256(b'original').hexdigest()}
        with patch.object(release, 'run') as run, self.assertRaisesRegex(ValueError, 'asset changed'):
            release.verify_assets(self.root, self.state, self.args)
        run.assert_not_called()

    def test_package_rejects_team_profile(self):
        archive = self.root / 'package.zip'
        with zipfile.ZipFile(archive, 'w') as file:
            file.writestr('Mimic.app/Contents/Resources/private.mimicprofile', b'private')
        with self.assertRaisesRegex(ValueError, 'Private or unsafe'):
            release.verify_package(archive)

    def test_withdraw_preserves_older_item_and_sets_latest_without_deleting(self):
        self.state['stage'] = 'published'
        self.save()
        data = ('<rss xmlns:sparkle="' + release.NS + '"><channel>'
                '<item><sparkle:version>131</sparkle:version><sparkle:shortVersionString>1.3.1</sparkle:shortVersionString></item>'
                '<item><sparkle:version>130</sparkle:version><sparkle:shortVersionString>1.3.0</sparkle:shortVersionString></item>'
                '</channel></rss>').encode()
        calls = []
        class Service:
            def api(inner, path, method='GET', body=None, **kwargs):
                calls.append((path, method, body))
                return {'id': 7}
        def current(state):
            return release.digest(self.root / 'withdrawn-appcast.xml')
        with patch.object(release, 'github', return_value=Service()), patch.object(release, 'fetch', return_value=data), \
             patch.object(release, 'verify_feed'), patch.object(release, 'run'), \
             patch.object(release, 'current_feed_hash', side_effect=current), \
             patch.object(release, 'ensure_pages'), patch.object(release, 'deploy_feed') as deploy:
            release.withdraw(self.args)
        feed = release.ET.parse(self.root / 'withdrawn-appcast.xml')
        self.assertEqual([item.findtext('{' + release.NS + '}version') for item in feed.findall('./channel/item')], ['130'])
        self.assertEqual(calls, [('releases/tags/v1.3.0', 'GET', None), ('releases/7', 'PATCH', {'make_latest': 'true'})])
        self.assertEqual(release.read_state(self.root)['stage'], 'withdrawn')
        deploy.assert_called_once()


if __name__ == '__main__':
    unittest.main()
