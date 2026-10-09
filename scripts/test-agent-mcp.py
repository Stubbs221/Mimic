#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Created by Василий Маслов on 09.10.2026.
"""Protocol qualification with synthetic host identities; never starts the native app or project actions."""
import json
import select
import subprocess
import sys


def check(helper, client):
    process = subprocess.Popen([helper, '--fixture'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL)

    def send(message):
        process.stdin.write((json.dumps(message) + '\n').encode())
        process.stdin.flush()

    def call(identifier, method, parameters):
        send({'jsonrpc': '2.0', 'id': identifier, 'method': method, 'params': parameters})
        while True:
            if not select.select([process.stdout], [], [], 10)[0]:
                raise RuntimeError('Timed out waiting for MCP reply')
            line = process.stdout.readline()
            if not line:
                raise RuntimeError('MCP transport closed before its reply')
            reply = json.loads(line)
            if reply.get('id') == identifier:
                assert 'error' not in reply, reply
                return reply['result']

    try:
        initialized = call(1, 'initialize', {
            'protocolVersion': '2025-11-25', 'clientInfo': {'name': client, 'version': 'fixture'},
            'capabilities': {'experimental': {'io.modelcontextprotocol/ui': {'mimeTypes': ['text/html;profile=mcp-app']}}},
        })
        assert initialized['serverInfo']['name'] == 'mimic'
        send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        tools = {tool['name']: tool for tool in call(2, 'tools/list', {})['tools']}
        for name in ['bind_project', 'get_build_readiness', 'wait_build_activity', 'get_build_result',
                     'build_project', 'run_selected_tests', 'get_build_configuration', 'get_agent_state',
                     'start_test_catalogue', 'get_test_catalogue', 'validate_selected_tests', 'run_verified_tests',
                     'preview_artifact_cleanup', 'cleanup_activity_artifacts', 'get_build_products', 'start_simulator_check']:
            assert name in tools, name
        assert tools['wait_build_activity']['inputSchema']['required'] == ['activityID']
        assert tools['wait_build_activity']['inputSchema']['properties']['timeoutMs']['maximum'] == 25000
        assert 'workflowID' not in tools['build_project']['inputSchema']['required']
        for name in ['get_build_readiness', 'wait_build_activity', 'get_build_result']:
            assert tools[name]['annotations']['readOnlyHint'] is True
        for tool in tools.values():
            assert 'clientSessionID' not in tool['inputSchema']['properties']
            assert 'helperIdentity' not in tool['inputSchema']['properties']
        for name in ['bind_project', 'get_build_readiness', 'wait_build_activity', 'get_build_result']:
            assert 'resourceUri' not in tools[name].get('_meta', {}).get('ui', {})
        assert tools['run_verified_tests']['inputSchema']['required'] == ['context', 'requestID', 'selectionID']
        assert tools['get_agent_state']['inputSchema']['required'] == []
        assert tools['cleanup_activity_artifacts']['annotations']['readOnlyHint'] is False
        uri = tools['open_panel']['_meta']['ui']['resourceUri']
        resources = call(3, 'resources/list', {})['resources']
        assert any(resource['uri'] == uri for resource in resources)
        resource = call(4, 'resources/read', {'uri': uri})['contents'][0]
        assert resource['mimeType'] == 'text/html;profile=mcp-app'
        assert len(resource['text']) > 10000
        assert resource['_meta']['ui']['csp']['connectDomains'] == ['ws://127.0.0.1:*', 'wss://127.0.0.1:47931']
        state = call(5, 'tools/call', {'name': 'get_state', 'arguments': {}})['structuredContent']
        assert state['capabilities']['buildWorkflowVersion'] == 1
        process.stdin.close()
        process.wait(timeout=10)
        assert process.returncode == 0
        print('PASS: ' + client + ' synthetic stdio handshake, workflow tools, legacy panel resource, EOF')
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)


if __name__ == '__main__':
    for client_name in ['codex-fixture', 'claude-code-fixture', 'generic-mcp-fixture']:
        check(sys.argv[1], client_name)
