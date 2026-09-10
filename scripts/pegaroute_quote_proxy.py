#!/usr/bin/env python3
"""Local GET /quote bridge. The upstream API key never enters the Cake app."""

import argparse
import ipaddress
import json
from pathlib import Path
import re
import shlex
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qsl, urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener


QUOTE_FIELDS = {
    "fromChain", "fromToken", "toChain", "toToken", "amount",
    "destinationAddress", "senderAddress", "refundAddress", "private",
}
MAX_RESPONSE_BYTES = 2 * 1024 * 1024


def read_api_key(path):
    text = Path(path).read_text()
    matches = re.findall(r"(?im)\b[A-Z_]*API_?KEY\s*=\s*([^\r\n]+)", text)
    if len(matches) != 1:
        raise ValueError("Expected one API key assignment in the key file")
    values = shlex.split(matches[0].strip().strip("`"), comments=True)
    if len(values) != 1 or not values[0] or any(c in values[0] for c in "\r\n"):
        raise ValueError("Invalid API key assignment")
    return values[0]


def local_origin(value):
    uri = urlsplit(value)
    host = uri.hostname
    loopback = host == "localhost"
    if not loopback:
        try:
            loopback = ipaddress.ip_address(host).is_loopback
        except ValueError:
            loopback = False
    if (uri.scheme != "http" or not loopback or uri.username is not None
            or uri.password is not None or uri.path not in ("", "/")
            or uri.query or uri.fragment):
        raise ValueError("Upstream must be a loopback HTTP origin")
    return value.rstrip("/")


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class QuoteProxy(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, upstream, key_file):
        self.upstream = local_origin(upstream)
        self.key_file = key_file
        read_api_key(key_file)
        super().__init__(address, QuoteHandler)


class QuoteHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def reply(self, status, body):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def reject(self, status, message):
        self.reply(status, json.dumps({"error": {
            "code": "LOCAL_QUOTE_PROXY_ERROR", "message": message,
            "userMessage": message, "retryable": False,
        }}).encode())

    def do_GET(self):
        uri = urlsplit(self.path)
        fields = parse_qsl(uri.query, keep_blank_values=True)
        names = [name for name, _value in fields]
        port = self.server.server_port
        if self.headers.get("Host") not in (f"127.0.0.1:{port}", f"localhost:{port}"):
            return self.reject(403, "Invalid local proxy host")
        if (uri.scheme or uri.netloc or uri.path != "/quote"
                or len(self.path) > 8192 or len(names) != len(set(names))
                or any(name not in QUOTE_FIELDS for name in names)):
            return self.reject(400, "Only GET /quote with quote parameters is supported")
        try:
            request = Request(
                self.server.upstream + self.path,
                headers={"X-API-Key": read_api_key(self.server.key_file)},
            )
            opener = build_opener(ProxyHandler({}), NoRedirects())
            try:
                response = opener.open(request, timeout=30)
            except HTTPError as error:
                response = error
            with response:
                status = response.code
                body = response.read(MAX_RESPONSE_BYTES + 1)
            if 300 <= status < 400 or len(body) > MAX_RESPONSE_BYTES:
                return self.reject(502, "Invalid upstream quote response")
            json.loads(body)
        except (OSError, URLError, ValueError):
            return self.reject(502, "Local upstream quote request failed")
        self.reply(status, body)

    def do_POST(self):
        self.reject(405, "This local proxy supports quotes only")

    do_PUT = do_POST
    do_PATCH = do_POST
    do_DELETE = do_POST


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--key-file", required=True)
    parser.add_argument("--upstream", default="http://127.0.0.1:4000")
    parser.add_argument("--port", type=int, default=4001)
    args = parser.parse_args()
    try:
        server = QuoteProxy(("127.0.0.1", args.port), args.upstream, args.key_file)
    except (OSError, ValueError):
        parser.exit(1, "Unable to start: check the upstream, key file, and local port.\n")
    print(f"Cake quote proxy: http://127.0.0.1:{server.server_port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
