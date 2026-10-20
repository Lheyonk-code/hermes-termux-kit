#!/data/data/com.termux/files/usr/bin/bash
# install.sh — Hermes Agent: satu perintah, langsung pakai.
#
# Yang dikerjakan:
#   0. CETAK KUNCI DULU: cek ~/.hermes/.env + providers.yaml — kalau belum ada
#      key provider yang terisi, wizard interaktif menanyakan provider (nama,
#      base_url, model, API key), minimal 1, boleh lebih (auto-rotate sesuai
#      jumlah). Key HANYA ditulis ke ~/.hermes/.env (chmod 600); providers.yaml
#      memakai referensi "${ENV}". Sudah terisi = langkah ini dilewati (idempoten)
#   1. Cek host (Termux/Android vs Linux) dan pilih jalur install yang benar
#      - Termux : repo APT resmi Hermes (install.sh upstream SENGAJA menolak Termux)
#      - Linux  : installer resmi dari hermes-agent.nousresearch.com
#   2. Verifikasi fingerprint PGP key repo sebelum dipakai
#   3. Seed ~/.hermes/config.yaml + ~/.hermes/.env (chmod 600) kalau belum ada
#   4. Tulis provider chain (providers.yaml) + tarik semua key ke .env
#   5. Pilih gateway: injector bawaan kit (DEFAULT, ringan, :20129) atau
#      9Router (opsional, Node.js, dashboard :20128) — SALING EKSKLUSIF,
#      hanya SATU yang dipasang/jalan
#   6. Pasang service autostart (runsv): hermes-serve + gateway terpilih
#   7. Health check provider + smoke test `hermes -z`
#
# Semua kredensial hidup di ~/.hermes/.env. Tidak ada key plaintext di repo/file lain.
# Tanpa Tor, tanpa proxy — jalur langsung. Tambah provider lain di providers.yaml.
#
# Pakai:
#   bash install.sh                     # wizard kredensial (kalau kosong) + install
#   bash install.sh --no-services       # tanpa runsv service
#   bash install.sh --no-injector       # tanpa injector
#   bash install.sh --gateway=injector  # paksa injector (default)
#   bash install.sh --gateway=9router   # paksa 9Router (injector tidak dibuat)
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

GATEWAY_MODE=""; DRY=0; WANT_SERVICES=1; WANT_INJECTOR=1; CHANNEL=""
for a in "$@"; do case "$a" in
  --dry-run) DRY=1 ;;
  --no-services) WANT_SERVICES=0 ;;
  --no-injector) WANT_INJECTOR=0 ;;
  --gateway=*) GATEWAY_MODE="${a#--gateway=}" ;;
  --canary) CHANNEL=canary ;;
  --stable) CHANNEL=stable ;;
  -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
  *) echo "argumen tidak dikenal: $a" >&2; exit 2 ;;
esac; done

log()  { printf '\033[1;36m→\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m⚠\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY" = 1 ]; then echo "  [dry] $*"; else "$@"; fi; }

is_termux() { [ -n "${TERMUX_VERSION:-}" ] || case "${PREFIX:-}" in *com.termux/files/usr*) true;; *) false;; esac; }

ENVF="$HERMES_HOME/.env"
PYAML="$HERMES_HOME/providers.yaml"

# ---------------------------------------------------------------------------
# LANGKAH 0 — PROVIDER + API KEY HARUS SIAP SEBELUM INSTALL.
# Cek $PYAML + $ENVF: kalau belum ada satu pun key provider yang terisi,
# jalankan wizard interaktif (provider: nama, base_url, model, API key) —
# minimal 1 provider, boleh tambah lagi (2, 3, ... sesuai jumlah yang diisi
# user; dipakai untuk auto-rotate). Hasil wizard:
#   - $PYAML  : api_key SELALU "${NAMA_ENV}" (nol key plaintext di file ini)
#   - $ENVF   : key asli, chmod 600
# Idempoten: kalau kredensial sudah terisi, langkah ini dilewati — install
# ulang TIDAK PERNAH menimpa kredensial yang ada.
# ---------------------------------------------------------------------------

valid_name() { case "$1" in ''|*[!A-Za-z0-9_]*) return 1 ;; *) return 0 ;; esac; }

# Siap = minimal 1 provider di providers.yaml memakai api_key "${VAR}" DAN
# VAR terisi (tidak kosong) di ~/.hermes/.env.
provider_ready() {
  local var
  [ -f "$PYAML" ] && [ -f "$ENVF" ] || return 1
  while IFS= read -r var; do
    [ -n "$var" ] || continue
    grep -qE "^${var}=..*" "$ENVF" 2>/dev/null && return 0
  done < <(grep -oE 'api_key:[[:space:]]*"\$\{[A-Za-z_][A-Za-z0-9_]*\}"' "$PYAML" 2>/dev/null \
           | sed -E 's/.*\$\{([A-Za-z_][A-Za-z0-9_]*)\}.*/\1/' | sort -u)
  return 1
}

# Tulis/update satu env var di $ENVF (mode 600). Nilai lama yang sudah terisi
# TIDAK ditimpa — hanya baris kosong/placeholder yang diganti.
wizard_put_envvar() {
  local n="$1" v="$2" tmp
  if grep -qE "^${n}=..*" "$ENVF" 2>/dev/null; then
    warn "  $n sudah terisi di $ENVF — nilai lama tetap dipakai (tidak ditimpa)"
    return 0
  fi
  tmp="$ENVF.tmp.$$"
  grep -vE "^${n}=" "$ENVF" > "$tmp" 2>/dev/null || : > "$tmp"
  printf '%s=%s\n' "$n" "$v" >> "$tmp"
  mv "$tmp" "$ENVF"
  chmod 600 "$ENVF"
  ok "  $n ditulis ke $ENVF (mode 600)"
}

# wizard_add_provider <nomor> — tanya data 1 provider, tulis blok YAML ke
# $WIZARD_BLOCKS (api_key pakai referensi ${ENV}, bukan literal) + key ke $ENVF.
wizard_add_provider() {
  local no="$1" name base model key envvar
  printf '\n== Provider ke-%s ==\n' "$no"
  while :; do
    read -r -p '  Nama provider (mis. river): ' name
    valid_name "${name:-}" && break
    echo '  Nama wajib diisi, hanya huruf/angka/underscore.'
  done
  while :; do
    read -r -p '  Base URL (endpoint OpenAI-compatible, tanpa / di akhir): ' base
    case "${base:-}" in https://*|http://*) break ;; esac
    echo '  Harus diawali http:// atau https://'
  done
  read -r -p '  Default model (Enter = lewati): ' model
  while :; do
    read -r -s -p '  API key: ' key; echo
    [ -n "${key:-}" ] && break
    echo '  API key wajib diisi.'
  done
  envvar="${name^^}_API_KEY"
  {
    printf '  - name: %s\n' "$name"
    printf '    base_url: %s\n' "$base"
    printf '    api_key: "${%s}"\n' "$envvar"
    printf '    status: ok\n'
    printf '    priority: %d\n' "$no"
    if [ "$no" = 1 ]; then printf '    fallback: false\n'
    else printf '    fallback: true\n'; fi
    if [ -n "${model:-}" ]; then
      printf '    default_model: %s\n' "$model"
      printf '    models:\n      - %s\n' "$model"
    fi
    printf '\n'
  } >> "$WIZARD_BLOCKS"
  wizard_put_envvar "$envvar" "$key"
  ok "  Provider '$name' tercatat — key hanya di $ENVF, $PYAML pakai \${$envvar}"
}

# --- LANGKAH 0: jalankan / lewati -----------------------------------------
if [ "$DRY" = 1 ]; then
  echo '  [dry] Langkah 0: cek provider + key (wizard dilewati di dry-run)'
elif provider_ready; then
  ok "Langkah 0: kredensial sudah terisi ($PYAML + $ENVF) — dilewati (idempoten)"
else
  log 'Langkah 0: provider + API key belum terisi — wizard pengisian'
  mkdir -p "$HERMES_HOME" 2>/dev/null || true
  chmod 700 "$HERMES_HOME" 2>/dev/null || true
  [ -f "$ENVF" ] || : > "$ENVF"
  chmod 600 "$ENVF"
  if [ -f "$PYAML" ]; then
    cp -p "$PYAML" "$PYAML.bak.$(date +%Y%m%d%H%M%S)"
    warn "$PYAML lama dicadangkan (.bak.<tanggal>) sebelum ditulis ulang"
  fi
  WIZARD_BLOCKS="$(mktemp)"
  : > "$WIZARD_BLOCKS"
  n_provider=0
  while :; do
    n_provider=$((n_provider + 1))
    wizard_add_provider "$n_provider"
    read -r -p 'Tambah provider lagi (untuk auto-rotate)? [y/N]: ' lagi
    case "${lagi:-n}" in y|Y) ;; *) break ;; esac
  done
  {
    echo '# providers.yaml — provider chain Hermes (hasil wizard Langkah 0 install.sh)'
    echo '# ATURAN KREDENSIAL: api_key SELALU "${NAMA_ENV}" — key asli HANYA di'
    echo '# ~/.hermes/.env (chmod 600). Tidak ada Tor, tidak ada proxy. Jalur langsung.'
    echo '#'
    echo '# Field per provider: name, base_url, api_key, key_env (opsi), status,'
    echo '# priority (kecil = dicoba dulu), default_model, fallback (true = cadangan), models.'
    echo
    echo 'providers:'
    cat "$WIZARD_BLOCKS"
  } > "$PYAML"
  rm -f "$WIZARD_BLOCKS" "$WIZARD_BLOCKS".tmp.* 2>/dev/null || true
  chmod 644 "$PYAML" 2>/dev/null || true
  ok "providers.yaml ditulis: $n_provider provider siap — key di $ENVF (mode 600)"
  unset n_provider lagi WIZARD_BLOCKS
fi


# ---------------------------------------------------------------------------
# PILIH GATEWAY (setelah Langkah 0) — injector bawaan kit (DEFAULT, ringan,
# proxy OpenAI-compatible :20129) atau 9Router (opsional, Node.js, dashboard
# :20128 + endpoint /v1). SALING EKSKLUSIF: hanya SATU gateway yang jalan.
#   pilih 9Router -> service injector TIDAK dibuat; yang lama dimatikan
#   pilih injector -> 9Router TIDAK dipasang sama sekali
# Pilihan disimpan di $HERMES_HOME/gateway.mode supaya idempoten (install
# ulang tidak menanya lagi) dan bisa diganti kapan saja lewat flag
# --gateway=injector|--gateway=9router. Tanpa flag, wizard bertanya kalau
# pilihan belum tersimpan (Enter = injector). Key provider tetap HANYA di
# $ENVF (chmod 600) — pilihan gateway tidak menyentuh key.
# ---------------------------------------------------------------------------
GWF="$HERMES_HOME/gateway.mode"
GATEWAY="$GATEWAY_MODE"
case "$GATEWAY" in ''|injector|9router) ;; *) die "gateway tidak dikenal: $GATEWAY (pakai injector atau 9router)" ;; esac
if [ -z "$GATEWAY" ]; then
  GATEWAY=""
  if [ -r "$GWF" ]; then
    GATEWAY="$(head -1 "$GWF" 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  case "$GATEWAY" in injector|9router) ok "Gateway tersimpan: $GATEWAY (dari $GWF)" ;; *) GATEWAY="" ;; esac
fi
if [ -z "$GATEWAY" ] && [ "$DRY" = 0 ] && [ -t 0 ]; then
  echo
  echo '== Pilih gateway (hanya SATU yang jalan) =='
  echo '  1) injector bawaan kit — ringan, proxy OpenAI-compatible :20129 (default)'
  echo '  2) 9Router (opsional)  — router Node.js, dashboard :20128, fallback pintar'
  read -r -p 'Pilihan [1/2, Enter = 1]: ' gw_choice
  case "${gw_choice:-1}" in 2) GATEWAY=9router ;; *) GATEWAY=injector ;; esac
fi
GATEWAY="${GATEWAY:-injector}"
if [ "$DRY" = 1 ]; then
  echo "  [dry] pilihan gateway '$GATEWAY' akan ditulis ke $GWF"
else
  mkdir -p "$HERMES_HOME" 2>/dev/null || true
  printf '%s\n' "$GATEWAY" > "$GWF"
  chmod 644 "$GWF" 2>/dev/null || true
  ok "Gateway aktif: $GATEWAY (tersimpan di $GWF)"
fi
# 9Router butuh Node.js + npm, lalu paketnya sendiri (npm install -g 9router)
if [ "$GATEWAY" = 9router ] && [ "$DRY" = 0 ]; then
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    log "9Router butuh Node.js + npm — install dulu"
    if is_termux; then run pkg install -y nodejs
    else
      SUDO=""; [ "$(id -u)" = 0 ] || { command -v sudo >/dev/null && SUDO=sudo || die "butuh root/sudo"; }
      run $SUDO apt-get update -y && run $SUDO apt-get install -y nodejs npm
    fi
  fi
  if command -v 9router >/dev/null 2>&1; then
    ok "9Router sudah terpasang: $(command -v 9router)"
  else
    log "Pasang 9Router (npm install -g 9router) — bisa makan waktu beberapa menit"
    run npm install -g 9router
  fi
fi


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

# --- 5. services (runsv) — hanya gateway terpilih yang dipasang ------------
if [ "$WANT_SERVICES" = 1 ] && is_termux; then
  command -v runsvdir >/dev/null 2>&1 || { warn "termux-services belum ada — install"; run pkg install -y termux-services; }
  # Saling eksklusif: matikan service gateway yang TIDAK terpilih (kalau ada).
  # Service dinonaktifkan dengan `sv down` + di-rename ke direktori tersembunyi
  # (.awalan diabaikan runsvdir) — tidak dihapus, jadi bisa diaktifkan lagi.
  if [ "$GATEWAY" = 9router ] && [ -d "$SVC_DIR/injector" ]; then
    log "Matikan service injector (gateway aktif: 9Router)"
    if [ "$DRY" = 0 ]; then sv down injector 2>/dev/null || true; fi
    run mv "$SVC_DIR/injector" "$SVC_DIR/.injector.disabled"
  fi
  if [ "$GATEWAY" = injector ] && [ -d "$SVC_DIR/9router" ]; then
    log "Matikan service 9router (gateway aktif: injector)"
    if [ "$DRY" = 0 ]; then sv down 9router 2>/dev/null || true; fi
    run mv "$SVC_DIR/9router" "$SVC_DIR/.9router.disabled"
  fi
  gwpair=""
  case "$GATEWAY" in
    injector) gwpair="injector:python3 $ROOT/tools/injector.py serve -p 20129" ;;
    9router)  gwpair="9router:9router" ;;
  esac
  for pair in "hermes-serve:hermes serve --host 127.0.0.1 --port 9119" "$gwpair"; do
    name="${pair%%:*}"; cmd="${pair#*:}"
    [ -z "$cmd" ] && continue
    [ "$name" = injector ] && [ "$WANT_INJECTOR" = 0 ] && continue
    if [ -d "$SVC_DIR/$name" ]; then ok "service $name sudah ada"; continue; fi
    log "Pasang service $name"
    run mkdir -p "$SVC_DIR/$name"
    if [ "$name" = 9router ]; then
      # runsv memakai PATH minimal — pastikan node/9router ketemu
      printf '#!/data/data/com.termux/files/usr/bin/sh\nexport PATH="${PREFIX:-/data/data/com.termux/files/usr}/bin:$PATH"\nexec %s\n' "$cmd" \
        | run tee "$SVC_DIR/$name/run" >/dev/null
    else
      printf '#!/data/data/com.termux/files/usr/bin/sh\nexec %s\n' "$cmd" | run tee "$SVC_DIR/$name/run" >/dev/null
    fi
    run chmod 700 "$SVC_DIR/$name/run"
  done
  if [ "$DRY" = 0 ]; then
    sv up hermes-serve 2>/dev/null || true
    case "$GATEWAY" in
      injector) sv up injector 2>/dev/null || true ;;
      9router)  sv up 9router 2>/dev/null || true ;;
    esac
  fi
  ok "service dipasang — gateway aktif: $GATEWAY (restart terminal supaya runsvdir memuatnya)"
elif [ "$WANT_SERVICES" = 1 ]; then
  warn "autostart runsv hanya untuk Termux — di Linux pakai systemd sendiri (lewati)"
fi

# --- 5b. sambungkan provider chain ke 9Router (sebisa mungkin) -------------
# 9Router mengelola provider-nya lewat dashboard (token/OAuth per provider),
# jadi koneksi chain dilakukan best-effort: data chain kit ditampilkan siap
# tempel. Key asli TETAP hanya di $ENVF — tidak disalin ke file lain.
if [ "$GATEWAY" = 9router ]; then
  log "Sambungkan provider chain ke 9Router:"
  echo "  Dashboard : http://127.0.0.1:20128  → Providers → tambah provider custom (OpenAI-compatible)"
  echo "  Endpoint  : http://127.0.0.1:20128/v1  (API key di-copy dari dashboard 9Router)"
  echo "  Data chain kit: base_url/model di $HERMES_HOME/providers.yaml, key hanya di $ENVF"
  if [ -r "$HERMES_HOME/providers.yaml" ]; then
    echo "  Provider di chain kit (siap ditempel ke dashboard):"
    grep -E '^[[:space:]]*- name:|^[[:space:]]*base_url:' "$HERMES_HOME/providers.yaml" 2>/dev/null | sed 's/^/    /' || true
  fi
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
