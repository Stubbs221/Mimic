#!/usr/bin/env python3
# Created by Василий Маслов on 04.10.2026.
"""Read-only stdio fixture handshake; never starts Mimic or executes project actions."""
import json
import select
import subprocess
import sys

helper = sys.argv[1]
process = subprocess.Popen([helper, '--fixture'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

def send(value):
    process.stdin.write((json.dumps(value) + '\n').encode())
    process.stdin.flush()

def call(identifier, method, parameters):
    send({'jsonrpc': '2.0', 'id': identifier, 'method': method, 'params': parameters})
    while True:
        if not select.select([process.stdout], [], [], 5)[0]:
            raise RuntimeError('MCP response timed out or request ID was changed')
        line = process.stdout.readline()
        if not line:
            raise RuntimeError('MCP helper closed the transport')
        result = json.loads(line)
        if result.get('id') == identifier:
            assert 'error' not in result, result.get('error', {}).get('code')
            return result['result']

try:
    initialization = call(9007199254740993, 'initialize', {'protocolVersion': '2025-11-25', 'capabilities': {
        'roots': {'listChanged': True},
        'experimental': {
            'io.modelcontextprotocol/ui': {'mimeTypes': ['text/html;profile=mcp-app']},
            'openai/ui': {'entrypoints': True},
            'fixture-legacy': 'supported',
        },
    }, 'clientInfo': {'name': 'MimicFixtureHost', 'version': '1'}})
    assert initialization['serverInfo']['name'] == 'mimic'
    send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
    tools = call(2, 'tools/list', {})['tools']
    assert {"run_local_action", "run_remote_action", "get_remote_run", "get_action_configuration", "preview_generator", "get_generator_preview", "generate_files"}.issubset({tool["name"] for tool in tools})
    assert not {"run_ui_tests", "get_ui_test_run", "arbitrary_shell"}.intersection({tool["name"] for tool in tools})
    private = [tool for tool in tools if tool['name'].startswith('panel_')]
    assert private and all(tool['_meta']['ui']['visibility'] == ['app'] for tool in private)
    panel = next(tool for tool in tools if tool['name'] == 'open_panel')
    assert panel['_meta']['openai/ui']['entrypoints'] == [{'type': 'thread'}]
    resource_uri = panel['_meta']['ui']['resourceUri']
    resources = call(3, 'resources/list', {})['resources']
    assert any(resource['uri'] == resource_uri for resource in resources)
    content = call(4, 'resources/read', {'uri': resource_uri})['contents'][0]
    assert content['mimeType'] == 'text/html;profile=mcp-app'
    assert 'root' in content['text'] or 'app' in content['text']
    assert len(content['text']) > 10000
    assert content['_meta']['ui']['csp']['connectDomains'] == []
    state = call(5, 'tools/call', {'name': 'open_panel', 'arguments': {}})['structuredContent']
    assert state['version'] == 3
    assert state['actions'] == []
    assert state['context']['profileRevision'] is None
    assert state['context']['checkoutId'].startswith('/private/tmp/')
    unsupported = {'jsonrpc': '2.0', 'id': 6, 'method': 'tools/call', 'params': {'name': 'arbitrary_shell', 'arguments': {}}}
    send(unsupported)
    assert json.loads(process.stdout.readline()).get('error', {}).get('code') == -32602
    print('PASS: MCP Apps initialize capabilities, profile action contracts, thread entrypoint, bundled UI/CSP, fixture state, unknown-tool rejection')
finally:
    process.terminate()
    process.wait(timeout=5)
