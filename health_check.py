#!/usr/bin/env python3
"""health_check.py — cek sehat provider chain + layanan Hermes.

Untuk setiap provider di providers.yaml:
  * resolusi key (${VAR} dari ~/.hermes/.env atau env proses)
  * GET {base_url}/models        → endpoint hidup + key diterima
  * POST /chat/completions       → benar-benar bisa dipakai (opsional --chat)
  * RTT + status, urut priority

Untuk Hermes sendiri:
  * binary + versi, config.yaml ada, .env mode 600
  * gateway AKTIF saja (pilihan pengguna, terbaca dari ~/.hermes/gateway.mode):
    - injector (default) : status service runsv `injector`
    - 9router            : status service runsv `9router` + HTTP :20128
    Gateway yang TIDAK terpilih tidak dicek — tidak dianggap gagal/merah.
  * ai-memory (opsional): hanya dicek kalau dipasang (~/.hermes/aimemory.mode
    = "yes", ditulis install.sh) — service runsv `ai-memory` + HTTP :49374.
    Kalau tidak dipilih, service yang absen = "tidak dipilih": dilewati,
    netral, TIDAK dihitung gagal/merah.
  * smoke test `hermes -z` (opsional --smoke)

Exit code: 0 = semua provider utama sehat, 1 = ada yang merah.
Cocok dipakai sebagai cron / gate sebelum menganggap instalasi sehat.

Pakai:
  python3 health_check.py                        # semua provider, tanpa chat test
  python3 health_check.py --chat                 # + uji chat/completions (1 token)
  python3 health_check.py --smoke                # + `hermes -z` end-to-end
  python3 health_check.py --json                 # keluaran mesin (cron/monitoring)
  python3 health_check.py --timeout 8 --retries 2
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

HOME = pathlib.Path.home()
HERMES_HOME = pathlib.Path(os.environ.get("HERMES_HOME", HOME / ".hermes"))
ENV_FILE = HERMES_HOME / ".env"  # health check boleh bind saat import (read-only)
GATEWAY_FILE = HERMES_HOME / "gateway.mode"  # ditulis install.sh: injector|9router
AIMEMORY_FILE = HERMES_HOME / "aimemory.mode"  # ditulis install.sh: yes|no (opsional)


def detect_aimemory() -> bool:
    """True hanya kalau ai-memory memang DIPASANG (install.sh: ~/.hermes/aimemory.mode = yes).

    Service ai-memory yang absen TANPA pilihan ini berarti "tidak dipilih" —
    dilewati, netral, tidak pernah dihitung gagal/merah.
    """
    try:
        return AIMEMORY_FILE.read_text(encoding="utf-8").strip().lower() == "yes"
    except OSError:
        return False


def detect_gateway(explicit: str | None = None) -> str:
    """Gateway aktif: --gateway > ~/.hermes/gateway.mode > injector (default)."""
    if explicit in ("injector", "9router"):
        return explicit
    try:
        g = GATEWAY_FILE.read_text(encoding="utf-8").strip().splitlines()
        if g and g[0].strip() in ("injector", "9router"):
            return g[0].strip()
    except OSError:
        pass
    return "injector"


def find_providers(explicit: str | None = None) -> pathlib.Path:
    """Cari providers.yaml: eksplisit → $HERMES_HOME → syadagentic/ → repo kit."""
    if explicit:
        return pathlib.Path(explicit)
    cands = [HERMES_HOME / "providers.yaml",
             HERMES_HOME / "syadagentic" / "providers.yaml",
             pathlib.Path(__file__).resolve().parent / "providers.yaml"]
    for c in cands:
        if c.exists():
            return c
    return cands[0]


DEFAULT_PROVIDERS = find_providers()


# --- util ------------------------------------------------------------------
def load_env_file(path: pathlib.Path = ENV_FILE) -> dict[str, str]:
    out: dict[str, str] = {}
    if path.exists():
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def resolve_secret(value: str, env: dict[str, str]) -> str:
    """"${VAR}" → env proses dulu, lalu ~/.hermes/.env."""
    v = (value or "").strip()
    if v.startswith("${") and v.endswith("}"):
        name = v[2:-1].strip()
        return os.environ.get(name) or env.get(name, "")
    return v


def parse_providers(path: pathlib.Path) -> list[dict]:
    """Parser minimal (tanpa pyyaml) — format sama dengan tools/injector.py."""
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
        m = re.match(r"^([A-Za-z_]+):\s*(.*)$", s)
        if m and not s.startswith("- "):
            k, v = m.group(1), m.group(2).strip().strip('"')
            cur[k] = v
            lst_key = k if v == "" else None
            continue
        if s.startswith("- ") and lst_key:
            cur.setdefault(lst_key, [])
            if isinstance(cur[lst_key], list):
                cur[lst_key].append(s[2:].strip().strip('"'))
    if cur:
        provs.append(cur)
    for p in provs:
        try:
            p["priority"] = int(p.get("priority", 999))
        except (TypeError, ValueError):
            p["priority"] = 999
    provs.sort(key=lambda x: x["priority"])
    return provs


def http(url: str, key: str, timeout: float, payload: dict | None = None,
         proxy: str | None = None):
    """Kembalikan (status, body_text, detik). status None = error jaringan.

    proxy: URL proxy utk provider yang memang butuh (mis. socks5h://127.0.0.1:20130).
    Hanya dipakai kalau diisi di providers.yaml — tidak ada Tor default.
    """
    data = json.dumps(payload).encode() if payload else None
    req = urllib.request.Request(url, data=data, method="POST" if data else "GET")
    req.add_header("Authorization", f"Bearer {key}")
    if data:
        req.add_header("Content-Type", "application/json")
    opener = None
    if proxy:
        # socks5h:// didukung kalau PySocks terpasang; http:// proxy selalu bisa.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({"http": proxy, "https": proxy}))
    t0 = time.time()
    try:
        ctx = opener.open(req, timeout=timeout) if opener else urllib.request.urlopen(req, timeout=timeout)
        with ctx as r:
            return r.status, r.read(4096).decode("utf-8", "ignore"), time.time() - t0
    except urllib.error.HTTPError as e:
        return e.code, (e.read(2048).decode("utf-8", "ignore") if e.fp else ""), time.time() - t0
    except Exception as e:
        return None, f"{type(e).__name__}: {e}", time.time() - t0


# --- checks ----------------------------------------------------------------
def check_provider(p: dict, env: dict, timeout: float, retries: int, chat: bool) -> dict:
    name = p.get("name", "?")
    base = (p.get("base_url") or "").rstrip("/")
    key = resolve_secret(p.get("api_key", ""), env)
    models = [m for m in (p.get("models") or []) if m]
    proxy = (p.get("proxy") or "").strip() or None
    res = {"name": name, "base_url": base, "status": p.get("status", ""), "proxy": proxy,
           "key_present": len(key) > 8, "key_len": len(key), "models": len(models),
           "listed": None, "chat": None, "rtt": None, "healthy": False, "note": ""}

    if not base:
        res["note"] = "base_url kosong"; return res
    if not res["key_present"]:
        res["note"] = "key tidak teresolusi (cek .env)"; return res

    status = body = None; rtt = None
    for attempt in range(max(1, retries)):
        status, body, rtt = http(f"{base}/models", key, timeout, proxy=proxy)
        if status is not None:
            break
        time.sleep(min(2 ** attempt, 5))
    res["rtt"] = round(rtt, 2) if rtt else None

    if status is None:
        res["note"] = f"jaringan: {body[:80]}"; return res
    if status in (401, 403):
        if res["status"] in ("ok_via_proxy",) and not proxy:
            res["note"] = f"HTTP {status} — provider ini butuh proxy; isi field `proxy` di providers.yaml"
        elif res["status"] in ("blocked_ip_403", "blocked"):
            res["note"] = f"HTTP {status} (diketahui: diblok dari IP ini)"
        else:
            res["note"] = f"HTTP {status} — key ditolak / IP diblok"
        return res
    if status >= 400:
        res["note"] = f"HTTP {status}"; return res

    try:
        data = json.loads(body) if body.strip().startswith(("{", "[")) else {}
        n = len(data.get("data", data if isinstance(data, list) else []) or [])
        res["listed"] = n
    except Exception:
        res["listed"] = 0

    if chat and models:
        st, _, rt = http(f"{base}/chat/completions", key, max(timeout, 30),
                         {"model": models[0], "messages": [{"role": "user", "content": "ping"}],
                          "max_tokens": 5}, proxy=proxy)
        res["chat"] = {"status": st, "rtt": round(rt, 2), "model": models[0]}
        if st is None or st >= 400:
            res["note"] = f"/models OK tapi chat gagal (HTTP {st})"
            return res
    res["healthy"] = True
    return res


def check_9router_http(timeout: float = 5.0) -> str | None:
    """Probe HTTP dashboard 9Router :20128. 'up' / 'down' (None = bukan mode 9router)."""
    try:
        with urllib.request.urlopen("http://127.0.0.1:20128/", timeout=timeout) as r:
            return "up" if r.status < 500 else "down"
    except Exception:
        return "down"


def check_aimemory_http(timeout: float = 5.0) -> str | None:
    """Probe HTTP server ai-memory :49374 (hanya dipanggil kalau dipasang).
    'up' / 'down'."""
    try:
        req = urllib.request.Request("http://127.0.0.1:49374/", method="GET")
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return "up" if r.status < 500 else "down"
    except urllib.error.HTTPError:
        # HTTP error = server hidup dan merespons (endpoint MCP bukan GET biasa)
        return "up"
    except Exception:
        return "down"


def check_hermes(smoke: bool, timeout: float, gateway: str = "injector",
                 aimemory: bool = False) -> dict:
    out = {"binary": None, "version": None, "config": (HERMES_HOME / "config.yaml").exists(),
           "env_mode": None, "gateway": gateway, "aimemory": "dipasang" if aimemory else "tidak dipilih",
           "services": {}, "smoke": None}
    b = shutil.which("hermes") or str(HOME / ".local/bin/hermes")
    out["binary"] = b if os.path.exists(b) else None
    if out["binary"]:
        try:
            out["version"] = subprocess.run([b, "--version"], capture_output=True, text=True,
                                            timeout=60).stdout.strip().splitlines()[0]
        except Exception as e:
            out["version"] = f"error: {e}"
    envf = HERMES_HOME / ".env"
    if envf.exists():
        out["env_mode"] = oct(envf.stat().st_mode & 0o777)
    # Gateway yang dicek HANYA yang aktif — gateway lain tidak boleh merah.
    # ai-memory hanya dicek kalau memang dipasang (aimemory.mode = yes);
    # service yang absen tanpa pilihan itu = "tidak dipilih", netral, bukan gagal.
    services = ["hermes-serve", gateway] + (["ai-memory"] if aimemory else [])
    for svc in services:
        p = pathlib.Path(os.environ.get("PREFIX", "/usr")) / "var/service" / svc
        if p.is_dir():
            try:
                st = subprocess.run(["sv", "status", svc], capture_output=True, text=True, timeout=10)
                out["services"][svc] = "up" if "run:" in st.stdout else "down"
            except Exception:
                out["services"][svc] = "unknown"
    if gateway == "9router":
        out["gateway_http"] = check_9router_http()
    if aimemory:
        out["aimemory_http"] = check_aimemory_http()
    if smoke and out["binary"]:
        try:
            r = subprocess.run([out["binary"], "-z", "Balas hanya dengan satu kata: ok"],
                               capture_output=True, text=True, timeout=timeout)
            out["smoke"] = "ok" if r.returncode == 0 else f"gagal (rc={r.returncode})"
        except Exception as e:
            out["smoke"] = f"error: {e}"
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Health check provider chain Hermes + layanan.")
    ap.add_argument("--providers", default=str(DEFAULT_PROVIDERS))
    ap.add_argument("--env", default=str(ENV_FILE))
    ap.add_argument("--timeout", type=float, default=10.0)
    ap.add_argument("--retries", type=int, default=2)
    ap.add_argument("--chat", action="store_true", help="+ uji chat/completions 1 token")
    ap.add_argument("--smoke", action="store_true", help="+ `hermes -z` end-to-end")
    ap.add_argument("--gateway", choices=("auto", "injector", "9router"), default="auto",
                    help="gateway aktif yang dicek (default: auto = baca ~/.hermes/gateway.mode)")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    env = load_env_file(pathlib.Path(args.env))
    provs = parse_providers(pathlib.Path(args.providers))
    results = [check_provider(p, env, args.timeout, args.retries, args.chat) for p in provs]
    gateway = detect_gateway(args.gateway)
    aimemory = detect_aimemory()
    h = check_hermes(args.smoke, max(args.timeout, 120), gateway=gateway, aimemory=aimemory)

    healthy = [r for r in results if r["healthy"]]
    broken = [r for r in results if not r["healthy"]]
    # Provider yang statusnya memang "blocked"/"ok_via_proxy" tanpa proxy = kondisi
    # diketahui, bukan kegagalan baru. Sisanya = wajib hijau supaya exit 0.
    known_bad = [r for r in broken if r["status"] in ("blocked_ip_403", "blocked")]
    must_fix = [r for r in broken if r not in known_bad]
    rc = 0 if not must_fix else 1

    if args.json:
        print(json.dumps({"hermes": h, "providers": results, "ok": rc == 0,
                          "must_fix": [r["name"] for r in must_fix],
                          "known_bad": [r["name"] for r in known_bad]}, indent=2))
        return rc

    print("┌─ HERMES ────────────────────────────────────────────────────────────")
    print(f"│ binary   : {h['binary'] or 'TIDAK KETEMU'}")
    print(f"│ versi    : {h['version']}")
    print(f"│ config   : {'ada' if h['config'] else 'TIDAK ADA (jalankan hermes setup)'}")
    print(f"│ .env     : mode {h['env_mode'] or '-'}")
    gw_line = f"{h['gateway']}"
    if h.get("gateway_http") is not None:
        gw_line += f" (HTTP :20128 {h['gateway_http']})"
    print(f"│ gateway  : {gw_line}  [hanya gateway aktif yang dicek]")
    # ai-memory: hanya relevan kalau dipasang. Tidak dipilih = netral (BUKAN gagal).
    if h.get("aimemory") == "dipasang":
        am_svc = h["services"].get("ai-memory", "unknown")
        am_http = h.get("aimemory_http", "-")
        am_flag = "\033[1;32mOK\033[0m" if (am_svc == "up" and am_http != "down") else "\033[1;31mMATI\033[0m"
        print(f"│ ai-memory: [{am_flag}] service={am_svc} http :49374={am_http}")
    else:
        print("│ ai-memory: tidak dipilih (komponen opsional — dilewati, bukan gagal)")
    if h["services"]:
        print(f"│ service  : {', '.join(f'{k}={v}' for k, v in h['services'].items())}")
    if h["smoke"]:
        print(f"│ smoke    : {h['smoke']}")
    print("├─ PROVIDER ──────────────────────────────────────────────────────────")
    for r in results:
        flag = "\033[1;32mSEHAT\033[0m" if r["healthy"] else "\033[1;31mMASALAH\033[0m"
        key = f"{r['key_len']}B" if r["key_present"] else "—"
        prx = " +proxy" if r.get("proxy") else ""
        print(f"│ [{flag}] {r['name']:12s} rtt={str(r['rtt'] or '-'):>6}s key={key:>4s} "
              f"models_listed={r['listed'] if r['listed'] is not None else '-':>3}{prx} "
              f"{('| ' + r['note']) if r['note'] else ''}")
    print("└─────────────────────────────────────────────────────────────────────")
    if not results:
        print("\n(tidak ada provider terbaca — cek path providers.yaml)")
    print(f"\nSEHAT: {len(healthy)}/{len(results)} provider"
          + (f"  —  PERLU DIPERBAIKI: {', '.join(r['name'] for r in must_fix)}" if must_fix
             else f"  —  {len(known_bad)} diketahui diblok: {', '.join(r['name'] for r in known_bad)}" if known_bad
             else "  —  SEMUA BAIK"))
    return rc


if __name__ == "__main__":
    sys.exit(main())
