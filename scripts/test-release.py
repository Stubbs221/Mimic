#!/usr/bin/env python3
# Created by Василий Маслов on 06.10.2026.
"""Targeted release metadata checks; no Keychain, Apple service or GitHub calls."""
import importlib.util
import pathlib
import plistlib
import tempfile
import unittest


def load(name):
    spec = importlib.util.spec_from_file_location(name, pathlib.Path(__file__).with_name(name + '.py'))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


release = load('prepare-release')
metadata = release.metadata


class ReleaseTests(unittest.TestCase):
    def test_bundle_has_exact_shared_version_and_signed_feed(self):
        with tempfile.TemporaryDirectory() as directory:
            app = pathlib.Path(directory) / 'Mimic.app'
            (app / 'Contents').mkdir(parents=True)
            with (app / 'Contents/Info.plist').open('wb') as file:
                plistlib.dump({'CFBundleIdentifier': 'fixture'}, file)
            metadata.configure(app, metadata.ROOT / 'Distribution/Updates.plist')
            with (app / 'Contents/Info.plist').open('rb') as file:
                info = plistlib.load(file)
            self.assertEqual(info['CFBundleVersion'], metadata.version()['build'])
            self.assertEqual(info['CFBundleShortVersionString'], metadata.version()['version'])
            self.assertEqual(info['SUScheduledCheckInterval'], 3600)
            self.assertTrue(info['SURequireSignedFeed'])
            self.assertTrue(info['SUVerifyUpdateBeforeExtraction'])
            self.assertFalse(info['SUAutomaticallyUpdate'])

    def test_configuration_rejects_unsafe_or_incomplete_feed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'Updates.plist'
            original = metadata.load_configuration(metadata.ROOT / 'Distribution/Updates.plist')
            for field, value in [('feedURL', 'http://example.invalid/feed'), ('feedURL', 'https://secret@example.invalid/feed'),
                                 ('publicKey', 'bad'), ('repository', 'missing-owner'), ('keyAccount', '')]:
                config = dict(original); config[field] = value
                with path.open('wb') as file:
                    plistlib.dump(config, file)
                with self.assertRaises((ValueError, TypeError)):
                    metadata.load_configuration(path)

    def test_feed_targets_immutable_release_and_rejects_repeated_build(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory); archive = root / 'Mimic-1.3.0.zip'; archive.write_bytes(b'fixture')
            config = metadata.load_configuration(metadata.ROOT / 'Distribution/Updates.plist')
            feed = release.appcast(config, '1.3.0', '130', archive, 'fixture-signature')
            enclosure = feed.find('.//enclosure')
            self.assertEqual(enclosure.attrib['url'], 'https://github.com/Stubbs221/Mimic/releases/download/v1.3.0/Mimic-1.3.0.zip')
            self.assertEqual(enclosure.attrib['length'], '7')
            self.assertEqual(feed.find('.//{' + release.SPARKLE + '}hardwareRequirements').text, 'arm64')
            prior = root / 'appcast.xml'; feed.write(prior)
            for build in ['129', '130']:
                with self.assertRaises(ValueError):
                    release.appcast(config, '1.3.1', build, archive, 'fixture-signature', prior)
            release.appcast(config, '1.3.1', '131', archive, 'fixture-signature', prior)


if __name__ == '__main__':
    unittest.main()
