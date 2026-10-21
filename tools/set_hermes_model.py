#!/usr/bin/env python3
"""set_hermes_model.py — tulis blok `model:` Hermes ke gateway kit (F-33/F-34).

Hermes 0.22 memvalidasi `model.provider` secara ketat: endpoint custom
slug resminya "custom". Nama rantai injector (river/bariska/...) sebagai
provider membuat chat mati total dengan "Unknown provider", padahal
injector sehat — terbukti di lapangan 21 Okt 2026. Karena itu kit menulis
sendiri blok model di ~/.hermes/config.yaml:

    model:
      provider: custom
      base_url: http://127.0.0.1:20129/v1   # gateway kit (injector/9Router)
      default: <default_model provider utama>
      api_key: "${ENV_PROVIDER_UTAMA}"

Dengan base_url menunjuk gateway lokal, dashboard Hermes membaca /models
dari gateway itu dan model-model chain MUNCUL di pemilih APK (F-33) —
persis perilaku hasil `hermes model` manual yang terbukti di HP utama.

Edit bersifat bedah: hanya kunci provider/base_url/default/api_key di
dalam blok `model:` yang disentuh; blok lain (memory:, dll) dan kunci
model lain tidak berubah. Penulisan atomik (tmp + os.replace).

Pakai:
  python3 tools/set_hermes_model.py [--config ~/.hermes/config.yaml]
      [--providers ~/.hermes/providers.yaml] --base-url http://127.0.0.1:20129/v1

Exit: 0 = tertulis / tidak ada yang perlu ditulis; 1 = argumen salah.
Tidak pernah mencetak nilai key.
"""
from __future__ import annotations

import argparse
import os
import pathlib
import re
import sys

HOME = pathlib.Path.home()
HERMES_HOME = pathlib.Path(os.environ.get("HERMES_HOME", HOME / ".hermes"))


def parse_providers(path: pathlib.Path) -> list[dict]:
    """Parser minimal — format sama dengan tools/injector.py."""
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
    provs.sort(key=lambda x: x.get("priority", 999))
    return provs


def primary_of(provs: list[dict]) -> dict | None:
    utama = [p for p in provs if not p.get("fallback")]
    return (utama or provs or [None])[0]


def set_model_block(config: pathlib.Path, base_url: str, model: str,
                    api_key_ref: str) -> None:
    lines = config.read_text(encoding="utf-8").splitlines() if config.exists() else []
    want = {"provider": "custom", "base_url": base_url,
            "default": model, "api_key": f'"{api_key_ref}"'}
    # Cari blok top-level `model:` — bloknya = baris-baris sesudahnya yang
    # ber-indentasi (atau kosong/komentar) sampai kunci top-level berikutnya.
    start = None
    for i, ln in enumerate(lines):
        if re.match(r"^model:\s*$", ln):
            start = i
            break
    if start is None:
        if lines and lines[-1].strip():
            lines.append("")
        lines.append("model:")
        for k in ("provider", "base_url", "default", "api_key"):
            lines.append(f"  {k}: {want[k]}")
    else:
        end = start + 1
        while end < len(lines) and (lines[end].strip() == ""
                                    or lines[end].startswith((" ", "\t", "#"))):
            end += 1
        block = lines[start + 1:end]
        seen: set[str] = set()
        for j, bl in enumerate(block):
            m = re.match(r"^(\s*)([A-Za-z_]+):", bl)
            if m and m.group(2) in want:
                k = m.group(2)
                block[j] = f"{m.group(1)}{k}: {want[k]}"
                seen.add(k)
        for k in ("provider", "base_url", "default", "api_key"):
            if k not in seen:
                block.append(f"  {k}: {want[k]}")
        lines[start + 1:end] = block
    config.parent.mkdir(parents=True, exist_ok=True)
    tmp = config.with_suffix(".yaml.tmp")
    tmp.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.replace(tmp, config)


def main() -> int:
    ap = argparse.ArgumentParser(description="Tulis blok model: Hermes -> gateway kit.")
    ap.add_argument("--config", default=str(HERMES_HOME / "config.yaml"))
    ap.add_argument("--providers", default=str(HERMES_HOME / "providers.yaml"))
    ap.add_argument("--base-url", required=True,
                    help="base_url gateway kit, mis. http://127.0.0.1:20129/v1")
    args = ap.parse_args()

    provs = parse_providers(pathlib.Path(args.providers))
    prim = primary_of(provs)
    if not prim:
        print("⚠ set-model: tidak ada provider terbaca — blok model tidak ditulis")
        return 0
    model = prim.get("default_model") or next(iter(prim.get("models") or []), "")
    if not model:
        print(f"⚠ set-model: provider utama '{prim.get('name')}' tidak punya model — blok model tidak ditulis")
        return 0
    ref = (prim.get("api_key") or "").strip()
    if not (ref.startswith("${") and ref.endswith("}")):
        # Jangan menyalin key literal ke config.yaml. Pakai nama env var
        # yang akan dibuat rotate_keys --env-only untuk provider ini.
        var = re.sub(r"[^A-Z0-9]", "_", (prim.get("name") or "PROVIDER").upper()) + "_API_KEY"
        ref = "${" + var + "}"
    set_model_block(pathlib.Path(args.config), args.base_url, model, ref)
    print(f"✓ config.yaml: model.provider=custom → {args.base_url} (default: {model}, "
          f"provider utama: {prim.get('name')})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
