import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import tempfile
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import ProxyHandler, Request, build_opener

from scripts.pegaroute_quote_proxy import QuoteProxy


class Upstream(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.server.calls.append((self.path, self.headers.get("X-API-Key")))
        body = json.dumps({"routes": [{"expectedOutput": "4.65"}]}).encode()
        self.send_response(self.server.status)
        if self.server.status == 302:
            self.send_header("Location", "/credential-receiver")
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class QuoteProxyTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.key_file = Path(self.directory.name) / "local-key.md"
        self.key_file.write_text("PEGASUS_API_KEY=fixture-only-key\n")
        self.upstream = ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
        self.upstream.calls = []
        self.upstream.status = 200
        self.proxy = QuoteProxy(
            ("127.0.0.1", 0),
            f"http://127.0.0.1:{self.upstream.server_port}", self.key_file,
        )
        self.threads = []
        for server in [self.upstream, self.proxy]:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            self.threads.append(thread)

    def tearDown(self):
        for server in [self.proxy, self.upstream]:
            server.shutdown()
            server.server_close()
        for thread in self.threads:
            thread.join()
        self.directory.cleanup()

    def request(self, path, method="GET", headers=None):
        request = Request(f"http://127.0.0.1:{self.proxy.server_port}{path}",
                          method=method, headers=headers or {})
        try:
            response = build_opener(ProxyHandler({})).open(request, timeout=3)
        except HTTPError as error:
            response = error
        with response:
            return response.status, json.loads(response.read()), response.headers

    def test_authenticates_quotes_server_side_and_reloads_rotated_key(self):
        path = "/quote?fromChain=ETH&fromToken=ETH&toChain=XMR&toToken=XMR&amount=1"
        status, body, headers = self.request(path, headers={"X-API-Key": "ignored-client-key"})
        self.assertEqual(status, 200)
        self.assertEqual(body["routes"][0]["expectedOutput"], "4.65")
        self.assertIsNone(headers.get("X-API-Key"))
        self.assertEqual(self.upstream.calls, [(path, "fixture-only-key")])
        self.key_file.write_text("PEGASUS_API_KEY='rotated-fixture-key'\n")
        self.assertEqual(self.request(path)[0], 200)
        self.assertEqual(self.upstream.calls[-1], (path, "rotated-fixture-key"))

    def test_rejects_creation_callbacks_and_unapproved_proxy_targets(self):
        for path, method in [("/swap", "POST"), ("/swap/id/txhash", "POST"),
                             ("/swap/id", "GET"), ("/quote?integrationId=other", "GET"),
                             ("/quote?amount=1&amount=2", "GET")]:
            self.assertIn(self.request(path, method)[0], [400, 405])
        self.assertEqual(self.request("/quote", headers={"Host": "external.test"})[0], 403)
        self.assertEqual(self.upstream.calls, [])

    def test_does_not_follow_authenticated_upstream_redirects(self):
        self.upstream.status = 302
        self.assertEqual(self.request("/quote?amount=1")[0], 502)
        self.assertEqual(len(self.upstream.calls), 1)
        self.assertEqual(self.upstream.calls[0][0], "/quote?amount=1")

    def test_reports_upstream_authentication_failure_without_leaking_key(self):
        self.upstream.status = 401
        status, body, _headers = self.request("/quote?amount=1")
        self.assertEqual(status, 401)
        self.assertNotIn("fixture-only-key", json.dumps(body))
        self.key_file.write_text("PEGASUS_API_KEY=''\n")
        self.assertEqual(self.request("/quote?amount=1")[0], 502)
        self.assertEqual(len(self.upstream.calls), 1)


if __name__ == "__main__":
    unittest.main()
