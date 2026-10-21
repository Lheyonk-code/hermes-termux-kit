#!/usr/bin/env bash
# hermes-maintain — satu perintah untuk "Hermes tetap sehat & kredensial bersih".
#
# Dipakai dua cara:
#   1. manual   : bash hermes-maintain.sh          (cek sekarang)
#   2. terjadwal: cron Hermes -> script ini        (auto rotate + health, tiap 6 jam)
#
# Yang dilakukan tiap tick:
#   * rotate_keys.py --env-only → tarik key literal nyasar ke ~/.hermes/.env (idempoten)
#   * health_check.py           → provider hidup? key diterima? endpoint chat jalan?
#   * kalau ada provider MASALAH yang punya endpoint rotasi → coba --rotate
#   * ringkasan ke ~/logs/hermes-maintain.log
#
# stdout HANYA baris alarm (watchdog pattern): kosong = semua sehat, tidak ada
# yang perlu dikirim ke operator.
#
# Exit code: 0 sehat, 1 ada yang perlu diperbaiki, 2 env salah.
#
# JEBAKAN (sudah kena saat uji, jangan diulang):
#   * JANGAN hitung status di dalam pipe (`... | python3`) — itu subshell, variabel
#     yang di-assign di luar pipe TETAP kosong. Tulis ke file temp, baru baca.
#   * JANGAN kirim dua kali --providers ke health_check.py — argparse memakai yang
#     TERAKHIR, jadi path uji (mis. /tmp/x) selalu kalah oleh fallback default.

KIT="${HERMES_KIT:-$HOME/hermes-kit}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
PROV="${PROV:-$HERMES_HOME/providers.yaml}"
[ -f "$PROV" ] || PROV="$KIT/providers.yaml"
[ -f "$PROV" ] || { echo "✗ providers.yaml tidak ada (cek $PROV)" >&2; exit 2; }
LOG="$HOME/logs/hermes-maintain.log"
mkdir -p "$(dirname "$LOG")"
# E-1: dua pemicu (service runsv loop 6 jam + cron Hermes) boleh ada, tapi
# jangan pernah jalan BERSAMAAN — kunci eksklusif non-blocking; yang kalah
# melewatkan tick ini dengan tenang.
exec 9>"$HOME/logs/.hermes-maintain.lock"
flock -n 9 || { echo "[$(date '+%Y-%m-%d %H:%M:%S%z')] tick dilewati: instance lain sedang jalan" >> "$LOG"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

ts() { date '+%Y-%m-%d %H:%M:%S%z'; }
say() { echo "[$(ts)] $*" >> "$LOG"; }

# --- 1. tarik key literal nyasar ke .env (aman diulang) --------------------
if [ -f "$KIT/rotate_keys.py" ]; then
  moved=$(cd "$KIT" && python3 rotate_keys.py --env-only --providers "$PROV" 2>&1)
  case "$moved" in
    *"diperbarui"*) say "env-only: $(printf '%s' "$moved" | tr '\n' ' ')" ;;
  esac
fi

# --- 2. health check (json = gampang dibaca) -------------------------------
cd "$KIT" || exit 2
python3 health_check.py --providers "$PROV" --chat --json --timeout 12 > "$TMP/hj" 2>/dev/null
RC=$?
BAD=$(python3 - "$TMP/hj" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    print("PARSE_ERR"); raise SystemExit
bad=[p for p in d["providers"] if not p["healthy"]]
fix=[p["name"] for p in bad if p.get("status") not in ("blocked_ip_403","blocked")]
known=[p["name"] for p in bad if p.get("status") in ("blocked_ip_403","blocked")]
down=[k for k,v in d["hermes"].get("services",{}).items() if v!="up"]
parts=[]
if fix:   parts.append("PERLU-DIPERBAIKI=" + ",".join(fix))
if known: parts.append("diblok=" + ",".join(known))
if down:  parts.append("service-mati=" + ",".join(down))
if not d["providers"]: parts.append("TIDAK-ADA-PROVIDER-terbaca")
print("; ".join(parts))
PY
)

# --- 3. rotasi key untuk provider yang endpointnya diketahui ---------------
if [ -n "$BAD" ] && [ "$BAD" != "PARSE_ERR" ] && printf '%s' "$BAD" | grep -q 'PERLU-DIPERBAIKI='; then
  RET=$(python3 rotate_keys.py --rotate --providers "$PROV" 2>&1 || true)
  case "$RET" in
    *"key dirotasi"*) say "ROTASI: $(printf '%s' "$RET" | tr '\n' ' ')"; BAD="$BAD (rotasi dicoba)" ;;
    *) say "rotasi tak tersedia (rotate manual di dashboard provider)" ;;
  esac
fi

# --- 4. ringkas ------------------------------------------------------------
if [ "$RC" = 0 ] && [ -z "$BAD" ]; then
  say "OK  rc=0  semua provider sehat  ($PROV)"
  exit 0
fi
say "GAGAL rc=$RC  $BAD  ($PROV)"
echo "⚠ hermes-maintain $(ts): ${BAD:-health rc=$RC}"
exit 1
