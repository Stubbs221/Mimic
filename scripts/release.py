#!/usr/bin/env python3
# Created by Василий Маслов on 08.10.2026.
"""Local releases: prepare/resume never publish; publish and withdraw are explicit operations."""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request
import uuid
import xml.etree.ElementTree as ET
import zipfile
from contextlib import contextmanager
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parent.parent
NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
VERSION_PATH = 'Sources/MimicCore/Resources/Version.plist'
CONFIG_PATH = 'Distribution/Updates.plist'
ET.register_namespace('sparkle', NS)


def run(*args, cwd=None, env=None):
    return subprocess.run([str(arg) for arg in args], cwd=cwd, env=env, check=True,
                          capture_output=True, text=True).stdout.strip()


def digest(path):
    value = hashlib.sha256()
    with pathlib.Path(path).open('rb') as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def save(directory, state):
    """Atomically persist every completed external step, without credentials."""
    state['updatedAt'] = datetime.now(timezone.utc).isoformat()
    pending = directory / 'state.json.tmp'
    with pending.open('w') as file:
        json.dump(state, file, indent=2, ensure_ascii=False)
        file.flush()
        os.fsync(file.fileno())
    pending.replace(directory / 'state.json')


@contextmanager
def lock():
    directory = ROOT / '.local'
    directory.mkdir(exist_ok=True)
    with (directory / 'release.lock').open('a') as file:
        try:
            fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('Another local release operation is running.')
        yield


def fetch(url):
    if not url.startswith('https://'):
        raise ValueError('Public release downloads require HTTPS.')
    request = urllib.request.Request(url, headers={'Cache-Control': 'no-cache', 'User-Agent': 'Mimic-release'})
    with urllib.request.urlopen(request, timeout=60) as response:
        if not response.geturl().startswith('https://'):
            raise ValueError('An HTTPS download redirected to an insecure URL.')
        return response.read()


class GitHub:
    """Use the existing gh login; never extract its token or install a CLI automatically."""
    def __init__(self, executable, repository):
        self.executable = executable
        self.repository = repository

    def command(self, *args):
        return run(self.executable, *args)

    def api(self, path, method='GET', body=None, missing=False):
        args = [self.executable, 'api', 'repos/' + self.repository + '/' + path,
                '--method', method, '-H', 'X-GitHub-Api-Version: 2026-03-10']
        data = None
        if body is not None:
            args += ['--input', '-']
            data = json.dumps(body)
        result = subprocess.run(args, input=data, capture_output=True, text=True)
        if result.returncode:
            if missing and '(HTTP 404)' in result.stderr:
                return None
            raise RuntimeError('GitHub API failed: ' + result.stderr.strip())
        return json.loads(result.stdout) if result.stdout.strip() else {}


def github(args, state):
    executable = args.gh or shutil.which('gh')
    if not executable:
        raise ValueError('GitHub CLI is required; pass --gh /absolute/path/to/gh or add it to PATH.')
    return GitHub(executable, state['config']['repository'])


def tools(args):
    return args.sparkle_tools.resolve()


def verify_feed(path, args, config):
    run(tools(args) / 'sign_update', '--account', config['keyAccount'], '--verify', path)
    root = ET.parse(path)
    builds = [int(item.findtext('{' + NS + '}version')) for item in root.findall('./channel/item')]
    if len(builds) != len(set(builds)):
        raise ValueError('The previous feed contains duplicate builds.')
    return builds


def previous_feed(directory, args, config, first=False):
    path = directory / 'previous-appcast.xml'
    try:
        data = fetch(config['feedURL'])
    except urllib.error.HTTPError as error:
        if not first or error.code != 404:
            raise
        return None
    path.write_bytes(data)
    verify_feed(path, args, config)
    if first:
        raise ValueError('--first-release requires an absent public feed.')
    return digest(path)


def snapshot(ref, directory):
    """Export only committed public files; never reset or stash the developer's checkout."""
    sha = run('git', 'rev-parse', '--verify', ref + '^{commit}', cwd=ROOT)
    directory.mkdir()
    archive = directory.parent / 'source.tar'
    with archive.open('wb') as file:
        subprocess.run(['git', 'archive', sha], cwd=ROOT, stdout=file, check=True)
    with tarfile.open(archive) as tar:
        # A source snapshot must not install links outside its own tree.
        for member in tar.getmembers():
            target = (directory / member.name).resolve()
            if directory.resolve() not in target.parents or member.issym() or member.islnk():
                raise ValueError('Unsafe source archive entry: ' + member.name)
        tar.extractall(directory)
    archive.unlink()
    return sha


def validate_app(app, version, config):
    """Reject a mismatched or ad hoc bundle before sending anything to Apple."""
    with (app / 'Contents/Info.plist').open('rb') as file:
        info = plistlib.load(file)
    expected = {'CFBundleIdentifier': 'local.vmaslov.Mimic', 'CFBundleVersion': version['build'],
                'CFBundleShortVersionString': version['version'], 'SUFeedURL': config['feedURL'],
                'SUPublicEDKey': config['publicKey']}
    if any(info.get(key) != value for key, value in expected.items()):
        raise ValueError('The app must match the pinned version, identity, feed and Sparkle key.')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', app)
    result = subprocess.run(['/usr/bin/codesign', '-dv', '--verbose=4', str(app)],
                            capture_output=True, text=True, check=True)
    if 'Authority=Developer ID Application:' not in result.stderr or 'runtime)' not in result.stderr:
        raise ValueError('Developer ID with hardened runtime is required before notarization.')


def verify_package(path):
    """Keep team profiles and signing material out of both public ZIPs."""
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        for name in names:
            parts = pathlib.PurePosixPath(name).parts
            base = pathlib.PurePosixPath(name).name.lower()
            if '..' in parts or name.startswith('/') or base == 'profile.json' or base.endswith(('.mimicprofile', '.p12', '.pfx', '.pem', '.key')):
                raise ValueError('Private or unsafe package entry: ' + name)
        if not any(name.endswith('/Mimic.app/Contents/Info.plist') or name == 'Mimic.app/Contents/Info.plist' for name in names):
            raise ValueError('The ZIP does not contain Mimic.app.')
        if not any(name.endswith('/Contents/Resources/LICENSE') for name in names):
            raise ValueError('The app ZIP is missing its license.')


def prepare(args):
    directory = args.release_dir.resolve()
    if ROOT == directory or ROOT in directory.parents:
        raise ValueError('Keep release state and packages outside the repository.')
    directory.mkdir(parents=True, exist_ok=False)
    source = directory / 'source'
    sha = snapshot(args.ref, source)
    with (source / VERSION_PATH).open('rb') as file:
        version = plistlib.load(file)
    with (source / CONFIG_PATH).open('rb') as file:
        config = plistlib.load(file)
    shutil.copy2(args.notes, directory / 'ReleaseNotes.md')
    shutil.copy2(args.acceptance, directory / 'Acceptance.md')
    state = dict(schema=1, commit=sha, version=version['version'], build=version['build'],
                 tag='v' + version['version'], config=config, stage='created',
                 acceptanceSHA256=digest(directory / 'Acceptance.md'),
                 firstRelease=args.first_release, submissionID=args.submission_id,
                 keychainProfile=args.keychain_profile)
    save(directory, state)
    service = github(args, state)
    if service.api('releases/tags/' + state['tag'], missing=True):
        raise ValueError('This version already has a GitHub Release; choose a new version/build.')
    if args.first_release and service.api('releases?per_page=1'):
        raise ValueError('The repository already has releases; omit --first-release.')
    state['previousFeedSHA256'] = previous_feed(directory, args, config, args.first_release)
    if state['previousFeedSHA256'] and int(state['build']) <= max(verify_feed(directory / 'previous-appcast.xml', args, config), default=0):
        raise ValueError('The release build must exceed all published builds.')
    if pathlib.Path('/Applications/Mimic.app/Contents/Info.plist').exists() and not args.app:
        with pathlib.Path('/Applications/Mimic.app/Contents/Info.plist').open('rb') as file:
            installed = plistlib.load(file)
        if int(state['build']) <= int(installed['CFBundleVersion']):
            raise ValueError('A newly built release must exceed the installed development build.')
    if args.app:
        run('/usr/bin/ditto', args.app.resolve(), directory / 'Mimic.app')
    else:
        env = dict(os.environ, MIMIC_APP_PATH=str(directory / 'Mimic.app'),
                   MIMIC_DISTRIBUTION_PATH=str(directory / ('MimicSetup-' + state['version'])),
                   MIMIC_BUILD_PATH=str(directory / 'build'), MIMIC_BUILD_SYSTEM='native')
        print('Building pinned source ' + sha, flush=True)
        subprocess.run(['bash', str(source / 'scripts/build-app.sh'), '--release', '--no-install'], env=env, check=True)
    validate_app(directory / 'Mimic.app', version, config)
    state['stage'] = 'built'
    save(directory, state)
    resume(args)


def read_state(directory):
    state = json.loads((directory / 'state.json').read_text())
    if state.get('schema') != 1:
        raise ValueError('Unsupported release state format.')
    return state


def qualify(directory, state, args):
    """Package only the pinned version, with the current release tooling and original setup resources."""
    spec = importlib.util.spec_from_file_location('mimic_prepare_release', ROOT / 'scripts/prepare-release.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    output = directory / 'assets'
    # Incomplete packaging is disposable; a sealed set is never regenerated.
    if output.exists():
        shutil.rmtree(output)
    previous = directory / 'previous-appcast.xml'
    module.prepare(argparse.Namespace(app=directory / 'Mimic.app', config=directory / 'source' / CONFIG_PATH,
                                     source_root=directory / 'source', sparkle_tools=tools(args),
                                     previous_appcast=previous if previous.exists() else None,
                                     notarize=False, output=output, notes=directory / 'ReleaseNotes.md'))
    names = ['Mimic-' + state['version'] + '.zip', 'MimicSetup-' + state['version'] + '.zip']
    for name in names:
        verify_package(output / name)
    (output / 'SHA256SUMS').write_text(''.join(digest(output / name) + '  ' + name + '\n' for name in names))
    shutil.copy2(directory / 'ReleaseNotes.md', output / 'ReleaseNotes.md')
    state['hashes'] = {name: digest(output / name) for name in names + ['SHA256SUMS', 'appcast.xml', 'ReleaseNotes.md']}
    state['stage'] = 'prepared'
    save(directory, state)


def resume(args):
    directory = args.release_dir.resolve()
    state = read_state(directory)
    if state['stage'] in ('prepared', 'published', 'withdrawn'):
        verify_assets(directory, state, args)
        print('Already ' + state['stage'] + ': ' + str(directory))
        return
    if state['stage'] not in ('built', 'submitting', 'submitted'):
        raise ValueError('Preparation did not finish building; use a new directory after correcting the error.')
    if args.submission_id:
        if state.get('submissionID') and state['submissionID'] != args.submission_id:
            raise ValueError('Cannot replace an existing Apple submission ID.')
        state['submissionID'] = args.submission_id
        save(directory, state)
    if not state.get('submissionID'):
        if state['stage'] == 'submitting':
            raise ValueError('Submission outcome unknown. Check notarytool history and resume with --submission-id; do not resend.')
        if not state.get('keychainProfile'):
            raise ValueError('A Keychain notary profile is required.')
        # Persist intent before the network operation. A lost reply must never cause a duplicate submission.
        archive = directory / ('Notary-' + str(uuid.uuid4()) + '.zip')
        run('/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', directory / 'Mimic.app', archive)
        state.update(stage='submitting', submissionArchive=archive.name)
        save(directory, state)
        result = json.loads(run('/usr/bin/xcrun', 'notarytool', 'submit', archive,
                                '--keychain-profile', state['keychainProfile'], '--output-format', 'json'))
        state.update(submissionID=result['id'], stage='submitted')
        save(directory, state)
    result = json.loads(run('/usr/bin/xcrun', 'notarytool', 'info', state['submissionID'],
                            '--keychain-profile', state['keychainProfile'], '--output-format', 'json'))
    state['notaryStatus'] = result['status']
    save(directory, state)
    if result['status'] == 'In Progress':
        print('Apple is processing ' + state['submissionID'] + '. Run resume later; no new submission is needed.')
        return
    if result['status'] != 'Accepted':
        raise ValueError('Apple did not accept the submission: ' + result['status'])
    run('/usr/bin/xcrun', 'stapler', 'staple', directory / 'Mimic.app')
    qualify(directory, state, args)
    print('Prepared; publication requires a separate publish command: ' + str(directory))


def verify_assets(directory, state, args):
    if not state.get('hashes'):
        raise ValueError('The release has not been qualified.')
    for name, expected in state['hashes'].items():
        if pathlib.Path(name).name != name or digest(directory / 'assets' / name) != expected:
            raise ValueError('Prepared asset changed: ' + name)
    if digest(directory / 'Acceptance.md') != state['acceptanceSHA256']:
        raise ValueError('The acceptance report changed after preparation.')
    feed = directory / 'assets/appcast.xml'
    verify_feed(feed, args, state['config'])
    item = ET.parse(feed).find('./channel/item')
    if item.findtext('{' + NS + '}version') != state['build']:
        raise ValueError('The feed build does not match the release.')
    enclosure = item.find('enclosure')
    name = 'Mimic-' + state['version'] + '.zip'
    expected_url = 'https://github.com/' + state['config']['repository'] + '/releases/download/' + state['tag'] + '/' + name
    if enclosure.get('url') != expected_url or int(enclosure.get('length')) != (directory / 'assets' / name).stat().st_size:
        raise ValueError('The feed does not target the exact qualified archive.')
    run(tools(args) / 'sign_update', '--account', state['config']['keyAccount'], '--verify',
        directory / 'assets' / name, enclosure.get('{' + NS + '}edSignature'))


def current_feed_hash(state):
    try:
        return hashlib.sha256(fetch(state['config']['feedURL'])).hexdigest()
    except urllib.error.HTTPError as error:
        if error.code == 404 and state['firstRelease']:
            return None
        raise


def check_feed_base(state, desired_hash):
    current = current_feed_hash(state)
    if current not in (state['previousFeedSHA256'], desired_hash):
        raise ValueError('The public feed changed since preparation; reconcile before publishing.')


def ensure_tag(service, state):
    ref = service.api('git/ref/tags/' + state['tag'], missing=True)
    if ref:
        value = ref['object']
        while value['type'] == 'tag':
            value = service.api('git/tags/' + value['sha'])['object']
        if value['type'] != 'commit' or value['sha'] != state['commit']:
            raise ValueError('The remote tag points to a different commit.')
    else:
        service.api('git/refs', 'POST', {'ref': 'refs/tags/' + state['tag'], 'sha': state['commit']})


def verify_remote_assets(service, state, release, directory, public=False):
    expected = {name: value for name, value in state['hashes'].items() if name != 'appcast.xml'}
    assets = {asset['name']: asset for asset in release['assets']}
    if set(assets) - set(expected):
        raise ValueError('The release contains unexpected assets.')
    for name, asset in assets.items():
        if asset['state'] != 'uploaded' or asset['size'] != (directory / 'assets' / name).stat().st_size:
            raise ValueError('Incomplete remote asset: ' + name)
        if asset.get('digest') != 'sha256:' + expected[name]:
            raise ValueError('Remote asset SHA-256 differs: ' + name)
        if public and hashlib.sha256(fetch(asset['browser_download_url'])).hexdigest() != expected[name]:
            raise ValueError('Public download differs: ' + name)
    return set(expected) - set(assets)


def deploy_feed(service, directory, state, feed):
    """CAS-update a dedicated public-only Pages tree; never push developer branches or force-push."""
    ref = service.api('git/ref/heads/gh-pages', missing=True)
    previous = ref['object']['sha'] if ref else None
    entries = {}
    if previous:
        commit = service.api('git/commits/' + previous)
        tree = service.api('git/trees/' + commit['tree']['sha'] + '?recursive=1')
        if tree.get('truncated'):
            raise ValueError('Pages tree is truncated.')
        entries = {entry['path']: entry for entry in tree['tree']}
        if set(entries) - {'appcast.xml', '.nojekyll'}:
            raise ValueError('gh-pages contains unrelated files; refusing to replace it.')
        old_feed = entries.get('appcast.xml')
        if old_feed:
            import base64
            content = service.api('git/blobs/' + old_feed['sha'])
            existing = base64.b64decode(content['content'])
            if existing == feed.read_bytes():
                return
            if hashlib.sha256(existing).hexdigest() != state['previousFeedSHA256']:
                raise ValueError('The gh-pages branch changed since preparation.')
    blob = service.api('git/blobs', 'POST', {'content': feed.read_text(), 'encoding': 'utf-8'})
    marker = '# Created by Василий Маслов on ' + datetime.now().astimezone().strftime('%d.%m.%Y') + '.\n'
    empty = service.api('git/blobs', 'POST', {'content': marker, 'encoding': 'utf-8'})
    tree = service.api('git/trees', 'POST', {'tree': [
        {'path': 'appcast.xml', 'mode': '100644', 'type': 'blob', 'sha': blob['sha']},
        {'path': '.nojekyll', 'mode': '100644', 'type': 'blob', 'sha': empty['sha']}]})
    commit = service.api('git/commits', 'POST', {'message': 'Publish Mimic update feed ' + state['tag'],
                                              'tree': tree['sha'], 'parents': [previous] if previous else []})
    latest = service.api('git/ref/heads/gh-pages', missing=True)
    if (latest['object']['sha'] if latest else None) != previous:
        raise ValueError('Concurrent Pages update detected; no branch was changed.')
    if previous:
        service.api('git/refs/heads/gh-pages', 'PATCH', {'sha': commit['sha'], 'force': False})
    else:
        service.api('git/refs', 'POST', {'ref': 'refs/heads/gh-pages', 'sha': commit['sha']})


def ensure_pages(service):
    pages = service.api('pages', missing=True)
    if pages:
        if pages.get('build_type') != 'legacy' or pages.get('source') != {'branch': 'gh-pages', 'path': '/'}:
            raise ValueError('Pages already uses a different publishing source.')
    else:
        service.api('pages', 'POST', {'build_type': 'legacy', 'source': {'branch': 'gh-pages', 'path': '/'}})
        pages = service.api('pages')
    if not pages.get('https_enforced'):
        try:
            service.api('pages', 'PUT', {'https_enforced': True})
        except RuntimeError as error:
            if 'certificate does not exist yet' in str(error):
                raise ValueError('Pages HTTPS certificate is not ready. Run the same command after provisioning; archives are unchanged.')
            raise


def publish(args):
    directory = args.release_dir.resolve()
    state = read_state(directory)
    if state['stage'] not in ('prepared', 'published'):
        raise ValueError('Only a qualified, non-withdrawn release can be published.')
    verify_assets(directory, state, args)
    service = github(args, state)
    desired = state['hashes']['appcast.xml']
    check_feed_base(state, desired)
    # This operation is intentionally separate from prepare/resume.
    service.api('immutable-releases', 'PUT')
    if not service.api('immutable-releases').get('enabled'):
        raise ValueError('GitHub release immutability is not enabled.')
    ensure_tag(service, state)
    release = service.api('releases/tags/' + state['tag'], missing=True)
    if not release:
        release = service.api('releases', 'POST', dict(tag_name=state['tag'], target_commitish=state['commit'],
                              name='Mimic ' + state['version'], body=(directory / 'assets/ReleaseNotes.md').read_text(),
                              draft=True, prerelease=False))
    missing = verify_remote_assets(service, state, release, directory)
    if missing:
        if not release['draft']:
            raise ValueError('Published release is missing assets; never repair it by replacing files.')
        service.command('release', 'upload', state['tag'], *[str(directory / 'assets' / name) for name in sorted(missing)],
                        '--repo', service.repository)
    release = service.api('releases/' + str(release['id']))
    if verify_remote_assets(service, state, release, directory):
        raise ValueError('Draft assets are incomplete.')
    ensure_tag(service, state)
    if release['draft']:
        service.api('releases/' + str(release['id']), 'PATCH', {'draft': False, 'make_latest': 'true'})
    release = service.api('releases/' + str(release['id']))
    if not release.get('immutable'):
        raise ValueError('The published release is not immutable; feed was not changed.')
    verify_remote_assets(service, state, release, directory, public=True)
    state['releaseURL'] = release['html_url']
    save(directory, state)
    check_feed_base(state, desired)
    deploy_feed(service, directory, state, directory / 'assets/appcast.xml')
    ensure_pages(service)
    if current_feed_hash(state) != desired:
        raise ValueError('Pages deployment is pending or differs. Run publish again after deployment; archives will be reused.')
    state['stage'] = 'published'
    save(directory, state)
    print('Published and verified: ' + state['releaseURL'])


def withdraw(args):
    directory = args.release_dir.resolve()
    state = read_state(directory)
    service = github(args, state)
    if state['stage'] not in ('prepared', 'published', 'withdrawn'):
        raise ValueError('This release has not been prepared.')
    pending = directory / 'withdrawal.json'
    feed = directory / 'withdrawn-appcast.xml'
    if pending.exists():
        change = json.loads(pending.read_text())
    else:
        previous = directory / 'withdrawal-previous.xml'
        previous.write_bytes(fetch(state['config']['feedURL']))
        verify_feed(previous, args, state['config'])
        tree = ET.parse(previous)
        channel = tree.find('./channel')
        matching = [item for item in channel.findall('item') if item.findtext('{' + NS + '}version') == state['build']]
        if not matching:
            raise ValueError('This build is absent from the public feed.')
        for item in matching:
            channel.remove(item)
        tree.getroot().insert(0, ET.Comment(' Created by Василий Маслов on ' + datetime.now().astimezone().strftime('%d.%m.%Y') + '. '))
        tree.write(feed, encoding='utf-8', xml_declaration=True)
        run(tools(args) / 'sign_update', '--account', state['config']['keyAccount'], feed)
        change = {'previousFeedSHA256': digest(previous), 'desiredSHA256': digest(feed)}
        pending.write_text(json.dumps(change))
    verify_feed(feed, args, state['config'])
    if digest(feed) != change['desiredSHA256']:
        raise ValueError('The prepared withdrawal feed changed.')
    changed = dict(state, previousFeedSHA256=change['previousFeedSHA256'])
    check_feed_base(changed, change['desiredSHA256'])
    deploy_feed(service, directory, changed, feed)
    ensure_pages(service)
    remaining = ET.parse(feed).findall('./channel/item')
    if remaining:
        newest = max(remaining, key=lambda item: int(item.findtext('{' + NS + '}version')))
        tag = 'v' + newest.findtext('{' + NS + '}shortVersionString')
        release = service.api('releases/tags/' + tag)
        service.api('releases/' + str(release['id']), 'PATCH', {'make_latest': 'true'})
    else:
        # There is no earlier good release for the first publication.
        release = service.api('releases/tags/' + state['tag'])
        service.api('releases/' + str(release['id']), 'PATCH', {'prerelease': True, 'make_latest': 'false'})
    if current_feed_hash(changed) != change['desiredSHA256']:
        raise ValueError('Withdrawal Pages deployment is pending; run withdraw again later.')
    state['stage'] = 'withdrawn'
    save(directory, state)
    print('Withdrawn from the feed. Already installed copies require a higher-build hotfix.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gh', help='Path to an already authenticated GitHub CLI')
    parser.add_argument('--sparkle-tools', type=pathlib.Path, default=ROOT / '.build/artifacts/sparkle/Sparkle/bin')
    commands = parser.add_subparsers(dest='command', required=True)
    preparing = commands.add_parser('prepare', help='Build/notarize a specified commit; never publish')
    preparing.add_argument('--ref', required=True, help='Commit or ref; resolved once to an exact SHA')
    preparing.add_argument('--release-dir', type=pathlib.Path, required=True)
    preparing.add_argument('--notes', type=pathlib.Path, required=True, help='Reviewed public release notes')
    preparing.add_argument('--acceptance', type=pathlib.Path, required=True, help='Reviewed private acceptance report')
    preparing.add_argument('--app', type=pathlib.Path, help='Adopt an existing signed app without rebuilding')
    preparing.add_argument('--submission-id', help='Reuse the Apple submission for that exact app')
    preparing.add_argument('--keychain-profile', required=True)
    preparing.add_argument('--first-release', action='store_true', help='Allow an absent feed only for an empty releases repository')
    for name in ['resume', 'publish', 'withdraw']:
        command = commands.add_parser(name)
        command.add_argument('--release-dir', type=pathlib.Path, required=True)
        if name == 'resume':
            command.add_argument('--submission-id', help='Recover the existing ID after a lost submission response')
    args = parser.parse_args()
    try:
        with lock():
            globals()[args.command](args)
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError, ET.ParseError, KeyError) as error:
        # Command output can include private paths; keep the report outside the public release assets.
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
