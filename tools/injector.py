#!/usr/bin/env python3
"""injector.py — proxy OpenAI-compatible kecil untuk provider chain Hermes.

Tugasnya cuma satu: jadi pintu tunggal (:20129) ke provider chain di
`providers.yaml`, dengan tiga hal yang `hermes serve` tidak berikan:

  1. **Kredensial dari `${VAR}`** — nilai `api_key` di providers.yaml boleh
     literal, atau `"${NAMA_VAR}"` yang dibaca dari env proses lalu
     `~/.hermes/.env` (chmod 600). Nol key plaintext nyasar di repo.
  2. **Isi ulang saat jatuh** — provider dengan `fallback: true` dipakai kalau
     provider prioritas di atasnya gagal (HTTP error / koneksi mati).
  3. **Bisa dicek tanpa buka kunci** — `GET /health` melaporkan upstream aktif,
     tinggi/rendahnya tiap provider, dan chain-nya. Cocok untuk cron.

Dipakai sebagai base_url oleh klien apa pun yang bicara OpenAI API
(`http://127.0.0.1:20129/v1`) — termasuk Hermes kalau mau dialihkan.

Pakai:
    python3 tools/injector.py serve                 # service (default :20129)
    python3 tools/injector.py chat -m "halo"        # sekali jalan
    python3 tools/injector.py providers             # daftar chain + status
    python3 tools/injector.py env-check             # cek resolusi key

Semua tanpa dependency luar: parser providers.yaml ditulis manual karena venv
Hermes di Termux tidak bawa pyyaml (lihat tools di repo syadagentic untuk
asal-usul parser yang sama).
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import socket
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "1.0.0"
HOME = pathlib.Path.home()
HERMES_HOME = pathlib.Path(os.environ.get("HERMES_HOME", HOME / ".hermes"))
ENV_FILE = HERMES_HOME / ".env"
DEFAULT_PROVIDERS = HERMES_HOME / "providers.yaml"
PORT_DEFAULT = 20129
VERBOSE = True

# Diisi saat startup (atau per-provider saat fallback). Kosong = jalur langsung.
PROXY_URL = ""


def log(*a) -> None:
    if VERBOSE:
        sys.stderr.write("[injector] " + " ".join(str(x) for x in a) + "\n")
        sys.stderr.flush()


# --------------------------------------------------------------------------
# Kredensial: env proses menang, `~/.hermes/.env` sebagai sumber kedua.
# --------------------------------------------------------------------------
def load_env_file() -> dict[str, str]:
    out: dict[str, str] = {}
    if ENV_FILE.exists():
        for raw in ENV_FILE.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def resolve_secret(value: str) -> tuple[str, bool]:
    """`"${VAR}"` → nilai VAR. Kembalikan (nilai, apakah_kosong_karena_var_hilang)."""
    v = (value or "").strip()
    if v.startswith("${") and v.endswith("}"):
        name = v[2:-1].strip()
        got = os.environ.get(name) or load_env_file().get(name, "")
        return got, not bool(got)
    return v, False


# --------------------------------------------------------------------------
# providers.yaml — parser minimal (tanpa pyyaml)
# --------------------------------------------------------------------------
def parse_providers(path: pathlib.Path) -> list[dict]:
    if not path.exists():
        return []
    provs: list[dict] = []
    cur: dict | None = None
    lst_key: str | None = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        if raw.lstrip().startswith("#") or not raw.strip():
            continue
        indent = len(raw) - len(raw.lstrip())
        s = raw.strip()
        if indent <= 2 and s.startswith("- name:"):
            if cur:
                provs.append(cur)
            cur = {"name": s.split(":", 1)[1].strip().strip('"'), "models": []}
            lst_key = None
            continue
        if cur is None:
            continue
        if s.startswith("- ") and lst_key:
            cur.setdefault(lst_key, []).append(s[2:].strip().strip('"'))
            continue
        if ":" not in s:
            continue
        k, v = s.split(":", 1)
        k, v = k.strip(), v.strip().strip('"')
        if not v:
            lst_key = k
            cur.setdefault(k, [])
            continue
        lst_key = None
        cur[k] = v
    if cur:
        provs.append(cur)

    for p in provs:
        try:
            p["priority"] = int(p.get("priority", 999))
        except (TypeError, ValueError):
            p["priority"] = 999
        p["fallback"] = str(p.get("fallback", "false")).lower() in ("1", "true", "yes")
        p["api_key"], missing = resolve_secret(p.get("api_key", ""))
        p["key_missing"] = missing
    provs.sort(key=lambda x: x.get("priority", 999))
    return provs


class Pool:
    """Provider chain + tinggi/rendahnya masing-masing."""

    def __init__(self, path: pathlib.Path):
        self.path = path
        self._lock = threading.Lock()
        self.health: dict[str, dict] = {}
        self.reload()

    def reload(self) -> None:
        with self._lock:
            self.provs = parse_providers(self.path)

    def base_url(self) -> str:
        p = self.primary()
        return (p or {}).get("base_url", "")

    def primary(self) -> dict | None:
        utama = [p for p in self.provs if not p.get("fallback")]
        return (utama or self.provs or [None])[0]

    def chain(self) -> list[dict]:
        """Provider non-fallback dulu (urut priority), lalu fallback (urut priority)."""
        hidup = [p for p in self.provs if not p.get("fallback")]
        cadangan = [p for p in self.provs if p.get("fallback")]
        return hidup + cadangan

    def mark(self, name: str, ok: bool, code: int = 0, err: str = "", latency: float = 0.0) -> None:
        with self._lock:
            self.health[name] = {"ok": ok, "code": code, "err": err[:200],
                                 "latency": round(latency, 2), "at": time.time()}

    def health_for(self, can_refresh_s: float = 30.0) -> dict:
        """Health per provider; kalau data lebih tua dari can_refresh_s, uji ulang ringan."""
        now = time.time()
        out = {}
        for p in self.chain():
            name = p["name"]
            h = self.health.get(name)
            if h and now - h.get("at", 0) > can_refresh_s:
                h = dict(h, age_s=round(now - h["at"], 1))
            elif h:
                h = dict(h, age_s=round(now - h["at"], 1))
            else:
                h = {"ok": None, "code": 0, "err": "", "latency": 0.0, "age_s": None}
            if p.get("key_missing"):
                h["ok"] = False
                h["err"] = "api_key kosong (VAR tidak ketemu di env/.env)"
            out[name] = dict(h, priority=p.get("priority"), fallback=p.get("fallback", False))
        return out


POOL: Pool | None = None


# --------------------------------------------------------------------------
# HTTP ke upstream
# --------------------------------------------------------------------------
def _opener(proxy: str | None = None) -> urllib.request.OpenerDirector:
    """Opener untuk satu panggilan upstream.

    `proxy` adalah proxy milik provider itu sendiri (field `proxy:` di
    providers.yaml). None = pakai proxy global (--proxy); string kosong =
    langsung tanpa proxy. Field per-provider selalu menang atas global,
    supaya satu provider yang butuh proxy (mis. IP-nya diblokir) tidak
    menyeret provider lain ikut lewat proxy.
    """
    eff = PROXY_URL if proxy is None else proxy
    if eff:
        return urllib.request.build_opener(
            urllib.request.ProxyHandler({"http": eff, "https": eff}))
    return urllib.request.build_opener(urllib.request.ProxyHandler({}))


def upstream_call(pv: dict, path: str, body: dict | None = None,
                  method: str = "POST", timeout: int = 180) -> tuple[int, str, float]:
    base = (pv.get("base_url") or "").rstrip("/")
    url = base + path
    key = pv.get("api_key") or ""
    if not key:
        raise RuntimeError(f"{pv.get('name')}: api_key kosong (cek ~/.hermes/.env)")
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", f"Bearer {key}")
    t0 = time.time()
    try:
        with _opener(pv.get("proxy")).open(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace"), time.time() - t0
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace"), time.time() - t0


def probe_provider(pv: dict, timeout: int = 20) -> dict:
    """Uji ringan: GET /models. Dipakai health check & pemilihan provider."""
    if pv.get("key_missing"):
        return {"ok": False, "code": 0, "latency": 0.0, "err": "api_key kosong"}
    try:
        st, _, dt = upstream_call(pv, "/models", method="GET", timeout=timeout)
    except Exception as e:
        return {"ok": False, "code": 0, "latency": 0.0, "err": str(e)}
    return {"ok": st == 200, "code": st, "latency": dt, "err": "" if st == 200 else "models ditolak"}


def infer_model(pv: dict) -> str:
    """Tentukan model provider ini: `default_model`, else entri pertama `models`."""
    return pv.get("default_model") or next(iter(pv.get("models") or []), "")


def forward(path: str, body: dict, timeout: int, echo: bool = False) -> tuple[int, dict]:
    """Teruskan body ke provider pertama yang menjawab 2xx; kalau gagal, coba berikutnya.

    Model diganti ke model milik provider tujuan (bukan provider utama) supaya
    nama model antar provider tidak tertukar saat `fallback: true` dipakai.
    """
    assert POOL is not None
    chain = POOL.chain()
    if not chain:
        return 502, {"error": {"message": "providers.yaml kosong / tidak ketemu",
                               "type": "injector_error"}}
    last: tuple[int, object] = 502, {"error": {"message": "tidak ada provider yang menjawab"}}
    prim = (POOL.primary() or {}).get("base_url", "")
    for i, pv in enumerate(chain):
        payload = dict(body)
        dm = infer_model(pv)
        if dm:
            payload["model"] = dm
        elif pv.get("base_url", "") != prim:
            return 502, {"error": {
                "message": f"{pv['name']}: tidak ada model (`default_model`/`models` kosong di providers.yaml)",
                "type": "injector_error"}}
        try:
            st, text, dt = upstream_call(pv, path, payload, timeout=timeout)
        except Exception as e:
            log(f"gagal {pv['name']}: {e}")
            POOL.mark(pv["name"], False, 0, str(e))
            last = 502, {"error": {"message": f"{pv['name']}: {e}", "type": "injector_upstream"}}
            continue
        POOL.mark(pv["name"], 200 <= st < 300, st, "" if st < 400 else text[:200], dt)
        if 200 <= st < 300:
            try:
                out = json.loads(text)
            except json.JSONDecodeError:
                return 502, {"error": {"message": f"balasan {pv['name']} bukan JSON",
                                       "type": "injector_upstream", "raw": text[:500]}}
            if echo:
                out["_injector"] = {"upstream": pv["name"], "latency_s": round(dt, 2),
                                    "attempt": i + 1, "chain": [p["name"] for p in chain]}
            log(f"{pv['name']} → {st} ({dt:.2f}s)")
            return st, out
        log(f"{pv['name']} → {st}, coba provider berikutnya")
        try:
            last = st, json.loads(text)
        except json.JSONDecodeError:
            last = st, {"error": {"message": text[:500], "type": "injector_upstream"}}
    return last  # type: ignore[return-value]


# --------------------------------------------------------------------------
# Server OpenAI-compatible
# --------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = f"injector/{VERSION}"

    def log_message(self, fmt, *args):  # rapi di stderr, bukan stdout
        log(f"{self.address_string()} {fmt % args}")

    def _send(self, code: int, obj: object) -> None:
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self) -> dict:
        n = int(self.headers.get("Content-Length") or 0)
        if not n:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode())
        except json.JSONDecodeError:
            return {}

    # --- GET ---------------------------------------------------------------
    def do_GET(self) -> None:  # noqa: N802
        assert POOL is not None
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path in ("/health", "/healthz"):
            prim = POOL.primary() or {}
            self._send(200, {
                "status": "ok" if prim else "no_provider",
                "service": "hermes-termux-kit-injector",
                "version": VERSION,
                "port": self.server.server_address[1],
                "providers_file": str(POOL.path),
                "upstream": prim.get("base_url", ""),
                "model": prim.get("default_model", ""),
                "provider_health": POOL.health_for(),
                "fallback_chain": [p["name"] for p in POOL.chain()],
                "proxy": PROXY_URL or None,
            })
            return
        if path == "/v1/models":
            prim = POOL.primary() or {}
            models = prim.get("models") or ([prim["default_model"]] if prim.get("default_model") else [])
            self._send(200, {"object": "list",
                             "data": [{"id": m, "object": "model", "owned_by": prim.get("name", "")}
                                      for m in models]})
            return
        self._send(404, {"error": {"message": f"rute tidak ada: {path}", "type": "injector_error"}})

    # --- POST --------------------------------------------------------------
    def do_POST(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0].rstrip("/")
        if path not in ("/v1/chat/completions", "/chat/completions"):
            self._send(404, {"error": {"message": f"rute tidak ada: {path}", "type": "injector_error"}})
            return
        body = self._body()
        if not body.get("messages"):
            self._send(400, {"error": {"message": "butuh `messages`", "type": "injector_error"}})
            return
        if not body.get("max_tokens"):
            body["max_tokens"] = 4096
        if "temperature" not in body:
            body["temperature"] = 1.0
        echo = str(self.headers.get("X-Injector-Echo", "")).lower() in ("1", "true", "yes")
        timeout = int(self.headers.get("X-Injector-Timeout") or 180)
        code, out = forward("/chat/completions", body, timeout=timeout, echo=echo)
        self._send(code, out)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------
def _pick_from_args(args) -> tuple[pathlib.Path, str, str, str]:
    """(providers_path, base_url, key, model) — argumen menang, sisanya dari providers.yaml."""
    path = pathlib.Path(args.providers)
    provs = parse_providers(path)
    prim = next((p for p in provs if not p.get("fallback")), provs[0] if provs else {})
    base = args.base_url or prim.get("base_url", "")
    key = args.api_key or prim.get("api_key", "")
    model = args.model or prim.get("default_model", "")
    return path, base, key, model


def cmd_serve(args) -> int:
    global POOL, PROXY_URL, VERBOSE
    VERBOSE = not args.quiet
    POOL = Pool(pathlib.Path(args.providers))
    if not POOL.provs:
        log(f"PERINGATAN: {args.providers} kosong/tidak ada — server jalan tapi tiap request 502")
    prim = POOL.primary() or {}
    PROXY_URL = args.proxy or ""
    log(f"upstream: {prim.get('base_url', '-')} (provider {prim.get('name', '-')})")
    if prim.get("key_missing"):
        log(f"PERINGATAN: key provider {prim.get('name')} kosong — isi {ENV_FILE}")
    if PROXY_URL:
        log(f"via proxy: {PROXY_URL}")
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    log(f"dengar di http://127.0.0.1:{args.port}/v1  (mode: passthrough)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        log("berhenti")
    return 0


def cmd_chat(args) -> int:
    global PROXY_URL, POOL
    path, base, key, model = _pick_from_args(args)
    POOL = Pool(path)
    PROXY_URL = args.proxy or ""
    prompt = args.message if isinstance(args.message, str) else " ".join(args.message)
    pv = POOL.primary() or {}
    if not pv.get("base_url"):
        pv = {"name": "cli", "base_url": base, "api_key": key, "default_model": model}
    body = {"model": model or pv.get("default_model", ""),
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": args.max_tokens, "temperature": args.temperature}
    code, out = forward("/chat/completions", body, timeout=args.timeout, echo=True)
    if code >= 400:
        print(json.dumps(out, indent=2, ensure_ascii=False))
        return 1
    meta = out.get("_injector", {})
    choices = out.get("choices") or [{}]
    print(choices[0].get("message", {}).get("content", ""))
    print(f"\n[upstream={meta.get('upstream')} {meta.get('latency_s')}s "
          f"attempt={meta.get('attempt')}]", file=sys.stderr)
    return 0


def cmd_providers(args) -> int:
    provs = parse_providers(pathlib.Path(args.providers))
    if not provs:
        print(f"tidak ada provider di {args.providers}")
        return 1
    for p in provs:
        mark = "cadangan" if p.get("fallback") else "utama"
        key = "KOSONG" if p.get("key_missing") else f"len={len(p.get('api_key') or '')}"
        print(f"{p.get('priority'):>3}  {p.get('name'):<16} {mark:<9} {p.get('base_url',''):<28} "
              f"key {key:<10} model {p.get('default_model','-')}")
    return 0


def cmd_env_check(args) -> int:
    env = load_env_file()
    print(f"env file: {ENV_FILE} ({'ada' if ENV_FILE.exists() else 'TIDAK ADA'})")
    if ENV_FILE.exists():
        print(f"mode    : {oct(ENV_FILE.stat().st_mode & 0o777)} (harus 0o600)")
    print(f"variabel: {len(env)} entri")
    provs = parse_providers(pathlib.Path(args.providers))
    bad = 0
    for p in provs:
        raw = ""
        for line in pathlib.Path(args.providers).read_text(encoding="utf-8").splitlines():
            if f"name: {p['name']}" in line:
                break
        if p.get("key_missing"):
            bad += 1
            print(f"  ✗ {p['name']}: api_key ${'{VAR}'} tidak ketemu di env/.env")
        else:
            src = "literal" if not raw else "env"
            print(f"  ✓ {p['name']}: key ok (len={len(p.get('api_key') or '')}, {src})")
    return 1 if bad else 0


def cmd_health(args) -> int:
    pool = Pool(pathlib.Path(args.providers))
    res = {}
    for p in pool.chain():
        r = probe_provider(p, timeout=args.timeout)
        res[p["name"]] = dict(r, priority=p.get("priority"), fallback=p.get("fallback", False))
    print(json.dumps(res, indent=2, ensure_ascii=False))
    return 0 if any(v["ok"] for v in res.values()) else 1


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="injector.py",
                                 description="Proxy OpenAI-compatible untuk provider chain Hermes.")
    ap.add_argument("--providers", default=str(DEFAULT_PROVIDERS),
                    help=f"path providers.yaml (default: {DEFAULT_PROVIDERS})")
    sub = ap.add_subparsers(dest="cmd")

    s = sub.add_parser("serve", help="jalankan server (default)")
    s.add_argument("-p", "--port", type=int, default=PORT_DEFAULT)
    s.add_argument("--proxy", default="", help="HTTP proxy upstream (kosong = langsung)")
    s.add_argument("-q", "--quiet", action="store_true")
    s.set_defaults(func=cmd_serve)

    c = sub.add_parser("chat", help="kirim satu prompt lewat chain")
    c.add_argument("-m", "--message", nargs="+", required=True)
    c.add_argument("--base-url", default="")
    c.add_argument("--api-key", default="")
    c.add_argument("--model", default="")
    c.add_argument("--proxy", default="")
    c.add_argument("--max-tokens", type=int, default=1024)
    c.add_argument("--temperature", type=float, default=1.0)
    c.add_argument("--timeout", type=int, default=180)
    c.set_defaults(func=cmd_chat)

    sub.add_parser("providers", help="daftar chain + prioritas").set_defaults(func=cmd_providers)
    sub.add_parser("env-check", help="cek resolusi key ${VAR} dari ~/.hermes/.env").set_defaults(func=cmd_env_check)
    h = sub.add_parser("health", help="uji hidup tiap provider (GET /models)")
    h.add_argument("--timeout", type=int, default=20)
    h.set_defaults(func=cmd_health)
    return ap


def main() -> int:
    ap = build_parser()
    args = ap.parse_args()
    if not getattr(args, "func", None):
        args = ap.parse_args([*(sys.argv[1:]), "serve"] if "serve" not in sys.argv[1:] else sys.argv[1:])
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
