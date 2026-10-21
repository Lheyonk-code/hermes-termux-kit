#!/usr/bin/env python3
"""F-38: injector menangani balasan SSE upstream.

Sebagian backend menghormati `stream: true` dan membalas SSE; injector
membaca seluruh badan balasan, jadi SSE harus digabung jadi completion
JSON (dan diteruskan mentah ke klien yang meminta stream), bukan 502
"balasan bukan JSON".

Jalan: python3 tests/test_sse.py
"""
import importlib.util
import json
import os
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

KIT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("injector", KIT / "tools" / "injector.py")
INJ = importlib.util.module_from_spec(spec)
spec.loader.exec_module(INJ)

SSE_BODY = (
    'data: {"id":"c1","created":1,"model":"m1","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}\n\n'
    'data: {"id":"c1","created":1,"model":"m1","choices":[{"index":0,"delta":{"content":"Ha"},"finish_reason":null}]}\n\n'
    'data: {"id":"c1","created":1,"model":"m1","choices":[{"index":0,"delta":{"content":"lo"},"finish_reason":null}]}\n\n'
    'data: {"id":"c1","created":1,"model":"m1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}\n\n'
    'data: [DONE]\n\n'
)

SSE_TOOLS = (
    'data: {"id":"c2","model":"m1","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get_weather","arguments":""}}]},"finish_reason":null}]}\n\n'
    'data: {"id":"c2","model":"m1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"city\\":"}}]},"finish_reason":null}]}\n\n'
    'data: {"id":"c2","model":"m1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"Jakarta\\"}"}}]},"finish_reason":"tool_calls"}]}\n\n'
    'data: [DONE]\n\n'
)


class FakePool:
    def __init__(self, provs):
        self._provs = provs
        self.marks = []

    def chain(self):
        return list(self._provs)

    def mark(self, name, ok, code, err, latency=0.0):
        self.marks.append((name, ok, code))


def _serve(body: bytes, ctype: str):
    class H(BaseHTTPRequestHandler):
        def do_POST(self):  # noqa: N802
            n = int(self.headers.get("Content-Length") or 0)
            self.rfile.read(n)
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass

    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f"http://127.0.0.1:{srv.server_address[1]}/v1"


class TestAggregate(unittest.TestCase):
    def test_content_chunks_merged(self):
        out = INJ._sse_aggregate(SSE_BODY)
        self.assertIsNotNone(out)
        self.assertEqual(out["choices"][0]["message"]["content"], "Halo")
        self.assertEqual(out["choices"][0]["finish_reason"], "stop")
        self.assertEqual(out["usage"]["total_tokens"], 7)
        self.assertEqual(out["model"], "m1")

    def test_tool_calls_merged(self):
        out = INJ._sse_aggregate(SSE_TOOLS)
        tc = out["choices"][0]["message"]["tool_calls"]
        self.assertEqual(len(tc), 1)
        self.assertEqual(tc[0]["id"], "call_1")
        self.assertEqual(tc[0]["function"]["name"], "get_weather")
        self.assertEqual(tc[0]["function"]["arguments"], '{"city":"Jakarta"}')
        self.assertEqual(out["choices"][0]["finish_reason"], "tool_calls")

    def test_plain_json_passthrough(self):
        out = INJ._sse_aggregate('{"id":"x","choices":[]}')
        self.assertEqual(out["id"], "x")

    def test_garbage_none(self):
        self.assertIsNone(INJ._sse_aggregate("bukan sse sama sekali"))
        self.assertIsNone(INJ._sse_aggregate(""))


class TestForwardSSE(unittest.TestCase):
    def setUp(self):
        for k in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "all_proxy"):
            os.environ.pop(k, None)

    def _pool(self, url):
        pv = {"name": "mock", "base_url": url, "api_key": "k-1",
              "models": ["m1"], "default_model": "m1", "fallback": False}
        return FakePool([pv])

    def test_forward_sse_aggregated_and_raw_kept(self):
        srv, url = _serve(SSE_BODY.encode(), "text/event-stream")
        try:
            INJ.POOL = self._pool(url)
            code, out, raw = INJ.forward("/chat/completions",
                                         {"model": "m1", "stream": True,
                                          "messages": [{"role": "user", "content": "hi"}]},
                                         timeout=10)
            self.assertEqual(code, 200)
            self.assertEqual(out["choices"][0]["message"]["content"], "Halo")
            self.assertIsNotNone(raw)
            self.assertIn("data:", raw)
        finally:
            srv.shutdown()

    def test_forward_plain_json_raw_none(self):
        payload = {"id": "j1", "choices": [{"index": 0, "message": {"role": "assistant", "content": "ok"}, "finish_reason": "stop"}]}
        srv, url = _serve(json.dumps(payload).encode(), "application/json")
        try:
            INJ.POOL = self._pool(url)
            code, out, raw = INJ.forward("/chat/completions",
                                         {"model": "m1", "messages": [{"role": "user", "content": "hi"}]},
                                         timeout=10)
            self.assertEqual(code, 200)
            self.assertEqual(out["choices"][0]["message"]["content"], "ok")
            self.assertIsNone(raw)
        finally:
            srv.shutdown()


if __name__ == "__main__":
    unittest.main(verbosity=1)
