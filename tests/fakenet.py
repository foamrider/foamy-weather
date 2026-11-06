"""Test-only network and helper plumbing for the black-box helper tests.

The helper never reaches the real MET Norway, Nominatim or Open-Meteo hosts in
tests. A loopback HTTPS server (``Server``) stands in for all three; its
certificate is issued by a throwaway CA (``make_certs``, via ``openssl``) for
the real host names, so TLS is verified exactly as in production: the helper
connects to ``FOAMY_WEATHER_TEST_CONNECT`` (a loopback ``ip:port``, test-only)
instead of the host's address, and trusts the CA through ``SSL_CERT_FILE``.

``helper_command(subcommand, *args)`` is the argv of the helper under test:
``bin/<machine>/foamy-weather-helper`` (absolute, so it runs with any
``PATH``). ``FOAMY_HELPER`` (a JSON argv prefix, absolute paths) overrides it;
the subcommand and its arguments follow the prefix.

CLI for the node and bash tests:

  python3 tests/fakenet.py certs DIR     # DIR/ca.pem, DIR/server.pem, DIR/server.key
  python3 tests/fakenet.py serve DIR     # writes DIR/port; logs DIR/requests;
                                         # replies from DIR/<kind>.json if present
  python3 tests/fakenet.py argv SUBCOMMAND [ARG...]   # NUL-separated helper argv
"""
import http.server
import json
import os
from pathlib import Path
import platform
import ssl
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
HOSTS = ['api.met.no', 'nominatim.openstreetmap.org', 'geocoding-api.open-meteo.com']
PROXY_VARIABLES = ['http_proxy', 'HTTP_PROXY', 'https_proxy', 'HTTPS_PROXY',
                   'all_proxy', 'ALL_PROXY', 'no_proxy', 'NO_PROXY']


def helper_command(subcommand, *args):
    """The helper's argv: FOAMY_HELPER (or the bundled binary) + subcommand."""
    prefix = os.environ.get('FOAMY_HELPER')
    if prefix:
        argv = json.loads(prefix)
        if not isinstance(argv, list) or not argv or not all(isinstance(a, str) for a in argv):
            raise SystemExit('FOAMY_HELPER must be a JSON list of strings')
        return [*argv, subcommand, *args]
    return [str(ROOT / 'bin' / platform.machine() / 'foamy-weather-helper'), subcommand, *args]



def make_certs(directory):
    """A CA and a server certificate for HOSTS (EC P-256, two days)."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    run = lambda *argv: subprocess.run(['openssl', *argv], check=True, capture_output=True)
    run('req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256', '-nodes', '-days', '2',
        '-subj', '/CN=foamy-weather test CA', '-addext', 'basicConstraints=critical,CA:TRUE',
        '-addext', 'keyUsage=critical,keyCertSign', '-keyout', str(directory / 'ca.key'),
        '-out', str(directory / 'ca.pem'))
    run('req', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256', '-nodes',
        '-subj', '/CN=' + HOSTS[0], '-keyout', str(directory / 'server.key'),
        '-out', str(directory / 'server.csr'))
    (directory / 'server.ext').write_text(
        'subjectAltName=' + ','.join('DNS:' + host for host in HOSTS) + '\n'
        'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n'
        'extendedKeyUsage=serverAuth\n')
    run('x509', '-req', '-in', str(directory / 'server.csr'), '-CA', str(directory / 'ca.pem'),
        '-CAkey', str(directory / 'ca.key'), '-CAcreateserial', '-days', '2',
        '-extfile', str(directory / 'server.ext'), '-out', str(directory / 'server.pem'))
    return {name: str(directory / f'{name}.pem') for name in ['ca', 'server']} | {
        'key': str(directory / 'server.key')}


def forecast_body():
    return json.dumps({'type': 'Feature', 'properties': {'timeseries': [{
        'time': time.strftime('%Y-%m-%dT%H:00:00Z', time.gmtime()),
        'data': {'instant': {'details': {'air_temperature': 12}}}}]}})


SUN = json.dumps({'properties': {'sunrise': {'time': '2026-10-09T06:00:00Z'},
                                 'sunset': {'time': '2026-10-09T18:00:00Z'}}})
SEARCH = json.dumps({'results': [{'name': 'Oslo', 'latitude': 59.91273, 'longitude': 10.74609,
                                  'country': 'Norway', 'admin1': 'Oslo'}]})


def kind_of(path):
    if '/locationforecast/' in path:
        return 'forecast'
    if '/sunrise/' in path:
        return 'sun'
    if path.startswith('/reverse'):
        return 'reverse'
    if path.startswith('/v1/search'):
        return 'search'
    return 'unknown'


class Server:
    """Loopback HTTPS for every host in HOSTS. ``replies[kind]`` is a dict
    with ``body`` (str or bytes), optional ``status`` and ``headers``, or a
    callable(handler) that writes the response itself. ``log`` holds
    ``(host, path, headers)`` per request."""

    def __init__(self, certs, replies=None, log_file=None):
        self.replies = replies if replies is not None else {}
        self.log = []
        self.log_file = log_file
        server = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def log_message(self, *args):
                pass

            def do_GET(self):
                kind = kind_of(self.path)
                entry = (self.headers.get('Host', ''), self.path, dict(self.headers.items()))
                server.log.append(entry)
                if server.log_file:
                    with open(server.log_file, 'a') as log:
                        log.write(json.dumps({'host': entry[0], 'path': entry[1], 'headers': entry[2]}) + '\n')
                reply = server.reply(kind)
                if callable(reply):
                    reply(self)
                    return
                body = reply.get('body', '')
                body = body.encode() if isinstance(body, str) else body
                self.send_response(reply.get('status', 200))
                for name, value in reply.get('headers', {}).items():
                    self.send_header(name, value)
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Connection', 'close')
                self.end_headers()
                self.wfile.write(body)
                self.close_connection = True

        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certs['server'], certs['key'])
        self.httpd = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.httpd.daemon_threads = True
        self.httpd.socket = context.wrap_socket(self.httpd.socket, server_side=True)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    def reply(self, kind):
        if kind in self.replies:
            return self.replies[kind]
        return {'forecast': {'body': forecast_body()}, 'sun': {'body': SUN},
                'reverse': {'body': '{}'}, 'search': {'body': SEARCH}}.get(kind, {'status': 404})

    def paths(self, kind=None):
        return [path for _, path, _ in self.log if kind is None or kind_of(path) == kind]

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.httpd.shutdown()
        self.httpd.server_close()


def network_env(env, port, ca):
    """``env`` pointed at the loopback server, without proxies."""
    env = {key: value for key, value in env.items() if key not in PROXY_VARIABLES}
    env.update(FOAMY_WEATHER_TEST_CONNECT=f'127.0.0.1:{port}', SSL_CERT_FILE=ca)
    env.pop('SSL_CERT_DIR', None)
    return env


def serve(directory):
    """Serve until killed; replies from DIR/<kind>.json, requests logged."""
    directory = Path(directory)
    certs = {'ca': str(directory / 'ca.pem'), 'server': str(directory / 'server.pem'),
             'key': str(directory / 'server.key')}
    if not Path(certs['server']).exists():
        certs = make_certs(directory)

    class Replies(dict):
        def __contains__(self, kind):
            return (directory / f'{kind}.json').exists()

        def __getitem__(self, kind):
            return {'body': (directory / f'{kind}.json').read_bytes()}

    with Server(certs, Replies(), log_file=str(directory / 'requests')) as server:
        (directory / 'port.tmp').write_text(str(server.port))
        os.replace(directory / 'port.tmp', directory / 'port')
        threading.Event().wait()


if __name__ == '__main__':
    command, *rest = sys.argv[1:] or ['']
    if command == 'certs':
        make_certs(rest[0])
    elif command == 'serve':
        serve(rest[0])
    elif command == 'argv':
        sys.stdout.write(''.join(arg + '\0' for arg in helper_command(*rest)))
    else:
        raise SystemExit(__doc__)
