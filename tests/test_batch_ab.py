"""Tes Batch A+B: scrub aman (rotate_keys) + injector (C-10, E-2, F-32, T-1)."""
import importlib.util
import json
import os
import pathlib
import sqlite3
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import urllib.request

for _k in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY",
           "no_proxy", "NO_PROXY"):
    os.environ.pop(_k, None)

FAIL = []


def check(name, cond):
    print(("✓" if cond else "✗ GAGAL") + f" {name}")
    if not cond:
        FAIL.append(name)


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


# ---------------------------------------------------------------- scrub
ROOT = pathlib.Path("/tmp/scrubtest")
sub = subprocess.run(["rm", "-rf", str(ROOT)])
ROOT.mkdir(parents=True)
(ROOT / ".hermes").mkdir()
KEY = "sk-OLDKEY-1234567890"
(ROOT / "note.txt").write_text(f"key lama: {KEY}\n")
db = ROOT / ".hermes" / "state.db"
con = sqlite3.connect(db)
con.execute("CREATE TABLE msgs (id INTEGER, body TEXT)")
con.execute("INSERT INTO msgs VALUES (1, ?)", (f"halo {KEY} halo",))
con.commit(); con.close()
raw_bin = os.urandom(2048)
binf = ROOT / "blob.bin"
binf.write_bytes(raw_bin[:1000] + KEY.encode() + raw_bin[1000:])
(ROOT / "cache.pyc").write_bytes(b"\x42\x0d\x0d\x0a" + KEY.encode())
outside = pathlib.Path("/tmp/scrubtest_outside.txt")
outside.write_text(f"di luar root: {KEY}")
(ROOT / "link.txt").symlink_to(outside)

env = dict(os.environ, HERMES_HOME=str(ROOT / ".hermes"),
           ROTATE_SCRUB_ROOT=str(ROOT))
r = subprocess.run([sys.executable, "/tmp/kit-r/rotate_keys.py",
                    "--scrub", "--old", KEY],
                   env=env, capture_output=True, text=True)
check("scrub exit 0", r.returncode == 0)
check("file teks ter-redact", KEY not in (ROOT / "note.txt").read_text())
con = sqlite3.connect(db)
row = con.execute("SELECT body FROM msgs WHERE id=1").fetchone()[0]
ic = con.execute("PRAGMA integrity_check").fetchone()[0]
con.close()
check("DB: key diganti via SQL", KEY not in row and "REDACTED" in row)
check("DB: integrity ok", ic == "ok")
new_bin = binf.read_bytes()
expect = raw_bin[:1000] + b"REDACTED-ROTATE-ME" + raw_bin[1000:]
check("file biner: byte lain utuh 100%", new_bin == expect)
check(".pyc dihapus", not (ROOT / "cache.pyc").exists())
check("symlink TIDAK diikuti (target utuh)", KEY in outside.read_text())

# ---------------------------------------------------------------- C-10
seen = {}


class SrvB(BaseHTTPRequestHandler):
    def do_GET(self):
        seen["B_auth"] = self.headers.get("Authorization")
        body = b'{"data": []}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


class SrvA(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/cross":
            self.send_response(302)
            self.send_header("Location", "http://127.0.0.1:18093/models")
            self.end_headers()
        elif self.path == "/same":
            self.send_response(302)
            self.send_header("Location", "/final")
            self.end_headers()
        elif self.path == "/final":
            seen["A_auth"] = self.headers.get("Authorization")
            body = b'{"data": []}'
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


threading.Thread(target=ThreadingHTTPServer(("127.0.0.1", 18092), SrvA).serve_forever, daemon=True).start()
threading.Thread(target=ThreadingHTTPServer(("127.0.0.1", 18093), SrvB).serve_forever, daemon=True).start()

inj = load("injector", "/tmp/kit-r/tools/injector.py")
inj.PROXY_URL = ""
pvA = {"name": "a", "base_url": "http://127.0.0.1:18092", "api_key": "SECRETKEY"}
st, _, _ = inj.upstream_call(pvA, "/cross", method="GET", timeout=5)
check("redirect lintas origin: sampai (200)", st == 200)
check("redirect lintas origin: Authorization DIBUANG", seen.get("B_auth") is None)
st, _, _ = inj.upstream_call(pvA, "/same", method="GET", timeout=5)
check("redirect satu origin: Authorization dipertahankan",
      seen.get("A_auth") == "Bearer SECRETKEY")

# ---------------------------------------------------------------- E-2/F-32
got_models = []


class Up(BaseHTTPRequestHandler):
    def _go(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        got_models.append((self.server.server_address[1], body.get("model")))
        if self.server.server_address[1] == 18094:
            code, out = 500, {"error": "boom"}
        else:
            code, out = 200, {"choices": [{"message": {"content": "ok"}}],
                              "model": body.get("model")}
        data = json.dumps(out).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)

    do_POST = _go
    do_GET = _go

    def log_message(self, *a): pass


for port in (18094, 18095, 18096):
    threading.Thread(target=ThreadingHTTPServer(("127.0.0.1", port), Up).serve_forever, daemon=True).start()

yaml_p = pathlib.Path("/tmp/fwd_providers.yaml")
yaml_p.write_text("""providers:
  - name: satu
    base_url: http://127.0.0.1:18095/v1
    api_key: "k1"
    priority: 1
    fallback: false
    default_model: def-satu
    models: [m-pilih, def-satu]
""")
inj.POOL = inj.Pool(yaml_p)
got_models.clear()
code, _, _raw = inj.forward("/chat/completions",
                      {"model": "m-pilih", "messages": [{"role": "user", "content": "x"}]}, 5)
check("E-2: model pilihan klien yang terdaftar DIHORMATI", got_models[0][1] == "m-pilih")
got_models.clear()
code, _, _raw = inj.forward("/chat/completions",
                      {"model": "asing", "messages": [{"role": "user", "content": "x"}]}, 5)
check("E-2: model asing diganti default_model provider", got_models[0][1] == "def-satu")

yaml_p.write_text("""providers:
  - name: gagal
    base_url: http://127.0.0.1:18094/v1
    api_key: "k1"
    priority: 1
    fallback: false
    default_model: def-gagal
    models: [def-gagal]
  - name: kosong
    base_url: http://127.0.0.1:18097/v1
    api_key: "k2"
    priority: 2
    fallback: false
  - name: penolong
    base_url: http://127.0.0.1:18096/v1
    api_key: "k3"
    priority: 3
    fallback: false
    default_model: def-tolong
    models: [def-tolong]
""")
inj.POOL = inj.Pool(yaml_p)
code, out, _raw = inj.forward("/chat/completions",
                        {"messages": [{"role": "user", "content": "x"}]}, 5)
check("F-32c: provider tanpa model DILEWATI, rantai selamat (200 dari penolong)",
      code == 200)

# F-32b: health_for memicu probe latar saat data basi
inj.POOL.mark("penolong", False, 0, "basi", 0.0)
inj.POOL.health["penolong"]["at"] = time.time() - 999
inj.POOL.health_for()
time.sleep(1.0)
h = inj.POOL.health.get("penolong") or {}
check("F-32b: health basi di-probe ulang di latar", h.get("ok") in (True, False) and h.get("at", 0) > time.time() - 5)

# T-1: label env vs literal
provs = inj.parse_providers(yaml_p)
lbl = {p["name"]: p.get("api_key_is_ref") for p in provs}
check("T-1: api_key_is_ref False untuk literal", lbl.get("gagal") is False)

print("\nHASIL:", "SEMUA LULUS" if not FAIL else f"GAGAL: {FAIL}")
sys.exit(1 if FAIL else 0)
