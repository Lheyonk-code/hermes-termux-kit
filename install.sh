#!/data/data/com.termux/files/usr/bin/bash
# install.sh — Hermes Agent: satu perintah, langsung pakai.
#
# Yang dikerjakan:
#   1. Cek host (Termux/Android vs Linux) dan pilih jalur install yang benar
#      - Termux : repo APT resmi Hermes (install.sh upstream SENGAJA menolak Termux)
#      - Linux  : installer resmi dari hermes-agent.nousresearch.com
#   2. Verifikasi fingerprint PGP key repo sebelum dipakai
#   3. Seed ~/.hermes/config.yaml + ~/.hermes/.env (chmod 600) kalau belum ada
#   4. Tulis provider chain (providers.yaml) + tarik semua key ke .env
#   5. Pasang service autostart (runsv): hermes-serve + injector (opsional)
#   6. Health check provider + smoke test `hermes -z`
#
# Semua kredensial hidup di ~/.hermes/.env. Tidak ada key plaintext di repo/file lain.
# Tanpa Tor, tanpa proxy — jalur langsung. Tambah provider lain di providers.yaml.
#
# Pakai:
#   bash install.sh                     # install + konfigurasi + health check
#   bash install.sh --no-services       # tanpa runsv service
#   bash install.sh --no-injector       # tanpa injector
#   bash install.sh --canary            # Termux: pakai channel canary (default: auto-probe)
#   bash install.sh --dry-run           # tunjukkan langkahnya saja
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
SVC_DIR="${PREFIX:-/usr}/var/service"
KEY_FP="C572B5FDD1A29CCFA9A912B6840B0848E139156D"
KEY_URL="https://hermes-assets.nousresearch.com/releases/termux/canary/key.asc"
ASSETS="https://hermes-assets.nousresearch.com/releases/termux"
INSTALLER_URL="https://hermes-agent.nousresearch.com/install.sh"

DRY=0; WANT_SERVICES=1; WANT_INJECTOR=1; CHANNEL=""
for a in "$@"; do case "$a" in
  --dry-run) DRY=1 ;;
  --no-services) WANT_SERVICES=0 ;;
  --no-injector) WANT_INJECTOR=0 ;;
  --canary) CHANNEL=canary ;;
  --stable) CHANNEL=stable ;;
  -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
  *) echo "argumen tidak dikenal: $a" >&2; exit 2 ;;
esac; done

log()  { printf '\033[1;36m→\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m⚠\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY" = 1 ]; then echo "  [dry] $*"; else "$@"; fi; }

is_termux() { [ -n "${TERMUX_VERSION:-}" ] || case "${PREFIX:-}" in *com.termux/files/usr*) true;; *) false;; esac; }

# ---------------------------------------------------------------------------
log "Host: $(is_termux && echo 'Termux/Android' || echo 'Linux')  |  HOME=$HOME"
[ "$DRY" = 1 ] && warn "DRY-RUN: tidak ada yang benar-benar diubah"

# --- 1. prerequisites ------------------------------------------------------
log "Cek prerequisites (git, curl, gnupg)..."
need=(); for t in git curl gnupg; do command -v "$t" >/dev/null 2>&1 || need+=("$t"); done
if [ ${#need[@]} -gt 0 ]; then
  warn "Kurang: ${need[*]} — install otomatis"
  if is_termux; then run pkg install -y "${need[@]}"; else
    SUDO=""; [ "$(id -u)" = 0 ] || { command -v sudo >/dev/null && SUDO=sudo || die "butuh root/sudo"; }
    run $SUDO apt-get update -y && run $SUDO apt-get install -y "${need[@]}"
  fi
fi
ok "prerequisites siap"

# --- 2. Hermes binary -----------------------------------------------------
if command -v hermes >/dev/null 2>&1; then
  ok "Hermes sudah ada: $(hermes --version 2>/dev/null | head -1)"
else
  if is_termux; then
    # pilih channel yang reponya hidup (stable sering 404 — probe dulu)
    if [ -z "$CHANNEL" ]; then
      for c in stable canary; do
        case $c in stable) s=hermes-stable;; canary) s=hermes-canary;; esac
        if curl -fsI -o /dev/null -m 15 "$ASSETS/$c/dists/$s/InRelease"; then CHANNEL=$c; break; fi
      done
      [ -n "$CHANNEL" ] || die "tidak ada repo Termux Hermes yang bisa dijangkau"
    fi
    log "Termux: pakai repo APT resmi (channel: $CHANNEL)"
    if [ ! -f "$PREFIX/etc/apt/sources.list.d/hermes-agent.list" ]; then
      run pkg install -y gnupg
      run mkdir -p "$PREFIX/etc/apt/keyrings"
      run curl -fsSL "$KEY_URL" -o "$PREFIX/etc/apt/keyrings/hermes-agent.asc"
      got=$(gpg --show-keys --with-fingerprint "$PREFIX/etc/apt/keyrings/hermes-agent.asc" 2>&1 | tr -d ' \n')
      case "$got" in *"$KEY_FP"*) ok "fingerprint PGP cocok";; *) die "FINGERPRINT TIDAK COCOK — berhenti demi keamanan";; esac
      echo "deb [signed-by=$PREFIX/etc/apt/keyrings/hermes-agent.asc] $ASSETS/$CHANNEL hermes-$CHANNEL main" \
        | run tee "$PREFIX/etc/apt/sources.list.d/hermes-agent.list" >/dev/null
    fi
    run pkg update -y
    run pkg install -y hermes-agent
  else
    log "Linux: jalankan installer resmi"
    TMP="$(mktemp -d)"; run curl -fsSL "$INSTALLER_URL" -o "$TMP/install.sh"
    run bash "$TMP/install.sh" --non-interactive --skip-browser
  fi
  command -v hermes >/dev/null 2>&1 || { [ -x "$HOME/.local/bin/hermes" ] && export PATH="$HOME/.local/bin:$PATH"; }
  command -v hermes >/dev/null 2>&1 || die "binary hermes tidak ketemu setelah install"
  ok "Hermes terpasang: $(hermes --version 2>/dev/null | head -1)"
fi

# --- 3. config + .env -----------------------------------------------------
run mkdir -p "$HERMES_HOME"; run chmod 700 "$HERMES_HOME"
ENVF="$HERMES_HOME/.env"
if [ ! -f "$ENVF" ]; then
  log "Buat ~/.hermes/.env (chmod 600)"
  if [ "$DRY" = 1 ]; then echo "  [dry] touch $ENVF"; else
    : > "$ENVF"; chmod 600 "$ENVF"
  fi
  warn "Isi key di $ENVF (RIVER_API_KEY=...), lalu jalankan: hermes setup"
else
  run chmod 600 "$ENVF"; ok "~/.hermes/.env ada (mode 600)"
fi
[ -f "$HERMES_HOME/config.yaml" ] || warn "config.yaml belum ada — jalankan \`hermes setup\` setelah ini"

# --- 4. provider chain (repo) --------------------------------------------
if [ -f "$ROOT/providers.yaml" ]; then
  log "Pasang provider chain -> $HERMES_HOME/providers.yaml"
  run cp -n "$ROOT/providers.yaml" "$HERMES_HOME/providers.yaml" || true
  # tarik key dari repo ke .env kalau masih literal
  if [ "$DRY" = 0 ] && python3 "$ROOT/rotate_keys.py" --env-only --providers "$HERMES_HOME/providers.yaml" 2>/dev/null; then
    ok "key dari providers.yaml dipindah ke .env"
  fi
fi

# --- 5. services (runsv) --------------------------------------------------
if [ "$WANT_SERVICES" = 1 ] && is_termux; then
  command -v runsvdir >/dev/null 2>&1 || { warn "termux-services belum ada — install"; run pkg install -y termux-services; }
  for pair in "hermes-serve:hermes serve --host 127.0.0.1 --port 9119" "injector:python3 $ROOT/tools/injector.py serve -p 20129"; do
    name="${pair%%:*}"; cmd="${pair#*:}"
    [ "$name" = injector ] && [ "$WANT_INJECTOR" = 0 ] && continue
    if [ -d "$SVC_DIR/$name" ]; then ok "service $name sudah ada"; continue; fi
    log "Pasang service $name"
    run mkdir -p "$SVC_DIR/$name"
    printf '#!/data/data/com.termux/files/usr/bin/sh\nexec %s\n' "$cmd" | run tee "$SVC_DIR/$name/run" >/dev/null
    run chmod 700 "$SVC_DIR/$name/run"
  done
  [ "$DRY" = 0 ] && { sv up hermes-serve 2>/dev/null || true; sv up injector 2>/dev/null || true; }
  ok "service dipasang (restart terminal supaya runsvdir memuatnya)"
elif [ "$WANT_SERVICES" = 1 ]; then
  warn "autostart runsv hanya untuk Termux — di Linux pakai systemd sendiri (lewati)"
fi

# --- 6. health + smoke ----------------------------------------------------
log "Health check provider"
if [ "$DRY" = 1 ]; then echo "  [dry] python3 $ROOT/health_check.py"; else
  python3 "$ROOT/health_check.py" --providers "$HERMES_HOME/providers.yaml" \
    --providers "$ROOT/providers.yaml" --chat || warn "health check ada yang merah (lihat di atas)"
fi

# --- 6b. penjaga berkala: auto-rotate + cek sehat -------------------------
# Dua-duanya: service runsv (bertahan setelah HP restart) DAN cron Hermes
# (tidak butuh termux-services). Kalau salah satu tidak tersedia, yang lain jalan.
MAINT="$ROOT/hermes-maintain.sh"
if [ "$DRY" = 0 ] && [ -f "$MAINT" ]; then
  if is_termux && [ "$WANT_SERVICES" = 1 ]; then
    if [ ! -d "$SVC_DIR/hermes-maintain" ]; then
      log "Pasang service hermes-maintain (tiap 6 jam)"
      run mkdir -p "$SVC_DIR/hermes-maintain"
      printf '#!/data/data/com.termux/files/usr/bin/bash\nexec %s\n' "$MAINT" \
        | run tee "$SVC_DIR/hermes-maintain/run" >/dev/null
      run chmod 700 "$SVC_DIR/hermes-maintain/run"
    else ok "service hermes-maintain sudah ada"; fi
  fi
  # cron: pakai salinan di ~/.hermes/scripts (wajib — cron menolak symlink/path luar)
  run mkdir -p "$HERMES_HOME/scripts"
  run cp -f "$MAINT" "$HERMES_HOME/scripts/hermes-maintain.sh"
  run chmod 755 "$HERMES_HOME/scripts/hermes-maintain.sh"
  if command -v hermes >/dev/null 2>&1; then
    # Idempoten: hitung job bernama hermes-maintain. Hapus duplikat kalau ada,
    # baru daftar kalau memang belum ada. (Bug lama: grep di dalam `if` tanpa
    # variabel penampung — pernah lolos dan bikin job dobel.)
    n_job=$(hermes cron list 2>/dev/null | grep -c "Name:[[:space:]]*hermes-maintain")
    if [ "$n_job" = 0 ]; then
      log "Daftarkan cron hermes-maintain (tiap 6 jam)"
      run hermes cron create "every 6h" --name hermes-maintain \
        --script hermes-maintain.sh --no-agent >/dev/null 2>&1 \
        || warn "cron gagal didaftarkan otomatis — jalankan: hermes cron create \"every 6h\" --name hermes-maintain --script hermes-maintain.sh --no-agent"
    elif [ "$n_job" != 1 ]; then
      warn "ada $n_job job bernama hermes-maintain — hapus duplikat manual: hermes cron remove <job_id>"
    else
      ok "cron hermes-maintain sudah terdaftar"
    fi
  fi
fi

log "Smoke test: hermes -z"
if [ "$DRY" = 1 ]; then echo "  [dry] hermes -z 'Balas hanya dengan satu kata: ok'"; else
  if out=$(hermes -z "Balas hanya dengan satu kata: ok" 2>&1 | tail -2); then
    ok "Hermes merespons: $(echo "$out" | tr -d '\n' | head -c 80)"
  else
    warn "smoke test gagal — cek provider/key di $ENVF lalu: hermes doctor"
  fi
fi

echo
ok "SELESAI. Langkah lanjut:"
echo "  hermes -z \"halo\"                 # pakai sekarang"
echo "  python3 $ROOT/health_check.py     # cek sehat semua provider"
echo "  python3 $ROOT/rotate_keys.py --rotate --providers $HERMES_HOME/providers.yaml"
echo "  hermes doctor"
