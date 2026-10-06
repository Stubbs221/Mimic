#!/usr/bin/env python3
# Created by Василий Маслов on 04.10.2026.
"""Opt-in live acceptance for the generated Fixture checkout, never a working project."""
import argparse
import json
from pathlib import Path
import select
import signal
import subprocess
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--app', required=True)
parser.add_argument('--fixture', required=True)
parser.add_argument('--destination', required=True)
args = parser.parse_args()
checkout = Path(args.fixture)
assert str(checkout).startswith('/private/tmp/MimicXcodeAcceptance-')
assert (checkout / 'App/Value.swift').is_file(), 'Only the generated fixture is accepted'
helper = Path(args.app) / 'Contents/Helpers'
client = subprocess.Popen([str(helper / 'MimicMCP')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
sequence = 0

def send(message):
    client.stdin.write((json.dumps(message) + '\n').encode())
    client.stdin.flush()

def rpc(method, parameters):
    global sequence
    sequence += 1
    send({'jsonrpc': '2.0', 'id': sequence, 'method': method, 'params': parameters})
    deadline = time.monotonic() + 40
    while time.monotonic() < deadline:
        if not select.select([client.stdout], [], [], 1)[0]:
            continue
        response = json.loads(client.stdout.readline())
        if response.get('id') == sequence:
            assert 'error' not in response, response.get('error')
            return response['result']
    raise TimeoutError(method)

def tool(name, parameters):
    reply = rpc('tools/call', {'name': name, 'arguments': parameters})
    assert not reply.get('isError'), reply.get('structuredContent', {}).get('code')
    return reply['structuredContent']

try:
    rpc('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {}, 'clientInfo': {'name': 'MimicBuildAcceptance', 'version': '1'}})
    send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
    names = {x['name'] for x in rpc('tools/list', {})['tools']}
    assert len(names) == 16 and 'get_build_log' not in names
    state = tool('get_state', {})
    context = state['context']
    assert Path(context['checkoutId']).resolve() == checkout.resolve()
    catalogue = tool('get_build_configuration', {'context': context, 'scheme': 'Fixture'})
    assert any(x['id'] == args.destination for x in catalogue['cli']['destinations'])
    identifier = str(uuid.uuid4())
    parameters = {'context': context, 'requestID': identifier, 'simulatorConfirmed': False, 'parameters': {'backend': 'cli', 'scheme': 'Fixture', 'configuration': 'Debug', 'destinationID': args.destination}}
    first = tool('build_project', parameters)
    second = tool('build_project', parameters)
    assert uuid.UUID(first['id']) == uuid.UUID(second['id']) == uuid.UUID(identifier)
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        activity = tool('get_build_activity', {'activityID': identifier})
        assert 'text' not in activity and 'output' not in activity
        if activity['status'] not in ('queued', 'preparing', 'running'):
            break
        time.sleep(0.25)
    assert activity['status'] == 'succeeded'
    cli = str(helper / 'MimicCLI')
    command = [cli, 'test', '--scheme', 'Fixture', '--configuration', 'Debug', '--destination', args.destination, '--checkout', str(checkout), '--only-testing', 'FixtureTests/FixtureTests/testValue']
    with open('/private/tmp/MimicCLICancellation.log', 'wb') as output:
        observer = subprocess.Popen(command, stdout=output, stderr=subprocess.PIPE)
        line = observer.stderr.readline().decode().strip()
        operation = str(uuid.UUID(line))
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            status = json.loads(subprocess.check_output([cli, 'status', operation]))
            if status['status'] == 'running':
                break
            assert status['status'] in ('queued', 'preparing')
            time.sleep(0.1)
        observer.send_signal(signal.SIGINT)
        assert observer.wait(timeout=30) == 130
        status = json.loads(subprocess.check_output([cli, 'status', operation]))
        assert status['status'] == 'cancelled'
    print('PASS: 16 MCP tools, exact catalogue, build_project success/idempotency, metadata without output, MimicCLI Ctrl+C confirms addressed cancellation')
finally:
    client.terminate()
    client.wait(timeout=5)
