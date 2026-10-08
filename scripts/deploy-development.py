#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Created by Василий Маслов on 05.10.2026.
"""Deploy a verified development bundle after the native owner agrees to an idle exit."""
import argparse
import json
import pathlib
import plistlib
import socket
import subprocess
import sys
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parent
SUPPORT = pathlib.Path.home() / 'Library/Application Support/Mimic'
with (ROOT / 'setup-mimic.ru.plist').open('rb') as messages_file:
    MESSAGES = plistlib.load(messages_file)


def process_ids(name):
    result = subprocess.run(['/usr/bin/pgrep', '-x', name], capture_output=True, text=True)
    if result.returncode not in (0, 1):
        raise RuntimeError(MESSAGES['inventory'])
    return result.stdout.split()


def prepare_exit():
    """Use only the private lifecycle method; task metadata and logs are never collected."""
    request_id = str(uuid.uuid4())
    request = {'version': 2, 'id': request_id, 'method': 'prepare_development_update', 'parameters': {}}
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(5)
        connection.connect(str(SUPPORT / 'Bridge/mcp.sock'))
        connection.sendall(json.dumps(request).encode() + b'\n')
        data = bytearray()
        while b'\n' not in data:
            chunk = connection.recv(4096)
            if not chunk:
                raise RuntimeError(MESSAGES['development.bridgeClosed'])
            data.extend(chunk)
            if len(data) > 4096:
                raise RuntimeError(MESSAGES['development.invalidReply'])
    reply = json.loads(data.split(b'\n', 1)[0])
    if reply.get('id', '').lower() != request_id.lower() or reply.get('error'):
        raise RuntimeError(MESSAGES['development.legacy'])
    ready = reply.get('result', {}).get('ready')
    if not isinstance(ready, bool):
        raise RuntimeError(MESSAGES['development.invalidReply'])
    return ready


def wait_for_exit(seconds):
    deadline = time.monotonic() + seconds
    announced = False
    while True:
        owners = process_ids('Mimic') + process_ids('Mimic')
        hosts = process_ids('TaskHost')
        if not owners and not hosts:
            return
        if time.monotonic() >= deadline:
            raise RuntimeError(MESSAGES['development.timeout'])
        if not announced:
            print(MESSAGES['development.waiting'], flush=True)
            announced = True
        if owners:
            try:
                prepare_exit()
            except (FileNotFoundError, ConnectionRefusedError):
                # The socket can disappear before the exiting owner, or appear after a new launch.
                # Keep waiting within the same deadline; never bypass the installer's idle checks.
                pass
            except (OSError, RuntimeError):
                # Exit can race sending the reply. Accept only independently proven process disappearance.
                if process_ids('Mimic') or process_ids('Mimic'):
                    raise
        time.sleep(1)


def verify_launch(destination):
    expected = str((destination / 'Contents/MacOS/Mimic').resolve())
    for _ in range(20):
        for pid in process_ids('Mimic'):
            result = subprocess.run(['/bin/ps', '-p', pid, '-o', 'comm='], capture_output=True, text=True, check=True)
            if str(pathlib.Path(result.stdout.strip()).resolve()) == expected:
                return
        time.sleep(0.5)
    raise RuntimeError(MESSAGES['development.launchFailed'])


def deploy(app, destination, wait_seconds):
    if app.resolve() == destination.resolve():
        raise RuntimeError(MESSAGES['development.source'])
    installer = ['/bin/bash', str(ROOT / 'setup-mimic.command'), '--app', str(app)]
    subprocess.run(installer + ['--check-only'], check=True)
    wait_for_exit(wait_seconds)
    # The installer repeats inventory immediately before replacing and restores the backup on move failure.
    subprocess.run(installer + ['--destination', str(destination), '--yes', '--background'], check=True)
    verify_launch(destination)
    with (destination / 'Contents/Info.plist').open('rb') as info_file:
        refreshes_on_launch = plistlib.load(info_file).get('MimicRefreshPluginOnLaunch', False)
    if not refreshes_on_launch and (SUPPORT / 'CodexPlugin/plugins/mimic/.mcp.json').is_file():
        subprocess.run([str(destination / 'Contents/MacOS/Mimic'), '--refresh-codex-plugin'], check=True, timeout=180)
        print(MESSAGES['development.plugin'], flush=True)
    print(MESSAGES['development.updated'].format(destination=destination), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=pathlib.Path, required=True)
    parser.add_argument('--destination', type=pathlib.Path, default=pathlib.Path('/Applications/Mimic.app'))
    parser.add_argument('--wait-seconds', type=int, default=300)
    args = parser.parse_args()
    if args.wait_seconds < 0 or not args.app.is_absolute() or not args.destination.is_absolute():
        parser.error(MESSAGES['development.arguments'])
    try:
        deploy(args.app, args.destination, args.wait_seconds)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
