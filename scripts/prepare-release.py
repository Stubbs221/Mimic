#!/usr/bin/env python3
# Created by Василий Маслов on 06.10.2026.
"""Qualify an already signed app and prepare immutable, signed GitHub release assets. Never publishes."""
import argparse
import copy
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import format_datetime
from importlib.util import module_from_spec, spec_from_file_location

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = spec_from_file_location('metadata', ROOT / 'scripts/build-metadata.py')
metadata = module_from_spec(spec)
spec.loader.exec_module(metadata)
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE)


def run(*arguments):
    return subprocess.run([str(arg) for arg in arguments], check=True, capture_output=True, text=True).stdout.strip()


def appcast(config, version, build, archive, signature, previous=None, notes=None):
    if previous:
        old = ET.parse(previous)
        builds = [int(node.text) for node in old.findall('.//{' + SPARKLE + '}version')]
        if builds and int(build) <= max(builds):
            raise ValueError('The release build must exceed every previously published build.')
    rss = ET.Element('rss', version='2.0')
    rss.append(ET.Comment(' Created by Василий Маслов on ' + datetime.now().astimezone().strftime('%d.%m.%Y') + '. '))
    channel = ET.SubElement(rss, 'channel')
    ET.SubElement(channel, 'title').text = 'Mimic'
    ET.SubElement(channel, 'link').text = 'https://github.com/' + config['repository']
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = 'Mimic ' + version
    if notes:
        ET.SubElement(item, 'description', **{'{' + SPARKLE + '}format': 'plain-text'}).text = notes
    ET.SubElement(item, 'pubDate').text = format_datetime(datetime.now(timezone.utc), usegmt=True)
    ET.SubElement(item, '{' + SPARKLE + '}version').text = build
    ET.SubElement(item, '{' + SPARKLE + '}shortVersionString').text = version
    ET.SubElement(item, '{' + SPARKLE + '}minimumSystemVersion').text = '14.0.0'
    ET.SubElement(item, '{' + SPARKLE + '}hardwareRequirements').text = 'arm64'
    ET.SubElement(item, 'enclosure', url='https://github.com/' + config['repository'] + '/releases/download/v' + version + '/' + archive.name,
                  length=str(archive.stat().st_size), type='application/octet-stream', **{'{' + SPARKLE + '}edSignature': signature})
    if previous:
        for older in old.findall('./channel/item'):
            channel.append(copy.deepcopy(older))
    ET.indent(rss)
    return ET.ElementTree(rss)


def prepare(args):
    # The release may target an older commit while the working checkout already contains the next version.
    global ROOT
    if getattr(args, 'source_root', None):
        ROOT = args.source_root.resolve()
        metadata.ROOT = ROOT
    app = args.app.resolve()
    config = metadata.load_configuration(args.config)
    value = metadata.version()
    with (app / 'Contents/Info.plist').open('rb') as file:
        info = plistlib.load(file)
    if (info.get('CFBundleIdentifier'), info.get('CFBundleVersion'), info.get('CFBundleShortVersionString')) != ('local.vmaslov.Mimic', value['build'], value['version']):
        raise ValueError('The bundle must match the current version source and Mimic identity.')
    if info.get('SUFeedURL') != config['feedURL'] or info.get('SUPublicEDKey') != config['publicKey']:
        raise ValueError('The app must contain the selected appcast URL and public key.')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    signed = subprocess.run(['/usr/bin/codesign', '-dv', '--verbose=4', str(app)], capture_output=True, text=True, check=True).stderr
    if 'Authority=Developer ID Application:' not in signed or 'runtime)' not in signed:
        raise ValueError('A Developer ID Application signature with hardened runtime is required.')
    for executable in [app / 'Contents/MacOS/Mimic', *sorted((app / 'Contents/Helpers').iterdir())]:
        if run('/usr/bin/lipo', '-archs', executable) != 'arm64':
            raise ValueError('The first stable release must contain Apple Silicon executables only.')
    tools = args.sparkle_tools.resolve()
    if args.previous_appcast:
        run(tools / 'sign_update', '--account', config['keyAccount'], '--verify', args.previous_appcast)
    if run(tools / 'generate_keys', '--account', config['keyAccount'], '-p') != config['publicKey']:
        raise ValueError('The selected Keychain account must match the app public key.')
    if args.notarize:
        if not args.keychain_profile:
            raise ValueError('--notarize requires --keychain-profile; credentials remain in Keychain.')
        with tempfile.TemporaryDirectory(prefix='MimicNotarize-') as directory:
            archive = pathlib.Path(directory) / 'Mimic.zip'
            run('/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, archive)
            run('/usr/bin/xcrun', 'notarytool', 'submit', archive, '--keychain-profile', args.keychain_profile, '--wait')
        run('/usr/bin/xcrun', 'stapler', 'staple', app)
    # A signature alone cannot qualify a download for colleagues.
    run('/usr/bin/xcrun', 'stapler', 'validate', app)
    run('/usr/sbin/spctl', '--assess', '--type', 'execute', app)
    if args.output.exists():
        raise ValueError('Use a new output directory; prepared release assets are never overwritten.')
    args.output.mkdir(parents=True)
    archive = args.output / ('Mimic-' + value['version'] + '.zip')
    run('/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, archive)
    setup = args.output / ('MimicSetup-' + value['version'])
    setup.mkdir()
    run('/usr/bin/ditto', app, setup / 'Mimic.app')
    for source, name in [('scripts/setup-mimic.command', 'setup-mimic.command'), ('scripts/setup-mimic.ru.plist', 'setup-mimic.ru.plist'), ('docs/MimicSetup.md', 'README.md'), ('docs/AgentChecks.md', 'AgentChecks.md'), ('LICENSE', 'LICENSE')]:
        shutil.copy2(ROOT / source, setup / name)
    run('/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', setup, pathlib.Path(str(setup) + '.zip'))
    signature = run(tools / 'sign_update', '--account', config['keyAccount'], '-p', archive)
    feed = args.output / 'appcast.xml'
    notes = args.notes.read_text() if getattr(args, 'notes', None) else None
    appcast(config, value['version'], value['build'], archive, signature, args.previous_appcast, notes).write(feed, encoding='utf-8', xml_declaration=True)
    run(tools / 'sign_update', '--account', config['keyAccount'], feed)
    run(tools / 'sign_update', '--account', config['keyAccount'], '--verify', archive, signature)
    run(tools / 'sign_update', '--account', config['keyAccount'], '--verify', feed)
    print('Prepared:', args.output)
    print('Publish ZIP assets to tag v' + value['version'] + ' first; publish the signed appcast to GitHub Pages only after asset URLs work.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--config', type=pathlib.Path, default=ROOT / 'Distribution/Updates.plist')
    parser.add_argument('--sparkle-tools', type=pathlib.Path, default=ROOT / '.build/artifacts/sparkle/Sparkle/bin')
    parser.add_argument('--previous-appcast', type=pathlib.Path)
    parser.add_argument('--source-root', type=pathlib.Path, help='Pinned source snapshot supplying version and setup resources')
    parser.add_argument('--notes', type=pathlib.Path, help='Public release notes embedded in the signed feed')
    parser.add_argument('--notarize', action='store_true')
    parser.add_argument('--keychain-profile')
    args = parser.parse_args()
    try:
        prepare(args)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
