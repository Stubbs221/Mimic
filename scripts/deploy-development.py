#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Created by Василий Маслов on 05.10.2026.
"""Deploy a verified development bundle after the native owner agrees to an idle exit."""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
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
            except (TimeoutError, socket.timeout):
                # Backup or a busy UI may outlive one reply deadline. Only confirmed
                # process disappearance permits replacement; retain the original wait budget.
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


@contextlib.contextmanager
def native_handoff(seconds):
    """Hold the app's canonical flock after its confirmed exit; helpers cannot create a queue owner."""
    directory = SUPPORT / 'Bridge'
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(directory / 'native-instance.lock', os.O_CREAT | os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
    deadline = time.monotonic() + seconds
    locked = False
    try:
        while not locked:
            wait_for_exit(max(0, deadline - time.monotonic()))
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                locked = True
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise RuntimeError(MESSAGES['development.timeout'])
        # A losing background launch may still be exiting before it constructs TaskCoordinator.
        while process_ids('Mimic') or process_ids('TaskHost'):
            if time.monotonic() >= deadline:
                raise RuntimeError(MESSAGES['development.timeout'])
            time.sleep(0.05)
        yield
    finally:
        if locked:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def executable_digest(app):
    path = app / 'Contents/MacOS/Mimic'
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None


def deploy(app, destination, wait_seconds):
    if app.resolve() == destination.resolve():
        raise RuntimeError(MESSAGES['development.source'])
    installer = ['/bin/bash', str(ROOT / 'setup-mimic.command'), '--app', str(app)]
    subprocess.run(installer + ['--check-only'], check=True)
    with native_handoff(wait_seconds):
        previous = executable_digest(destination)
        # Keep every installer inventory check. A transient losing launch can fail a check
        # during staging; retry only while the old executable remains unchanged and no task host exists.
        for attempt in range(5):
            try:
                subprocess.run(installer + ['--destination', str(destination), '--yes', '--defer-launch'], check=True)
                break
            except subprocess.CalledProcessError:
                if attempt == 4 or process_ids('TaskHost') or not process_ids('Mimic') or executable_digest(destination) != previous:
                    raise
                time.sleep(0.2)
    subprocess.run(['/usr/bin/open', '-a', str(destination), '--args', '--mcp-background'], check=True)
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
