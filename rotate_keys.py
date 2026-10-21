#!/usr/bin/env python3
"""rotate_keys.py — pindah & rotasi kredensial provider chain.

Dua tugas, bisa dipisah:

  A. --env-only   : tarik SEMUA key literal dari providers.yaml / config.yaml ke
                    ~/.hermes/.env (chmod 600), lalu ganti di file jadi "${VAR}".
                    Tidak menyentuh jaringan. Aman diulang (idempoten).
                    Ini yang diberi nama "auto rotate" di install.sh: satu sumber
                    kredensial, nol plaintext tersebar.

  B. --rotate     : rotasi key di provider (butuh kredensial admin/API provider).
                    Hanya provider yang endpoint rotasinya BENAR-BENAR diketahui yang
                    dicoba (lihat ROTATE_ENDPOINTS). Kalau tidak ada, script TIDAK
                    mengarang key — dia mencatat "manual" dan memberitahu kamu di
                    mana harus rotate (dashboard provider).

Urutan pakai yang disarankan (kalau provider punya endpoint rotasi):
    1. python3 rotate_keys.py --rotate --providers ~/.hermes/providers.yaml
       → key baru ditulis langsung ke .env, file config tetap "${VAR}"

Kalau tidak ada endpoint rotasi (kasus umum):
    1. rotate di dashboard provider, simpan key baru
    2. python3 rotate_keys.py --env-only --set TOKEN_API_KEY=<key baru>
       (atau edit ~/.hermes/.env langsung)
    3. python3 health_check.py --chat --smoke     → pastikan masih sehat
    4. python3 rotate_keys.py --scrub             → bersihkan sisa key lama di
       backup/log/pycache/state.db

--scrub memindai semua file di bawah $HOME (batas 80 MB/file, lewati .git) dan
mengganti nilai key lama dengan REDACTED-ROTATE-ME. Karena itu butuh daftar key
lama: pakai --old <key> atau --old-from <file>. Kronologi: jalankan --scrub
SETELAH rotasi, sebelum key lama jadi sampah berbahaya.

Exit code: 0 sukses, 1 ada yang gagal, 2 argumen salah.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import sqlite3
import stat
import sys
import urllib.error
import urllib.request

HOME = pathlib.Path.home()


def hermes_home() -> pathlib.Path:
    """Baca HERMES_HOME dari env SETIAP KALI dipanggil.

    Bug yang diperbaiki: sebelumnya nilainya dibind saat import, jadi
    `HERMES_HOME=/tmp/x python3 rotate_keys.py` tetap menulis ke ~/.hermes/.env
    (kredensial asli tertimpa oleh uji sandbox).
    """
    return pathlib.Path(os.environ.get("HERMES_HOME", HOME / ".hermes"))


def env_file() -> pathlib.Path:
    return hermes_home() / ".env"


def find_providers(explicit: str | None = None) -> pathlib.Path:
    if explicit:
        return pathlib.Path(explicit)
    hh = hermes_home()
    for c in (hh / "providers.yaml", hh / "syadagentic" / "providers.yaml",
              pathlib.Path(__file__).resolve().parent / "providers.yaml"):
        if c.exists():
            return c
    return hh / "providers.yaml"


DEFAULT_PROVIDERS = find_providers()
PLACEHOLDER = "REDACTED-ROTATE-ME"

# nama env var per provider (bisa dioverride di providers.yaml: key_env: NAMA)
DEFAULT_ENV_NAME = {
    # "provider-1": "TOKEN_API_KEY",  # contoh — daftarkan provider kamu di sini
}


def log(m):  print(f"→ {m}", flush=True)
def ok(m):   print(f"✓ {m}", flush=True)
def warn(m): print(f"⚠ {m}", flush=True)
def die(m, c=1): print(f"✗ {m}", file=sys.stderr); sys.exit(c)


def read_env(path: pathlib.Path | None = None) -> dict[str, str]:
    path = path or env_file()
    out: dict[str, str] = {}
    if path.exists():
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def write_env_var(name: str, value: str) -> None:
    envf = env_file()
    lines = envf.read_text().splitlines() if envf.exists() else []
    lines = [l for l in lines if not l.strip().startswith(name + "=")]
    lines.append(f"{name}={value}")
    envf.parent.mkdir(parents=True, exist_ok=True)
    envf.write_text("\n".join(lines) + "\n")
    os.chmod(envf, stat.S_IRUSR | stat.S_IWUSR)
    ok(f"~/.hermes/.env ← {name} (len={len(value)}, sha256={hashlib.sha256(value.encode()).hexdigest()[:12]})")


def resolve(value: str, env: dict[str, str]) -> str:
    v = (value or "").strip()
    if v.startswith("${") and v.endswith("}"):
        n = v[2:-1].strip()
        return os.environ.get(n) or env.get(n, "")
    return v


def parse_providers(path: pathlib.Path) -> list[dict]:
    """Parser minimal, sama dengan injector/health_check."""
    if not path.exists():
        return []
    provs, cur, lst = [], None, None
    for raw in path.read_text(encoding="utf-8").splitlines():
        if raw.lstrip().startswith("#") or not raw.strip():
            continue
        indent = len(raw) - len(raw.lstrip())
        s = raw.strip()
        if indent <= 2 and s.startswith("- name:"):
            if cur:
                provs.append(cur)
            cur = {"name": s.split(":", 1)[1].strip().strip('"'), "models": []}
            lst = None
            continue
        if cur is None:
            continue
        m = re.match(r"^([A-Za-z_]+):\s*(.*)$", s)
        if m and not s.startswith("- "):
            k, v = m.group(1), m.group(2).strip().strip('"')
            cur[k] = v
            lst = k if v == "" else None
            continue
        if s.startswith("- ") and lst:
            cur.setdefault(lst, [])
            if isinstance(cur[lst], list):
                cur[lst].append(s[2:].strip().strip('"'))
    if cur:
        provs.append(cur)
    return provs


# --- A. env-only: tarik key literal ke .env --------------------------------
def env_only(providers: pathlib.Path, extra: dict[str, str] | None = None) -> int:
    if not providers.exists():
        die(f"providers.yaml tidak ada: {providers}")
    txt = providers.read_text()
    env = read_env()
    changed = 0

    for p in parse_providers(providers):
        name = p.get("name", "")
        raw = (p.get("api_key") or "").strip()
        if not raw or raw.startswith("${"):
            continue
        var = p.get("key_env") or DEFAULT_ENV_NAME.get(name) or f"{re.sub(r'[^A-Z0-9]', '_', name.upper())}_API_KEY"
        if env.get(var) == raw:
            pass  # sudah sinkron
        else:
            write_env_var(var, raw)
        txt = re.sub(
            rf'(name:\s*{re.escape(name)}\b[\s\S]*?api_key:\s*)["\']?{re.escape(raw)}["\']?',
            rf'\1"${{{var}}}"', txt, count=1)
        changed += 1
        ok(f"providers.yaml: {name} → ${{{var}}}")

    if extra:
        for k, v in extra.items():
            write_env_var(k, v)
            changed += 1

    if changed:
        providers.write_text(txt)
        ok(f"providers.yaml diperbarui ({changed} entri)")
    else:
        ok("tidak ada key literal — sudah bersih")

    left = [n for n in re.findall(r"api_key:\s*\"([^\"]+)\"", providers.read_text())
            if not n.startswith("${")]
    if left:
        warn(f"MASIH ada {len(left)} api_key literal — cek manual: {providers}")
        return 1
    ok("verifikasi: nol api_key literal di providers.yaml")
    return 0


# --- B. rotate di provider -------------------------------------------------
# Peta endpoint rotasi (hanya yang benar-benar diketahui). Tiap entri: url, method, payload.
ROTATE_ENDPOINTS = {
    # "provider-1": ("{base}/api_keys/rotate", "POST", {}),  # contoh — isi hanya kalau provider kamu memang punya endpoint rotasi
}


def rotate(providers: pathlib.Path, only: str | None, timeout: float) -> int:
    env = read_env()
    rc = 0
    for p in parse_providers(providers):
        name = p.get("name", "")
        if only and name != only:
            continue
        spec = ROTATE_ENDPOINTS.get(name)
        base = (p.get("base_url") or "").rstrip("/")
        cur = resolve(p.get("api_key", ""), env)
        if not spec or not base or not cur:
            warn(f"{name}: tidak ada endpoint rotasi otomatis → rotate MANUAL di dashboard. "
                 f"Simpan key baru ke .env lalu jalankan: rotate_keys.py --env-only --set "
                 f"{DEFAULT_ENV_NAME.get(name, 'PROVIDER_API_KEY')}=<baru>")
            rc = 1
            continue
        url, method, payload = spec[0].format(base=base), spec[1], spec[2]
        req = urllib.request.Request(url, data=json.dumps(payload).encode() if payload else None,
                                     method=method)
        req.add_header("Authorization", f"Bearer {cur}")
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                body = r.read().decode("utf-8", "ignore")
            new = (json.loads(body).get("api_key") or json.loads(body).get("key") or "").strip()
            if not new:
                warn(f"{name}: rotasi dijawab 200 tapi tidak ada api_key di respons")
                rc = 1
                continue
            var = p.get("key_env") or DEFAULT_ENV_NAME.get(name, f"{name.upper()}_API_KEY")
            write_env_var(var, new)
            ok(f"{name}: key dirotasi (lama sha256={hashlib.sha256(cur.encode()).hexdigest()[:12]})")
        except urllib.error.HTTPError as e:
            warn(f"{name}: rotasi gagal HTTP {e.code} — rotate manual di dashboard")
            rc = 1
        except Exception as e:
            warn(f"{name}: rotasi gagal ({type(e).__name__}: {e}) — rotate manual")
            rc = 1
    return rc


# --- C. scrub sisa key lama ------------------------------------------------
def scrub(olds: list[str], skip_git=True, max_mb=80) -> int:
    if not olds:
        die("--scrub butuh --old <key> atau --old-from <file>")
    home = HOME
    n_file = n_db = 0
    limit = max_mb * 1024 * 1024
    for root, dirs, files in os.walk(home, followlinks=False):
        if skip_git:
            dirs[:] = [d for d in dirs if d != ".git"]
        for f in files:
            p = pathlib.Path(root) / f
            try:
                if p.stat().st_size > limit or p == env_file():
                    continue
                raw = p.read_bytes()
            except Exception:
                continue
            if not any(o.encode() in raw for o in olds if o):
                continue
            if p.suffix == ".pyc":
                p.unlink(); n_file += 1; log(f"hapus cache: {p.relative_to(home)}"); continue
            txt = raw.decode("utf-8", "ignore")
            for o in olds:
                if o:
                    txt = txt.replace(o, PLACEHOLDER)
            p.write_bytes(txt.encode())
            n_file += 1; log(f"scrub: {p.relative_to(home)}")

    for dbf in (hermes_home() / "state.db",):
        if not dbf.exists():
            continue
        try:
            con = sqlite3.connect(f"file:{dbf}?mode=rw", uri=True, timeout=10)
            cur = con.cursor()
            tabs = [r[0] for r in cur.execute("SELECT name FROM sqlite_master WHERE type='table'")]
            for t in tabs:
                for c in [r[1] for r in cur.execute(f'PRAGMA table_info("{t}")')]:
                    for o in olds:
                        if not o:
                            continue
                        try:
                            n = cur.execute(
                                f'SELECT COUNT(*) FROM "{t}" WHERE CAST("{c}" AS TEXT) LIKE ?',
                                (f"%{o}%",)).fetchone()[0]
                        except Exception:
                            continue
                        if n:
                            cur.execute(
                                f'UPDATE "{t}" SET "{c}" = REPLACE(CAST("{c}" AS TEXT), ?, ?) '
                                f'WHERE CAST("{c}" AS TEXT) LIKE ?', (o, PLACEHOLDER, f"%{o}%"))
                            n_db += n
            con.commit(); con.close()
        except Exception as e:
            warn(f"{dbf.name}: {e}")
    ok(f"scrub selesai: {n_file} file, {n_db} baris DB  (catatan: WAL/FTS baru bersih setelah VACUUM saat Hermes idle)")
    warn("sisa di state.db-wal itu normal sampai checkpoint — rotasi yang membuatnya tidak berbahaya")
    return 0


# --- main ------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser(description="Pindah & rotasi kredensial provider chain.")
    ap.add_argument("--providers", default=str(DEFAULT_PROVIDERS))
    ap.add_argument("--env-only", action="store_true", help="tarik key literal ke .env (tanpa jaringan)")
    ap.add_argument("--rotate", action="store_true", help="rotasi di provider (kalau ada endpoint)")
    ap.add_argument("--only", help="batasi ke satu provider (nama di providers.yaml)")
    ap.add_argument("--set", action="append", default=[], metavar="VAR=VALUE",
                    help="tulis key baru ke .env (boleh berkali-kali)")
    ap.add_argument("--scrub", action="store_true", help="bersihkan key lama dari file/DB")
    ap.add_argument("--old", action="append", default=[], help="nilai key lama utk --scrub")
    ap.add_argument("--old-from", help="file berisi key lama (satu per baris) utk --scrub")
    ap.add_argument("--timeout", type=float, default=20.0)
    args = ap.parse_args()

    if not (args.env_only or args.rotate or args.scrub or args.set):
        ap.print_help(); return 2

    prov = pathlib.Path(args.providers)
    extra = {}
    for s in args.set:
        if "=" not in s:
            die(f"--set butuh format VAR=VALUE: {s}", 2)
        k, v = s.split("=", 1)
        extra[k.strip()] = v.strip()

    rc = 0
    if args.env_only or extra:
        rc |= env_only(prov, extra or None)
    if args.rotate:
        rc |= rotate(prov, args.only, args.timeout)
    if args.scrub:
        olds = list(args.old)
        if args.old_from:
            olds += [l.strip() for l in pathlib.Path(args.old_from).read_text().splitlines() if l.strip()]
        rc |= scrub(olds)
    return rc


if __name__ == "__main__":
    sys.exit(main())
