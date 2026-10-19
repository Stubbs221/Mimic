# Created by Василий Маслов on 16.10.2026.
"""Loopback-only form fixture. No request input or response credentials are logged."""
import http.server
import json


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def respond(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        kind = self.headers.get('X-Fixture-Response', 'uid')
        values = {'uid': {'uid': '123', 'email': 'fixture@example.test', 'password': 'fixture-password', 'session': 'fixture-session'}, 'null': None, 'emptyObject': {}, 'resultOK': {'result': 'ok'}, 'code': {'code': '1234'}}
        data = json.dumps(values[kind]).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = respond
    do_POST = respond
    do_PUT = respond
    do_DELETE = respond


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
