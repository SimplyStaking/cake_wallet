"""Check the local bridge with synthetic keys and a loopback test server."""

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

import pegaroute_quote_proxy as proxy


class UpstreamHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.server.requests.append((self.command, self.path, self.headers.get('X-API-Key')))
        body = json.dumps({'path': self.path}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_POST = do_GET


class QuoteProxyTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        key = Path(self.directory.name) / 'key.txt'
        key.write_text('API_KEY=synthetic-test-key\n')
        self.upstream = ThreadingHTTPServer(('127.0.0.1', 0), UpstreamHandler)
        self.upstream.requests = []
        self.start(self.upstream)
        self.bridge = proxy.QuoteProxy(('127.0.0.1', 0),
            f'http://127.0.0.1:{self.upstream.server_port}', str(key))
        self.start(self.bridge)

    def start(self, server):
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(thread.join, 2)
        self.addCleanup(server.shutdown)

    def request(self, path, *, method='GET', headers=None, body=None):
        request = Request(f'http://127.0.0.1:{self.bridge.server_port}{path}',
                          data=body, method=method, headers=headers or {})
        try:
            response = urlopen(request, timeout=2)
        except HTTPError as error:
            response = error
        with response:
            return response.status, json.load(response)

    def test_catalog_and_quote_reads_use_server_authentication(self):
        for path in ['/chains', '/tokens?chain=ETH', '/quote?fromChain=ETH&amount=0.01']:
            with self.subTest(path=path):
                status, value = self.request(path)
                self.assertEqual(status, 200)
                self.assertEqual(value, {'path': path})
                self.assertEqual(self.upstream.requests[-1], ('GET', path, 'synthetic-test-key'))

    def test_invalid_catalog_parameters_do_not_reach_upstream(self):
        for path in ['/chains?chain=ETH', '/tokens', '/tokens?chain=',
                     '/tokens?chain=ETH&chain=SOL', '/tokens?chain=ETH&key=value',
                     '/tokens?chain=eth', '/admin', '/swap/order']:
            with self.subTest(path=path):
                self.assertEqual(self.request(path)[0], 400)
        self.assertEqual(self.upstream.requests, [])

    def test_host_check_still_applies_to_catalog_reads(self):
        self.assertEqual(self.request('/chains', headers={'Host': 'example.test'})[0], 403)
        self.assertEqual(self.upstream.requests, [])

    def test_upstream_outage_does_not_poison_later_reads(self):
        with patch.object(proxy, 'build_opener') as opener:
            opener.return_value.open.side_effect = URLError('synthetic outage')
            status, value = self.request('/chains')
            self.assertEqual(status, 502)
            self.assertTrue(value['error']['retryable'])
            self.assertNotIn('synthetic outage', json.dumps(value))
            self.assertEqual(opener.return_value.open.call_count, 1)
        self.assertEqual(self.request('/chains')[0], 200)
        self.assertEqual(len(self.upstream.requests), 1)

    def test_execution_remains_opt_in(self):
        status, _ = self.request('/swap', method='POST',
                                headers={'Content-Type': 'application/json'}, body=b'{"amount":"1"}')
        self.assertEqual(status, 405)
        self.assertEqual(self.upstream.requests, [])

    def test_enabled_execution_is_not_retried_on_transport_failure(self):
        self.bridge.allow_execution = True
        with patch.object(proxy, 'build_opener') as opener:
            opener.return_value.open.side_effect = URLError('synthetic outage')
            status, _ = self.request('/swap', method='POST',
                headers={'Content-Type': 'application/json'}, body=b'{"amount":"1"}')
            self.assertEqual(status, 502)
            self.assertEqual(opener.return_value.open.call_count, 1)
        self.assertEqual(self.upstream.requests, [])


if __name__ == '__main__':
    unittest.main()
