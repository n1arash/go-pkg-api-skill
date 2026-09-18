#!/usr/bin/env python3
"""Integration tests using the real Bash/curl/jq against a loopback HTTP server.

Python is a development/test dependency only. No Internet access is required.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "skills/go-pkg/scripts/go-pkg.sh"


class Handler(BaseHTTPRequestHandler):
    requests: list[dict] = []
    responses: list[tuple[int, dict, bytes]] = []

    def do_GET(self) -> None:
        parsed = urlsplit(self.path)
        self.requests.append({"path": parsed.path, "query": parse_qs(parsed.query, keep_blank_values=True)})
        if self.responses:
            status, headers, body = self.responses.pop(0)
        else:
            status, headers, body = 200, {}, b'{"ok":true}'
        self.send_response(status)
        for name, value in headers.items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        pass


class HttpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}/v1"

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)

    def setUp(self) -> None:
        Handler.requests = []
        Handler.responses = []

    def invoke(self, *args: str, retries: int = 0) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env.update(GO_PKG_BASE_URL=self.base, GO_PKG_RETRIES=str(retries),
                   GO_PKG_TIMEOUT="5", GO_PKG_CONNECT_TIMEOUT="2",
                   NO_PROXY="127.0.0.1", no_proxy="127.0.0.1")
        return subprocess.run(["bash", str(CLI), *args], env=env, text=True,
                              capture_output=True, timeout=15, check=False)

    def test_every_endpoint_uses_get_and_the_correct_path(self) -> None:
        for endpoint in ("search", "package", "module", "packages", "versions", "symbols", "imported-by", "vulns"):
            with self.subTest(endpoint=endpoint):
                result = self.invoke(endpoint, "github.com/Acme/Thing/v2")
                self.assertEqual(result.returncode, 0, result.stderr)
                expected = "/v1/search" if endpoint == "search" else f"/v1/{endpoint}/github.com/Acme/Thing/v2"
                self.assertEqual(Handler.requests[-1]["path"], expected)

    def test_query_encoding_cannot_inject_parameters_or_read_files(self) -> None:
        query = '@secret.txt &q=INJECTED "quotes" + / ? # 日本語'
        result = self.invoke("search", query, "--filter", 'contains(synopsis, "c++")')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Handler.requests[0]["query"], {
            "q": [query], "filter": ['contains(synopsis, "c++")']})

    def test_path_metacharacters_are_encoded_without_changing_host(self) -> None:
        result = self.invoke("package", "example.com/x?y#z")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Handler.requests[0]["path"], "/v1/package/example.com/x%3Fy%23z")
        self.assertEqual(Handler.requests[0]["query"], {})

    def test_nested_pagination_preserves_query_and_replaces_token(self) -> None:
        for token, item in (("next +/= &", "One"), ("", "Two")):
            body = {"modulePath": "example.com/x", "version": "v1.0.0", "symbols": {
                "items": [{"name": item}], "nextPageToken": token, "total": 2}}
            Handler.responses.append((200, {}, json.dumps(body).encode()))
        result = self.invoke("symbols", "example.com/x", "--token", "initial +/=",
                             "--version", "v1.0.0", "--limit", "1", "--all")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([x["name"] for x in json.loads(result.stdout)["symbols"]["items"]], ["One", "Two"])
        first, second = [request["query"] for request in Handler.requests]
        self.assertEqual(first.pop("token"), ["initial +/="])
        self.assertEqual(second.pop("token"), ["next +/= &"])
        self.assertEqual(first, second)

    def test_retry_after_429_uses_only_successful_response_body(self) -> None:
        Handler.responses = [(429, {"Retry-After": "1"}, b'{"message":"slow down"}'),
                             (200, {}, b'{"ok":true}')]
        result = self.invoke("package", "fmt", retries=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"ok": True})
        self.assertEqual(len(Handler.requests), 2)

    def test_transient_503_is_retried(self) -> None:
        Handler.responses = [(503, {}, b'{"message":"retry"}'), (200, {}, b'{"ok":true}')]
        result = self.invoke("module", "std", retries=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"ok": True})
        self.assertEqual(len(Handler.requests), 2)

    def test_permanent_http_error_is_not_retried(self) -> None:
        Handler.responses = [(404, {}, b'{"message":"not found","fixes":["check path"]}')]
        result = self.invoke("package", "missing", retries=1)
        self.assertEqual(result.returncode, 22)
        self.assertEqual(result.stdout, "")
        self.assertIn("fixes", result.stderr)
        self.assertEqual(len(Handler.requests), 1)

    def test_non_json_success_is_not_treated_as_docs(self) -> None:
        Handler.responses = [(200, {}, b'<html>gateway login</html>')]
        result = self.invoke("package", "fmt", "--doc", "md")
        self.assertEqual(result.returncode, 65)
        self.assertEqual(result.stdout, "")

    def test_partial_aggregate_is_not_printed_after_http_error(self) -> None:
        Handler.responses = [(200, {}, b'{"items":[1],"nextPageToken":"more"}'),
                             (500, {}, b'{"message":"failed"}')]
        result = self.invoke("search", "uuid", "--all")
        self.assertEqual(result.returncode, 22)
        self.assertEqual(result.stdout, "")

    def test_spec_preserves_raw_yaml(self) -> None:
        body = b'openapi: 3.0.3\ninfo:\n  title: Test\n'
        Handler.responses = [(200, {}, body)]
        result = self.invoke("spec")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, body.decode())
        self.assertEqual(Handler.requests[0]["path"], "/v1/openapi.yaml")


if __name__ == "__main__":
    unittest.main(verbosity=2)
