#!/usr/bin/env python3
# Created by Василий Маслов on 06.10.2026.
"""Write validated version and update settings before bundle signing."""
import argparse
import base64
import pathlib
import plistlib
import re
from urllib.parse import urlsplit

ROOT = pathlib.Path(__file__).resolve().parent.parent


def load_configuration(path):
    with pathlib.Path(path).open('rb') as file:
        config = plistlib.load(file)
    url = urlsplit(config['feedURL'])
    if url.scheme != 'https' or not url.hostname or url.username or url.password or url.fragment:
        raise ValueError('An HTTPS appcast URL without credentials is required.')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', config['repository']):
        raise ValueError('A public GitHub owner/repository is required.')
    if len(base64.b64decode(config['publicKey'], validate=True)) != 32:
        raise ValueError('A valid Sparkle public Ed25519 key is required.')
    if not config.get('keyAccount'):
        raise ValueError('A Sparkle Keychain account is required.')
    return config


def version():
    with (ROOT / 'Sources/MimicCore/Resources/Version.plist').open('rb') as file:
        value = plistlib.load(file)
    if not re.fullmatch(r'\d+\.\d+\.\d+', value['version']) or not re.fullmatch(r'[1-9]\d*', value['build']):
        raise ValueError('Use a semantic release version and a positive, increasing integer build.')
    return value


def configure(app, config_path):
    config = load_configuration(config_path)
    value = version()
    path = pathlib.Path(app) / 'Contents/Info.plist'
    with path.open('rb') as file:
        metadata = plistlib.load(file)
    metadata.update(CFBundleVersion=value['build'], CFBundleShortVersionString=value['version'],
                    SUFeedURL=config['feedURL'], SUPublicEDKey=config['publicKey'],
                    SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=False, SUScheduledCheckInterval=3600,
                    SUEnableSystemProfiling=False, SUVerifyUpdateBeforeExtraction=True,
                    SURequireSignedFeed=True, SUSignedFeedFailureExpirationInterval=0,
                    MimicRefreshPluginOnLaunch=True)
    with path.open('wb') as file:
        plistlib.dump(metadata, file)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=pathlib.Path)
    parser.add_argument('--config', type=pathlib.Path, default=ROOT / 'Distribution/Updates.plist')
    parser.add_argument('--version', action='store_true')
    args = parser.parse_args()
    if args.version:
        print(version()['version'])
    elif args.app:
        configure(args.app, args.config)
    else:
        parser.error('--app or --version is required')


if __name__ == '__main__':
    main()
