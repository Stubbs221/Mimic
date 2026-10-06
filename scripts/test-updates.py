#!/usr/bin/env python3
# Created by Василий Маслов on 06.10.2026.
"""Exercise real Sparkle replacement in disposable DEBUG apps, using only a synthetic signing key."""
import argparse
import base64
import functools
import http.server
import json
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parent.parent
PRODUCTS = ROOT / '.build/arm64-apple-macosx/debug'
SIGN = ROOT / '.build/artifacts/sparkle/Sparkle/bin/sign_update'
NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', NS)


def run(*args):
    return subprocess.run([str(a) for a in args], check=True, capture_output=True, text=True).stdout.strip()


class QuietServer(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def bundle(app, feed, key, build):
    contents = app / 'Contents'
    for directory in ['MacOS', 'Helpers', 'Resources', 'Frameworks']:
        (contents / directory).mkdir(parents=True)
    shutil.copy2(PRODUCTS / 'Mimic', contents / 'MacOS/Mimic')
    for helper in ['TaskHost', 'MimicMCP', 'MimicCLI']:
        shutil.copy2(PRODUCTS / helper, contents / 'Helpers' / helper)
    for name in ['Mimic_Mimic', 'Mimic_MimicCore', 'Mimic_MimicMCP', 'SwiftTerm_SwiftTerm', 'ZIPFoundation_ZIPFoundation']:
        run('/usr/bin/ditto', PRODUCTS / (name + '.bundle'), contents / 'Resources' / (name + '.bundle'))
    run('/usr/bin/ditto', PRODUCTS / 'Sparkle.framework', contents / 'Frameworks/Sparkle.framework')
    with (contents / 'Info.plist').open('wb') as file:
        plistlib.dump(dict(CFBundleExecutable='Mimic', CFBundleIdentifier='local.vmaslov.MimicUpdateFixture',
                          CFBundleName='Mimic Update Fixture', CFBundlePackageType='APPL', CFBundleVersion=str(build),
                          CFBundleShortVersionString='1.3.' + str(build - 130), LSMinimumSystemVersion='14.0', LSUIElement=True,
                          NSPrincipalClass='NSApplication', SUFeedURL=feed, SUPublicEDKey=key,
                          SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=False, SUVerifyUpdateBeforeExtraction=True,
                          SURequireSignedFeed=True, SUScheduledCheckInterval=3600,
                          NSAppTransportSecurity={'NSAllowsArbitraryLoads': True}), file)
    # Ad hoc is explicit and limited to this disposable fixture; production identities are never accessed.
    run('/usr/bin/codesign', '--force', '--sign', '-', app)


def scenario(name, key, public, port, server_root):
    root = pathlib.Path(tempfile.mkdtemp(prefix='MimicUpdateAcceptance-', dir='/private/tmp'))
    app = root / 'Installed/Mimic.app'
    directory = server_root / name
    directory.mkdir()
    feed = f'http://127.0.0.1:{port}/{name}/appcast.xml'
    if name == 'offline':
        feed = 'http://127.0.0.1:1/appcast.xml'
    bundle(app, feed, public, 130)
    bundle(directory / 'Mimic.app', feed, public, 131)
    archive = directory / 'Mimic.zip'
    run('/usr/bin/ditto', '-c', '-k', '--keepParent', directory / 'Mimic.app', archive)
    signature = run(SIGN, '-f', key, '-p', archive)
    if name == 'bad-signature':
        signature = base64.b64encode(bytes(64)).decode()
    if name == 'corrupt':
        # Preserve length so rejection proves signature verification, not an HTTP truncation check.
        with archive.open('r+b') as file:
            file.seek(17); value = file.read(1); file.seek(17); file.write(bytes([value[0] ^ 1]))
    rss = ET.Element('rss', version='2.0')
    channel = ET.SubElement(rss, 'channel'); ET.SubElement(channel, 'title').text = 'Mimic fixture'
    item = ET.SubElement(channel, 'item'); ET.SubElement(item, 'title').text = 'Fixture 131'
    ET.SubElement(item, '{' + NS + '}version').text = '131'
    ET.SubElement(item, '{' + NS + '}shortVersionString').text = '1.3.1'
    ET.SubElement(item, 'enclosure', url=f'http://127.0.0.1:{port}/{name}/Mimic.zip', length=str(archive.stat().st_size),
                  type='application/octet-stream', **{'{' + NS + '}edSignature': signature})
    feed_path = directory / 'appcast.xml'
    ET.ElementTree(rss).write(feed_path, encoding='utf-8', xml_declaration=True)
    run(SIGN, '-f', key, feed_path)
    suite = 'MimicUpdateFixture-' + str(uuid.uuid4())
    with (root / 'fixture.plist').open('wb') as file:
        plistlib.dump({'suite': suite, 'expectedBuild': '131'}, file)
    support = root / 'Support'
    for relative in ['Profiles/preserved.txt', 'CodexPlugin/plugins/mimic/.mcp.json', 'BuildHistory/preserved.txt']:
        path = support / relative; path.parent.mkdir(parents=True, exist_ok=True); path.write_text('fixture-preserved')
    (support / 'history.json').write_text('[]')
    (support / 'remote-runs.json').write_text('[]')
    if name == 'no-write':
        app.chmod(0o555); app.parent.chmod(0o555)
    log = root / 'process.log'
    process = None
    try:
        with log.open('wb') as output:
            process = subprocess.Popen([str(app / 'Contents/MacOS/Mimic')], stdout=output, stderr=output)
            deadline = time.monotonic() + 55
            while time.monotonic() < deadline and not (root / 'result').exists():
                time.sleep(.2)
        result = (root / 'result').read_text() if (root / 'result').exists() else 'timeout'
        events = json.loads((root / 'events.json').read_text()) if (root / 'events.json').exists() else []
        with (app / 'Contents/Info.plist').open('rb') as file:
            build = plistlib.load(file)['CFBundleVersion']
        if name == 'success':
            assert result == 'installed' and build == '131', (name, result, events, root)
            assert events.index('queue-preserved') < events.index('queue-finished') < events.index('idle-exit'), events
            assert 'exit-blocked' not in events, events
            backups = list((support / 'UpdateBackups').glob('backup-*'))
            assert backups and any((p / 'Mimic.app/Contents/Info.plist').exists() for p in backups)
        else:
            assert result.startswith('failed') and result.endswith(':retry-ready') and build == '130', (name, result, events, root)
            assert 'idle-exit' not in events, events
        for relative in ['Profiles/preserved.txt', 'CodexPlugin/plugins/mimic/.mcp.json', 'BuildHistory/preserved.txt']:
            assert (support / relative).read_text() == 'fixture-preserved', relative
        print('PASS', name, result, 'build=' + build, flush=True)
        return {'scenario': name, 'result': result, 'build': build, 'events': events, 'evidence': str(root)}
    finally:
        if name == 'no-write':
            app.chmod(0o755); app.parent.chmod(0o755)
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait()
        # Only fixture preferences, never the user application's domain.
        subprocess.run(['/usr/bin/defaults', 'delete', suite], capture_output=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scenarios', nargs='+', choices=['success', 'corrupt', 'bad-signature', 'offline', 'no-write'],
                        default=['success', 'corrupt', 'bad-signature', 'offline', 'no-write'])
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='MimicUpdateServer-', dir='/private/tmp') as directory:
        root = pathlib.Path(directory)
        key = root / 'synthetic.seed'
        key.write_text(base64.b64encode(bytes(range(32))).decode()); key.chmod(0o600)
        program = root / 'public.swift'
        program.write_text('// Created by Василий Маслов on 06.10.2026.\nimport Foundation\nimport CryptoKit\nlet key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data((0..<32).map { UInt8($0) }))\nprint(key.publicKey.rawRepresentation.base64EncodedString())\n')
        public = run('/usr/bin/swift', program)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(QuietServer, directory=str(root)))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            results = [scenario(name, key, public, server.server_port, root) for name in args.scenarios]
            report = pathlib.Path('/private/tmp/MimicUpdateAcceptance-results.json')
            report.write_text(json.dumps(results, ensure_ascii=False, indent=2))
            print('Evidence:', report)
        finally:
            server.shutdown(); server.server_close()


if __name__ == '__main__':
    main()
