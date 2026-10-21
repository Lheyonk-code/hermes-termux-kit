"""Tes set_hermes_model.py (F-33/F-34) + health_check (C-3/F-28/F-30)."""
import json
import os
import pathlib
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

for _k in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY",
           "no_proxy", "NO_PROXY"):
    os.environ.pop(_k, None)

FAIL = []


def check(name, cond):
    print(("✓" if cond else "✗ GAGAL") + f" {name}")
    if not cond:
        FAIL.append(name)


KIT = str(pathlib.Path(__file__).resolve().parent.parent)
HH = pathlib.Path("/tmp/hh_f")
subprocess.run(["rm", "-rf", str(HH)])
HH.mkdir(parents=True)
(HH / "providers.yaml").write_text("""providers:
  - name: bariska
    base_url: https://api.bariska.cloud/v1
    api_key: "${BARISKA_API_KEY}"
    status: ok_via_proxy
    priority: 1
    fallback: false
    default_model: qwen3.8-flash
    models:
      - qwen3.8-flash
      - MiniMax-M3
""")
(HH / ".env").write_text("BARISKA_API_KEY=sk-x\n")

# --- config ala HP utama: provider bariska (rusak) + blok memory
cfg = HH / "config.yaml"
cfg.write_text("""model:
  api_key: "${BARISKA_API_KEY}"
  base_url: http://127.0.0.1:20129/v1
  default: qwen3.8-flash
  provider: bariska
memory:
  provider: ai-memory
""")
r = subprocess.run([sys.executable, f"{KIT}/tools/set_hermes_model.py",
                    "--config", str(cfg), "--providers", str(HH / "providers.yaml"),
                    "--base-url", "http://127.0.0.1:20129/v1"],
                   capture_output=True, text=True)
out = cfg.read_text()
check("set-model rc=0", r.returncode == 0)
check("provider jadi custom", "provider: custom" in out)
check("provider bariska hilang", "provider: bariska" not in out)
check("default dipertahankan (model utama chain)", "default: qwen3.8-flash" in out)
check("blok memory TIDAK tersentuh", "memory:\n  provider: ai-memory" in out)
check("api_key ref dipertahankan", 'api_key: "${BARISKA_API_KEY}"' in out)

# --- config kosong -> blok dibuat
cfg2 = HH / "config2.yaml"
r = subprocess.run([sys.executable, f"{KIT}/tools/set_hermes_model.py",
                    "--config", str(cfg2), "--providers", str(HH / "providers.yaml"),
                    "--base-url", "http://127.0.0.1:20128/v1"],
                   capture_output=True, text=True)
out2 = cfg2.read_text()
check("config baru: blok model dibuat (9router base)",
      "provider: custom" in out2 and "20128" in out2 and "default: qwen3.8-flash" in out2)

# ---------------------------------------------------------------- health
class Mock(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/v1/models":
            if self.server.server_address[1] == 18098:  # gaya Gemini native
                body = {"models": [{"name": "models/g1"}, {"name": "models/g2"},
                                   {"name": "models/g3"}]}
            else:  # gaya OpenAI
                body = {"data": [{"id": "m1"}, {"id": "m2"}]}
            data = json.dumps(body).encode()
            self.send_response(200)
        else:
            data = b"{}"
            self.send_response(404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(n)
        data = b'{"choices": []}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)

    def log_message(self, *a): pass


for port in (18098, 18099):
    threading.Thread(target=ThreadingHTTPServer(("127.0.0.1", port), Mock).serve_forever,
                     daemon=True).start()


def run_hc(providers_text, with_config=True):
    hh = pathlib.Path("/tmp/hh_hc")
    subprocess.run(["rm", "-rf", str(hh)])
    hh.mkdir(parents=True)
    (hh / "providers.yaml").write_text(providers_text)
    (hh / ".env").write_text("K1=sk-1234567890\nK2=sk-1234567890\n")
    if with_config:
        (hh / "config.yaml").write_text("model:\n  provider: custom\n")
    env = dict(os.environ, HERMES_HOME=str(hh))
    r = subprocess.run([sys.executable, f"{KIT}/health_check.py", "--json", "--chat"],
                       env=env, capture_output=True, text=True)
    try:
        d = json.loads(r.stdout[r.stdout.index("{"):])
    except Exception:
        d = {}
    return r.returncode, d


# Gemini-shape /models -> listed harus 3 (F-28), provider model-less -> tidak sehat (F-30)
rc, d = run_hc("""providers:
  - name: gem
    base_url: http://127.0.0.1:18098/v1
    api_key: "${K1}"
    priority: 1
    fallback: false
    default_model: g1
    models: [g1]
  - name: nomodel
    base_url: http://127.0.0.1:18099/v1
    api_key: "${K2}"
    priority: 2
    fallback: false
""")
by = {p["name"]: p for p in d.get("providers", [])}
check("F-28: /models gaya Gemini terhitung (listed=3)", by.get("gem", {}).get("listed") == 3)
check("F-28: provider Gemini sehat", by.get("gem", {}).get("healthy") is True)
check("F-30: provider tanpa model TIDAK sehat", by.get("nomodel", {}).get("healthy") is False)
check("C-3: rc=1 karena ada must_fix", rc == 1 and "nomodel" in d.get("must_fix", []))

# nol provider -> rc 1 (C-3 sehat palsu)
rc, d = run_hc("providers:\n")
check("C-3: nol provider -> rc=1 + struktural", rc == 1 and bool(d.get("structural")))

# config hilang -> rc 1 walau provider sehat
rc, d = run_hc("""providers:
  - name: gem
    base_url: http://127.0.0.1:18098/v1
    api_key: "${K1}"
    priority: 1
    fallback: false
    default_model: g1
    models: [g1]
""", with_config=False)
check("C-3: config hilang -> rc=1", rc == 1 and any("config" in s for s in d.get("structural", [])))

# semua sehat + config ada -> rc 0
rc, d = run_hc("""providers:
  - name: gem
    base_url: http://127.0.0.1:18098/v1
    api_key: "${K1}"
    priority: 1
    fallback: false
    default_model: g1
    models: [g1]
""")
check("sehat penuh -> rc=0", rc == 0 and d.get("ok") is True)

print("\nHASIL:", "SEMUA LULUS" if not FAIL else f"GAGAL: {FAIL}")
sys.exit(1 if FAIL else 0)
