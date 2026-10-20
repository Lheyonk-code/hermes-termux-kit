#!/usr/bin/env bash
# install.sh — Hermes Agent: satu perintah, langsung pakai.
#
# SATU script, DUA JALUR — platform dideteksi otomatis DI PALING AWAL
# (satu fungsi: detect_platform):
#   JALUR 1 — Termux/Android ($TERMUX_VERSION terisi, atau $PREFIX berakhir
#       "com.termux/files/usr"): perilaku asli kit, TIDAK berubah.
#   JALUR 2 — Windows via WSL2 (/proc/version mengandung Microsoft/WSL, atau
#       $WSL_DISTRO_NAME terisi, atau uname -r mengandung microsoft):
#       STATUS BETA — belum teruji end-to-end di mesin Windows asli.
#       - Langkah 0 (wizard provider+key), pilihan gateway (injector/9Router),
#         ai-memory opsional, health check: SAMA dengan JALUR 1.
#       - Hermes dipasang lewat installer resmi untuk Linux/WSL — BUKAN APT
#         canary Termux.
#       - Service: unit systemd bila systemd di WSL aktif ([boot] systemd=true
#         di /etc/wsl.conf); kalau tidak, script start manual terdokumentasi
#         (WSL tanpa systemd tidak punya autostart).
#       - Pengganti langkah cek-APK: arahan pemasangan Hermes Desktop
#         Companion di sisi Windows (link resmi ditampilkan; dari WSL tidak
#         bisa memasang aplikasi Windows secara diam-diam).
#   Platform lain yang tidak dikenal -> berhenti dengan pesan jelas.
#   (Override untuk pengujian: HERMES_PLATFORM=termux|wsl2|linux|unknown)
#
# Yang dikerjakan:
#   0. CETAK KUNCI DULU: cek ~/.hermes/.env + providers.yaml — kalau belum ada
#      key provider yang terisi, wizard interaktif menanyakan provider (nama,
#      base_url, model, API key), minimal 1, boleh lebih (auto-rotate sesuai
#      jumlah). Key HANYA ditulis ke ~/.hermes/.env (chmod 600); providers.yaml
#      memakai referensi "${ENV}". Sudah terisi = langkah ini dilewati (idempoten)
#   0b. CEK APK HERMES (Termux/Android): deteksi aplikasi mobile Hermes Agent
#       yang sudah terpasang di HP. Sudah ada -> "APK Hermes terdeteksi",
#       langkah DILEWATI. Belum -> tampilkan + buka link unduhan APK di
#       browser HP (termux-open-url bila ada), instruksi singkat, tunggu
#       user menekan Enter setelah memasang; pilihan lewati (dengan
#       peringatan) tersimpan di ~/.hermes/apk-check.mode (idempoten).
#       Aman-gagal: mekanisme deteksi tidak tersedia/diblokir ROM dianggap
#       dianggap jalur "belum terdeteksi" — install TIDAK digagalkan.
#       JALUR 2 (WSL2): diganti arahan pasang Hermes Desktop Companion di
#       sisi Windows (link resmi; dari WSL tidak bisa pasang aplikasi Windows).
#   1. Deteksi platform (satu fungsi, paling awal): termux -> JALUR 1;
#      wsl2/linux -> JALUR 2; lainnya -> berhenti dengan pesan jelas.
#      Lalu cek prerequisites dan pilih jalur install yang benar:
#      - Termux      : repo APT resmi Hermes (install.sh upstream SENGAJA menolak Termux)
#      - Linux/WSL2  : installer resmi dari hermes-agent.nousresearch.com
#   2. Verifikasi fingerprint PGP key repo sebelum dipakai
#   3. Seed ~/.hermes/config.yaml + ~/.hermes/.env (chmod 600) kalau belum ada
#   4. Tulis provider chain (providers.yaml) + tarik semua key ke .env
#   5. Pilih gateway: injector bawaan kit (DEFAULT, ringan, :20129) atau
#      9Router (opsional, Node.js, dashboard :20128) — SALING EKSKLUSIF,
#      hanya SATU yang dipasang/jalan
#   5c. KOMPONEN OPSIONAL ai-memory — ditanyakan SAAT SETELAH gateway,
#      DEFAULT TIDAK. Hanya kalau dijawab ya: server ai-memory (v3.1.1,
#      akitaonrails/ai-memory) di proot-debian, bind 127.0.0.1:49374,
#      service runsv `ai-memory` (autostart), config Hermes -> provider
#      ai-memory. Data lama TIDAK pernah disentuh saat install ulang.
#   6. Pasang service autostart: hermes-serve + gateway terpilih
#      (+ ai-memory hanya kalau dipilih) —
#      Termux: runsv (termux-services) | WSL2: unit systemd bila aktif,
#      selain itu script start manual terdokumentasi
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
#   bash install.sh --aimemory          # pasang ai-memory (opsional, default TIDAK)
#   bash install.sh --no-aimemory       # jangan pasang ai-memory
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

GATEWAY_MODE=""; DRY=0; WANT_SERVICES=1; WANT_INJECTOR=1; CHANNEL=""; AIMEMORY_FLAG=""
for a in "$@"; do case "$a" in
  --dry-run) DRY=1 ;;
  --no-services) WANT_SERVICES=0 ;;
  --no-injector) WANT_INJECTOR=0 ;;
  --gateway=*) GATEWAY_MODE="${a#--gateway=}" ;;
  --aimemory) AIMEMORY_FLAG=yes ;;
  --no-aimemory) AIMEMORY_FLAG=no ;;
  --canary) CHANNEL=canary ;;
  --stable) CHANNEL=stable ;;
  -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
  *) echo "argumen tidak dikenal: $a" >&2; exit 2 ;;
esac; done

log()  { printf '\033[1;36m→\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m⚠\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY" = 1 ]; then echo "  [dry] $*"; else "$@"; fi; }

is_termux() { [ -n "${TERMUX_VERSION:-}" ] || case "${PREFIX:-}" in *com.termux/files/usr*) true;; *) false;; esac; }

# ---------------------------------------------------------------------------
# DETEKSI PLATFORM — satu fungsi, hasilnya menentukan JALUR:
#   termux -> JALUR 1 (perilaku asli, tidak berubah)
#   wsl2   -> JALUR 2 (Windows via WSL2 — beta)
#   linux  -> JALUR 2 varian Linux biasa (perilaku lama non-Termux)
#   unknown-> berhenti dengan pesan jelas (lihat dispatch di bawah)
# Override untuk pengujian lintas platform: HERMES_PLATFORM=<nilai>
# ---------------------------------------------------------------------------
is_wsl() {
  [ -n "${WSL_DISTRO_NAME:-}" ] && return 0
  grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null && return 0
  case "$(uname -r 2>/dev/null)" in *microsoft*|*WSL*) return 0 ;; esac
  return 1
}
detect_platform() {
  case "${HERMES_PLATFORM:-}" in
    termux|wsl2|linux|unknown) PLATFORM="$HERMES_PLATFORM"; return 0 ;;
    '') ;;
    *) die "HERMES_PLATFORM tidak dikenal: $HERMES_PLATFORM (pakai termux|wsl2|linux|unknown)" ;;
  esac
  if is_termux; then PLATFORM=termux
  elif is_wsl; then PLATFORM=wsl2
  elif [ "$(uname -s 2>/dev/null)" = Linux ]; then PLATFORM=linux
  else PLATFORM=unknown; fi
}
detect_platform
case "$PLATFORM" in
  termux) ok "Platform terdeteksi: Termux/Android — JALUR 1 (perilaku tidak berubah)" ;;
  wsl2)   ok "Platform terdeteksi: Windows via WSL2 — JALUR 2 (BETA — belum teruji end-to-end di mesin Windows asli)" ;;
  linux)  ok "Platform terdeteksi: Linux — JALUR 2 (varian Linux biasa)" ;;
  *)      die "Platform tidak didukung: $(uname -s 2>/dev/null || echo '?'). Kit ini untuk Termux/Android (JALUR 1) atau Windows via WSL2 / Linux (JALUR 2). Lihat README.md." ;;
esac


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
# LANGKAH 0b — CEK APK HERMES (aplikasi mobile Hermes Agent di HP Android).
# Urutan: setelah Langkah 0 (wizard provider), sebelum setup service.
#   - APK sudah terpasang  -> "APK Hermes terdeteksi", langkah DILEWATI.
#   - Belum terpasang      -> tampilkan link unduhan, buka di browser HP
#                             (termux-open-url/termux-open bila tersedia),
#                             instruksi singkat, TUNGGU Enter setelah user
#                             selesai memasang. Pilihan "s" = lewati dengan
#                             peringatan; pilihan lewati tersimpan di
#                             $APKF supaya install ulang tidak mengarahkan lagi.
#   - Aman-gagal           -> mekanisme deteksi tidak tersedia/diblokir ROM
#                             dianggap jalur "belum terdeteksi"; install
#                             TIDAK digagalkan.
# Idempoten: HP yang sudah punya APK tidak pernah melihat arahan ini lagi.
# Deteksi: `pm list packages` (fallback `cmd package list packages`) — tidak
# butuh root. Di Linux non-Termux langkah ini dilewati (tidak relevan).
# Link unduhan bisa dioverride: HERMES_APK_URL=... bash install.sh
# Catatan kejujuran: TIDAK ada APK Android resmi dari Nous Research
# (jalur resminya desktop/Termux). Aplikasi di tautan default adalah
# Hermes Mobile (omarqaterge) — aplikasi KOMUNITAS open-source (MIT)
# yang didistribusikan lewat repo GitHub-nya — bukan buatan Nous.
# Bebas diganti user.
# ---------------------------------------------------------------------------
APKF="$HERMES_HOME/apk-check.mode"             # "skip" = user memilih lewati
HERMES_APK_URL="${HERMES_APK_URL:-https://github.com/omarqaterge/hermes-mobile-app/releases/latest}"
APK_PKGS="${HERMES_APK_PKGS:-com.omarqaterge.hermesmobile com.hermesagent.android com.xermes.xermes}"  # dikenali bila salah satu cocok

# --- Langkah 0b untuk JALUR 2 (WSL2): arahan Hermes Desktop Companion ------
# Dari WSL TIDAK BISA memasang aplikasi Windows secara diam-diam — cukup
# arahan + link resmi, lalu pilihan lewati tersimpan di $DESKF (idempoten).
# Desktop Companion BERSIFAT OPSIONAL: tanpa itu Hermes di WSL tetap jalan
# penuh dari terminal. Link bisa dioverride: HERMES_DESKTOP_URL=... bash install.sh
DESKF="$HERMES_HOME/desktop-check.mode"   # "skip" = user memilih lewati (WSL2)
HERMES_DESKTOP_URL="${HERMES_DESKTOP_URL:-https://hermes-agent.nousresearch.com/desktop}"
HERMES_DESKTOP_STORE="${HERMES_DESKTOP_STORE:-https://apps.microsoft.com/detail/9pmxk8czc7kr}"
HERMES_DESKTOP_DOCS="${HERMES_DESKTOP_DOCS:-https://hermes-agent.nousresearch.com/docs/user-guide/desktop}"

wsl_desktop_check() {
  if [ -r "$DESKF" ] && grep -q '^skip$' "$DESKF" 2>/dev/null; then
    ok "Langkah 0b: dilewati (pilihan 'lewati Desktop Companion' tersimpan di $DESKF — idempoten)"
    return 0
  fi
  warn 'Langkah 0b (JALUR 2): dari WSL tidak bisa mendeteksi/memasang aplikasi Windows secara diam-diam.'
  warn 'Hermes Desktop Companion (aplikasi Windows, opsional) dipasang MANUAL di sisi Windows:'
  echo "  Halaman unduhan resmi : $HERMES_DESKTOP_URL"
  echo "  Microsoft Store       : $HERMES_DESKTOP_STORE"
  echo "  Dokumentasi           : $HERMES_DESKTOP_DOCS"
  echo '  Cara: buka link di atas dari browser WINDOWS -> unduh installer -> pasang'
  echo '  seperti aplikasi Windows biasa. Tanpa Desktop Companion pun, Hermes di'
  echo '  WSL tetap jalan penuh dari terminal (CLI + service).'
  if [ -t 0 ]; then
    read -r -p '  Sudah dipasang / memilih lewati? Enter = lanjut / s = lewati (tersimpan) [Enter/s]: ' desk_choice
    case "${desk_choice:-}" in
      s|S)
        warn "DILEWATI: arahan Desktop Companion tidak ditampilkan lagi. Pilihan tersimpan di $DESKF (hapus file itu bila berubah pikiran)."
        if [ "$DRY" = 0 ]; then
          mkdir -p "$HERMES_HOME" 2>/dev/null || true
          printf 'skip\n' > "$DESKF"
          chmod 644 "$DESKF" 2>/dev/null || true
        fi
        ;;
      *) ok 'Lanjut — Desktop Companion bisa dipasang kapan pun dari link di atas.' ;;
    esac
    unset desk_choice
  else
    warn 'Mode non-interaktif: arahan di atas saja — install dilanjutkan.'
  fi
}


apk_detect() {
  # stdout: nama paket yang cocok (bila terpasang).
  # RC: 0 = terpasang, 1 = tidak ketemu, 2 = mekanisme deteksi tidak
  #     tersedia/diblokir (pemanggil memperlakukannya spt 1, dgn peringatan).
  local src pkgs_re hit
  if ! src="$(pm list packages 2>/dev/null)" || [ -z "$src" ]; then
    if ! src="$(cmd package list packages 2>/dev/null)" || [ -z "$src" ]; then
      return 2
    fi
  fi
  pkgs_re="$(printf '%s' "$APK_PKGS" | sed 's/[[:space:]]\+/|/g; s/\./\\./g')"
  hit="$(printf '%s\n' "$src" | grep -m1 -oE "^package:($pkgs_re)")"
  if [ -n "$hit" ]; then
    printf '%s\n' "${hit#package:}"
    return 0
  fi
  return 1
}

if [ "$DRY" = 1 ]; then
  echo '  [dry] Langkah 0b: cek APK Hermes / Desktop Companion (deteksi dilewati di dry-run)'
elif [ "$PLATFORM" = wsl2 ]; then
  wsl_desktop_check
elif ! is_termux; then
  ok 'Langkah 0b: host bukan Termux/Android — cek APK Hermes dilewati (tidak relevan)'
else
  apk_rc=0
  apk_found="$(apk_detect)" || apk_rc=$?
  if [ "$apk_rc" = 0 ]; then
    ok "APK Hermes terdeteksi ($apk_found) — Langkah 0b dilewati (idempoten)"
  elif [ -r "$APKF" ] && grep -q '^skip$' "$APKF" 2>/dev/null; then
    ok "Langkah 0b: dilewati (pilihan 'lewati APK' tersimpan di $APKF — idempoten)"
  else
    [ "$apk_rc" = 2 ] \
      && warn 'Deteksi paket tidak tersedia/diblokir ROM — dianggap jalur "belum terdeteksi"; install tidak digagalkan.'
    warn 'APK Hermes (aplikasi mobile Hermes Agent) belum terdeteksi di HP ini.'
    echo '  Catatan: aplikasi default = Hermes Mobile (omarqaterge), aplikasi'
    echo '           komunitas open-source — bukan aplikasi resmi Nous Research.'
    echo "  Link unduhan APK Hermes : $HERMES_APK_URL"
    log 'Membuka link di browser HP...'
    if command -v termux-open-url >/dev/null 2>&1; then
      run termux-open-url "$HERMES_APK_URL"
    elif command -v termux-open >/dev/null 2>&1; then
      run termux-open "$HERMES_APK_URL"
    else
      warn 'termux-open-url/termux-open tidak tersedia — buka link di atas manual di browser HP.'
    fi
    echo '  Instruksi singkat:'
    echo '   1. Buka link di atas di browser HP, lalu pasang APK Hermes (di Play Store: tap Install).'
    echo '      Kalau pasang dari file .apk luar toko: izinkan "install aplikasi tak dikenal".'
    echo '   2. Setelah APK terpasang, kembali ke sini dan tekan Enter untuk lanjut install.'
    if [ -t 0 ]; then
      read -r -p '  Sudah selesai memasang APK? Enter = lanjut (APK dilewati dulu) / s = lewati [Enter/s]: ' apk_choice
      case "${apk_choice:-}" in
        s|S)
          warn "DILEWATI: tanpa APK mobile, Hermes hanya bisa dipakai dari terminal Termux — tidak ada antarmuka aplikasi di HP. Pilihan tersimpan di $APKF (hapus file itu bila berubah pikiran)."
          if [ "$DRY" = 0 ]; then
            mkdir -p "$HERMES_HOME" 2>/dev/null || true
            printf 'skip\n' > "$APKF"
            chmod 644 "$APKF" 2>/dev/null || true
          fi
          ;;
        *)
          if apk_now="$(apk_detect)"; then
            ok "APK Hermes terdeteksi: $apk_now — lanjut install"
          else
            warn 'Masih belum terdeteksi (bila mekanisme deteksi diblokir ROM ini wajar) — install lanjut; APK bisa dipasang kapan pun dari link di atas.'
          fi
          ;;
      esac
    else
      warn 'Mode non-interaktif: tidak bisa menunggu — pasang APK manual dari link di atas; install dilanjutkan.'
    fi
    unset apk_choice apk_now
  fi
  unset apk_found apk_rc
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
# KOMPONEN OPSIONAL — ai-memory (akitaonrails/ai-memory v3.1.1).
# DEFAULT TIDAK. Hanya kalau user jawab ya:
#   - server jalan di proot-debian (pola terbukti di Termux), bind 127.0.0.1:49374
#   - service runsv `ai-memory` (autostart)
#   - config Hermes diarahkan ke memory.provider: ai-memory
#   - LLM konsolidasi memakai provider chain MILIK USER dari wizard
#     (providers.yaml + ~/.hermes/.env) — TANPA gateway pihak ketiga.
# Kalau tidak dipilih: TIDAK ada yang dipasang; health_check.py memperlakukan
# service ai-memory yang absen sebagai "tidak dipilih" (netral, bukan merah).
# Idempoten: data ai-memory (~/.local/share/ai-memory) TIDAK pernah disentuh.
# Butuh resource ekstra (proot-debian: ~1GB storage + RAM saat jalan) —
# tidak disarankan untuk HP RAM <= 3GB.
# ---------------------------------------------------------------------------
AMF="$HERMES_HOME/aimemory.mode"   # yes|no — tersimpan supaya install ulang tak menanya lagi
AIM_VER="3.1.1"

# sq <teks> — escape single-quote (buat penulisan nilai aman di file env)
sq() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }

# aim_llm_wire <providers.yaml> — baca provider PERTAMA (priority tertinggi)
# dan siapkan AM_BASE / AM_MODEL / AM_KEYVAR (NAMA variabel key, bukan isinya).
aim_llm_wire() {
  local yaml="$1" block base model var
  [ -r "$yaml" ] || return 1
  block="$(awk '/^[[:space:]]*-[[:space:]]*name:/{ if (f) exit; f=1 } f{ print }' "$yaml")"
  [ -n "$block" ] || return 1
  base="$(printf '%s\n' "$block" | sed -n 's/^[[:space:]]*base_url:[[:space:]]*//p' | head -1 | tr -d '"')"
  model="$(printf '%s\n' "$block" | sed -n 's/^[[:space:]]*default_model:[[:space:]]*//p' | head -1 | tr -d '"')"
  var="$(printf '%s\n' "$block" | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' | head -1 | tr -d '${}')"
  [ -n "$base" ] && [ -n "$var" ] || return 1
  AM_BASE="$base"; AM_MODEL="$model"; AM_KEYVAR="$var"
  return 0
}

# Pilih ya/tidak: flag > file tersimpan > wizard interaktif (Enter = TIDAK) > no
AIMEMORY=""
case "$AIMEMORY_FLAG" in yes) AIMEMORY=yes ;; no) AIMEMORY=no ;; esac
if [ -z "$AIMEMORY" ] && [ -r "$AMF" ]; then
  AIMEMORY="$(head -1 "$AMF" 2>/dev/null | tr -d '[:space:]')"
  case "$AIMEMORY" in yes|no) ;; *) AIMEMORY="" ;; esac
fi
if [ -z "$AIMEMORY" ]; then
  if [ "$DRY" = 1 ]; then
    echo "  [dry] pertanyaan opsional: 'Pasang ai-memory?' (default: tidak)"
  elif [ -t 0 ]; then
    echo
    echo '== Komponen opsional: ai-memory =='
    echo "  Server memori persisten Hermes (akitaonrails/ai-memory v$AIM_VER),"
    echo '  jalan di proot-debian, bind 127.0.0.1:49374.'
    echo '  Butuh resource ekstra: proot-debian ~1GB storage + RAM saat jalan'
    echo '  — TIDAK disarankan untuk HP RAM <= 3GB.'
    read -r -p 'Pasang ai-memory? [y/N]: ' am_choice
    case "${am_choice:-n}" in y|Y) AIMEMORY=yes ;; *) AIMEMORY=no ;; esac
    if [ "$DRY" = 0 ]; then
      mkdir -p "$HERMES_HOME" 2>/dev/null || true
      printf '%s\n' "$AIMEMORY" > "$AMF"
      chmod 644 "$AMF" 2>/dev/null || true
    fi
  else
    AIMEMORY=no   # non-interaktif tanpa flag = default TIDAK
    if [ "$DRY" = 0 ]; then printf '%s\n' "$AIMEMORY" > "$AMF" 2>/dev/null || true; fi
  fi
fi
case "$AIMEMORY" in
  yes) ok "ai-memory: DIPASANG (pilihan tersimpan di $AMF)" ;;
  *)   ok "ai-memory: tidak dipasang (opsi default tidak — pakai --aimemory bila berubah pikiran)" ;;
esac

if [ "$AIMEMORY" = yes ] && [ "$DRY" = 0 ]; then
  am_datadir="$HOME/.local/share/ai-memory"   # data di sisi host, di-mount ke proot — install ulang tidak menyentuhnya
  run mkdir -p "$am_datadir"
  # --- binary server --------------------------------------------------------
  if is_termux; then
    command -v proot-distro >/dev/null 2>&1 || { log "proot-distro belum ada — install"; run pkg install -y proot-distro; }
    if proot-distro list --installed 2>/dev/null | grep -q '^debian'; then
      ok "proot-debian sudah ada — dipakai apa adanya (idempoten)"
    else
      log "proot-debian belum ada — install (unduhan besar, sekali saja)"
      run proot-distro install debian
    fi
    log "Dependency di dalam proot-debian (ca-certificates, curl)"
    run proot-distro login debian -- /bin/sh -c "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq; apt-get install -y -qq ca-certificates curl"
    if proot-distro login debian -- test -x /root/.local/bin/ai-memory; then
      ok "binary ai-memory sudah ada di proot-debian (tidak diunduh ulang — data aman)"
    else
      log "Pasang ai-memory v$AIM_VER (installer resmi upstream, sha256 diverifikasi sebelum unpack)"
      run proot-distro login debian -- /bin/sh -c "curl -fsSL https://github.com/akitaonrails/ai-memory/releases/download/v${AIM_VER}/install.sh -o /tmp/ai-memory-install.sh && AI_MEMORY_VERSION=${AIM_VER} sh /tmp/ai-memory-install.sh"
    fi
    proot-distro login debian -- /root/.local/bin/ai-memory --version 2>/dev/null \
      || warn "binary ai-memory belum terverifikasi — cek unduhan/arsitektur"
  else
    # Linux non-Termux: proot tidak diperlukan — binary di host langsung.
    if [ -x "$HOME/.local/bin/ai-memory" ]; then
      ok "ai-memory sudah ada: $HOME/.local/bin/ai-memory"
    else
      log "Pasang ai-memory v$AIM_VER (installer resmi upstream, sha256 diverifikasi)"
      am_tmp="$(mktemp)"
      run curl -fsSL "https://github.com/akitaonrails/ai-memory/releases/download/v${AIM_VER}/install.sh" -o "$am_tmp"
      run sh -c "AI_MEMORY_VERSION=${AIM_VER} sh '$am_tmp'"
      rm -f "$am_tmp"
    fi
    warn "Linux: jalankan sendiri server-nya atau buat unit systemd — contoh:"
    echo "     $HOME/.local/bin/ai-memory serve --transport http --bind 127.0.0.1:49374 --data-dir $HOME/.local/share/ai-memory"
  fi
  # --- LLM konsolidasi dari provider chain milik user (tanpa gateway ketiga) -
  if aim_llm_wire "$HERMES_HOME/providers.yaml"; then
    {
      echo '# aimemory.env — LLM konsolidasi ai-memory dari provider chain milik user.'
      echo '# TIDAK ada key plaintext di sini: hanya NAMA variabel; isinya diekspor'
      echo '# saat service start dari ~/.hermes/.env (chmod 600). Tanpa Tor, tanpa Bariska,'
      echo '# tanpa gateway pihak ketiga.'
      printf "export AI_MEMORY_LLM_PROVIDER=openai\n"
      printf "export AI_MEMORY_LLM_BASE_URL='%s'\n" "$(sq "$AM_BASE")"
      [ -n "$AM_MODEL" ] && printf "export AI_MEMORY_LLM_MODEL='%s'\n" "$(sq "$AM_MODEL")"
      printf 'export OPENAI_API_KEY="${%s}"\n' "$AM_KEYVAR"
    } > "$HERMES_HOME/aimemory.env"
    chmod 600 "$HERMES_HOME/aimemory.env"
    ok "Konsolidasi LLM ai-memory <- chain milikmu (${AM_BASE#https://}, key=\${$AM_KEYVAR} dari $ENVF)"
  else
    : > "$HERMES_HOME/aimemory.env" 2>/dev/null || true
    chmod 600 "$HERMES_HOME/aimemory.env" 2>/dev/null || true
    warn "Provider chain belum terbaca — ai-memory jalan zero-LLM dulu (FTS tetap hidup); jalankan ulang install.sh setelah wizard provider"
  fi
  # --- config Hermes: memory.provider: ai-memory ----------------------------
  am_cfg="$HERMES_HOME/config.yaml"
  if [ -f "$am_cfg" ]; then
    if sed -n '/^memory:/,/^[^[:space:]#-]/p' "$am_cfg" | grep -qE '^[[:space:]]*provider:'; then
      [ "$(sed -n '/^memory:/,/^[^[:space:]#-]/p' "$am_cfg" | sed -n 's/^[[:space:]]*provider:[[:space:]]*//p' | head -1)" = "ai-memory" ] \
        && ok "config.yaml sudah memakai memory.provider: ai-memory" \
        || { awk '/^memory:/{m=1; print; next} /^[^[:space:]#]/{m=0} m&&/^[[:space:]]*provider:/{sub(/provider:.*/, "provider: ai-memory")} {print}' "$am_cfg" > "$am_cfg.tmp.$$" && mv "$am_cfg.tmp.$$" "$am_cfg"; ok "config.yaml: memory.provider diarahkan ke ai-memory"; }
    else
      sed -i '/^memory:/a\  provider: ai-memory' "$am_cfg"
      ok "config.yaml: memory.provider: ai-memory ditambahkan"
    fi
  else
    printf 'memory:\n  provider: ai-memory\n  memory_enabled: true\n' > "$am_cfg"
    ok "config.yaml dibuat dengan memory.provider: ai-memory (lanjutkan: hermes setup)"
  fi
  # pointer klien Hermes -> server lokal (tanpa kredensial)
  am_json="$HERMES_HOME/ai-memory.json"
  [ -f "$am_json" ] || printf '{\n  "server_url": "http://127.0.0.1:49374",\n  "workspace": "hermes",\n  "project": "hermes-default"\n}\n' > "$am_json"
elif [ "$AIMEMORY" != yes ] && is_termux && [ -d "${SVC_DIR}/ai-memory" ]; then
  warn "ai-memory tidak dipilih, tapi service lama masih terpasang — matikan manual bila mau:"
  echo "     sv down ai-memory && rm -r \"${SVC_DIR}/ai-memory\"   (data di ~/.local/share/ai-memory tetap aman)"
fi


# ---------------------------------------------------------------------------
case "$PLATFORM" in
  termux) host_lbl='Termux/Android — JALUR 1' ;;
  wsl2)   host_lbl='Windows via WSL2 — JALUR 2 (beta)' ;;
  linux)  host_lbl='Linux — JALUR 2 (varian Linux)' ;;
esac
log "Host: $host_lbl  |  HOME=$HOME"
unset host_lbl
[ "$DRY" = 1 ] && warn "DRY-RUN: tidak ada yang benar-benar diubah"

# --- 1. prerequisites ------------------------------------------------------
log "Cek prerequisites (git, curl, gnupg)..."
need=(); for t in git curl gnupg; do command -v "$t" >/dev/null 2>&1 || need+=("$t"); done
case "$PLATFORM" in wsl2|linux) command -v python3 >/dev/null 2>&1 || need+=("python3") ;; esac
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
    log "Linux/WSL2: jalankan installer resmi (bukan APT canary Termux)"
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

# --- 5. services — tiap platform punya mekanisme sendiri -------------------
# JALUR 2 (WSL2): unit systemd bila systemd WSL aktif, selain itu start manual.
wsl_has_systemd() {
  # true bila systemd di WSL benar-benar hidup ([boot] systemd=true di /etc/wsl.conf)
  [ -d /run/systemd/system ] || return 1
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl is-system-running 2>/dev/null | grep -qE '^(running|degraded)$'
}

wsl_write_unit() {
  # wsl_write_unit <unit-tanpa-suffix> <deskripsi> <ExecStart> <extra-EnvironmentFile>
  local unit="$1" desc="$2" eline="$3" extra="$4" f
  f="$(mktemp)"
  {
    printf '[Unit]\n'
    printf 'Description=%s (hermes-termux-kit, JALUR 2/WSL2)\n' "$desc"
    printf 'After=network-online.target\nWants=network-online.target\n\n'
    printf '[Service]\nType=simple\n'
    [ "$(id -u)" != 0 ] && printf 'User=%s\n' "$(id -un 2>/dev/null)"
    printf 'Environment=HOME=%s\n' "$HOME"
    printf 'EnvironmentFile=-%s\n' "$ENVF"               # key RESTI di sini; '- ' = boleh absen
    [ -n "$extra" ] && printf 'EnvironmentFile=-%s\n' "$extra"
    printf 'ExecStart=%s\n' "$eline"
    printf 'Restart=on-failure\nRestartSec=5\n\n'
    printf '[Install]\nWantedBy=multi-user.target\n'
  } > "$f"
  run $WSL_SUDO install -m 644 "$f" "/etc/systemd/system/$unit.service"
  rm -f "$f"
}

wsl_start_script() {
  # Fallback TANPA systemd: tulis script start manual (idempoten, aman diulang).
  # WSL tanpa systemd tidak punya autostart — script dijalankan per sesi.
  local script="$HERMES_HOME/start-hermes-wsl.sh"
  if [ -x "$script" ]; then
    ok "script start manual sudah ada: $script (idempoten — pilihan baru ikut saat ditulis ulang)"
  fi
  if [ "$DRY" = 1 ]; then
    echo "  [dry] tulis $script (start manual tanpa systemd)"
    return 0
  fi
  local bin_py bin_9r
  bin_py="$(command -v python3 2>/dev/null || printf '/usr/bin/python3')"
  bin_9r="$(command -v 9router 2>/dev/null || printf '9router')"
  mkdir -p "$HERMES_HOME"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "# start-hermes-wsl.sh — JALUR 2 (WSL2 tanpa systemd): start manual service kit."
    printf '%s\n' "# Dibuat otomatis oleh install.sh — idempoten, boleh dijalankan berulang."
    printf '%s\n' "# Pilihan saat dibuat: gateway=$GATEWAY, ai-memory=$AIMEMORY."
    printf '%s\n\n' 'set -u'
    printf 'HERMES_HOME="%s"\n' "$HERMES_HOME"
    printf '%s\n' 'PID_DIR="$HERMES_HOME/pids"; LOG_DIR="$HERMES_HOME/logs"'
    printf '%s\n' 'mkdir -p "$PID_DIR" "$LOG_DIR"'
    printf '%s\n' 'start_bg() { # <nama> <perintah...>'
    printf '%s\n' '  local name="$1"; shift'
    printf '%s\n' '  if [ -f "$PID_DIR/$name.pid" ] && kill -0 "$(cat "$PID_DIR/$name.pid" 2>/dev/null)" 2>/dev/null; then'
    printf '%s\n' '    echo "$name sudah jalan (pid $(cat "$PID_DIR/$name.pid"))"; return 0'
    printf '%s\n' '  fi'
    printf '%s\n' '  nohup "$@" >> "$LOG_DIR/$name.log" 2>&1 &'
    printf '%s\n' '  echo $! > "$PID_DIR/$name.pid"'
    printf '%s\n' '  echo "$name dimulai (pid $!, log $LOG_DIR/$name.log)"'
    printf '%s\n' '}'
    printf '%s\n' 'stop_bg() { # <nama>'
    printf '%s\n' '  [ -f "$PID_DIR/$1.pid" ] || return 0'
    printf '%s\n' '  kill "$(cat "$PID_DIR/$1.pid")" 2>/dev/null || true; rm -f "$PID_DIR/$1.pid"'
    printf '%s\n' '}'
    printf '%s\n' '[ -f "$HERMES_HOME/.env" ] && . "$HERMES_HOME/.env"'
    printf '\n'
    printf '%s\n' 'stop_bg hermes-serve; start_bg hermes-serve hermes serve --host 127.0.0.1 --port 9119'
    case "$GATEWAY" in
      injector) [ "$WANT_INJECTOR" = 1 ] && printf '%s\n' "stop_bg injector; start_bg injector $bin_py '$ROOT/tools/injector.py' serve -p 20129" ;;
      9router)  printf '%s\n' "stop_bg 9router; start_bg 9router $bin_9r" ;;
    esac
    if [ "$AIMEMORY" = yes ]; then
      printf '%s\n' "stop_bg ai-memory; start_bg ai-memory bash -c '. \"\$HOME/.hermes/.env\"; [ -f \"\$HOME/.hermes/aimemory.env\" ] && . \"\$HOME/.hermes/aimemory.env\"; exec \"\$HOME/.local/bin/ai-memory\" serve --transport http --bind 127.0.0.1:49374 --data-dir \"\$HOME/.local/share/ai-memory\"'"
    fi
    printf '%s\n' 'echo "Selesai. Stop manual: kill \$(cat $HERMES_HOME/pids/<nama>.pid)"'
  } > "$script"
  chmod 700 "$script"
  ok "script start manual ditulis: $script"
}

wsl_service_setup() {
  # JALUR 2 — pasangan service SAMA dengan JALUR 1: hermes-serve + SATU
  # gateway terpilih (+ ai-memory hanya kalau dipilih). Saling eksklusif.
  WSL_SUDO=""
  [ "$(id -u)" = 0 ] || { command -v sudo >/dev/null 2>&1 && WSL_SUDO=sudo; }
  if wsl_has_systemd; then
    log "WSL2: systemd aktif — pasang unit systemd (prefiks hermes-kit-)"
    local hermes_bin py_bin r9_bin
    hermes_bin="$(command -v hermes 2>/dev/null || printf '%s/.local/bin/hermes' "$HOME")"
    py_bin="$(command -v python3 2>/dev/null || printf '/usr/bin/python3')"
    # saling eksklusif seperti JALUR 1: matikan unit gateway yang tidak terpilih
    if [ "$GATEWAY" = 9router ] && [ -f /etc/systemd/system/hermes-kit-injector.service ]; then
      log "Matikan unit injector (gateway aktif: 9Router)"
      run $WSL_SUDO systemctl disable --now hermes-kit-injector.service
      run $WSL_SUDO rm -f /etc/systemd/system/hermes-kit-injector.service
    fi
    if [ "$GATEWAY" = injector ] && [ -f /etc/systemd/system/hermes-kit-9router.service ]; then
      log "Matikan unit 9router (gateway aktif: injector)"
      run $WSL_SUDO systemctl disable --now hermes-kit-9router.service
      run $WSL_SUDO rm -f /etc/systemd/system/hermes-kit-9router.service
    fi
    if [ -f /etc/systemd/system/hermes-kit-hermes-serve.service ]; then
      ok "unit hermes-kit-hermes-serve sudah ada (tidak ditulis ulang)"
    else
      log "Pasang unit hermes-kit-hermes-serve (hermes serve :9119)"
      wsl_write_unit "hermes-kit-hermes-serve" "Hermes Agent serve" \
        "$hermes_bin serve --host 127.0.0.1 --port 9119" ""
    fi
    case "$GATEWAY" in
      injector)
        if [ "$WANT_INJECTOR" = 1 ]; then
          if [ -f /etc/systemd/system/hermes-kit-injector.service ]; then
            ok "unit hermes-kit-injector sudah ada"
          else
            log "Pasang unit hermes-kit-injector (tools/injector.py :20129)"
            wsl_write_unit "hermes-kit-injector" "Hermes kit injector gateway" \
              "$py_bin $ROOT/tools/injector.py serve -p 20129" ""
          fi
        fi ;;
      9router)
        r9_bin="$(command -v 9router 2>/dev/null || true)"
        [ -n "$r9_bin" ] || die "9Router belum ketemu di PATH — install dulu: npm install -g 9router"
        if [ -f /etc/systemd/system/hermes-kit-9router.service ]; then
          ok "unit hermes-kit-9router sudah ada"
        else
          log "Pasang unit hermes-kit-9router (dashboard :20128)"
          wsl_write_unit "hermes-kit-9router" "Hermes kit 9Router gateway" "$r9_bin" ""
        fi ;;
    esac
    if [ "$AIMEMORY" = yes ]; then
      if [ -f /etc/systemd/system/hermes-kit-ai-memory.service ]; then
        ok "unit hermes-kit-ai-memory sudah ada"
      else
        log "Pasang unit hermes-kit-ai-memory (bind 127.0.0.1:49374)"
        # aimemory.env memakai baris 'export ...' — di-source via wrapper bash,
        # bukan EnvironmentFile (formatnya tidak kompatibel systemd).
        wsl_write_unit "hermes-kit-ai-memory" "ai-memory server (Hermes kit)" \
          "/bin/bash -c '. \"\$HOME/.hermes/.env\"; [ -f \"\$HOME/.hermes/aimemory.env\" ] && . \"\$HOME/.hermes/aimemory.env\"; exec \"\$HOME/.local/bin/ai-memory\" serve --transport http --bind 127.0.0.1:49374 --data-dir \"\$HOME/.local/share/ai-memory\"'" ""
      fi
    fi
    run $WSL_SUDO systemctl daemon-reload
    run $WSL_SUDO systemctl enable --now hermes-kit-hermes-serve.service
    case "$GATEWAY" in
      injector) [ "$WANT_INJECTOR" = 1 ] && run $WSL_SUDO systemctl enable --now hermes-kit-injector.service ;;
      9router)  run $WSL_SUDO systemctl enable --now hermes-kit-9router.service ;;
    esac
    [ "$AIMEMORY" = yes ] && run $WSL_SUDO systemctl enable --now hermes-kit-ai-memory.service
    ok "unit systemd terpasang & di-enable — cek: systemctl --no-pager status 'hermes-kit-*'"
  else
    warn "WSL2: systemd TIDAK aktif — WSL tanpa systemd tidak punya autostart."
    wsl_start_script
    echo '  Cara pakai start manual:'
    echo "    bash $HERMES_HOME/start-hermes-wsl.sh      # tiap awal sesi WSL"
    echo '    (opsional: tambahkan baris itu ke ~/.bashrc, atau pakai Task Scheduler Windows)'
    echo '  Mau autostart sungguhan? Aktifkan systemd di WSL: tambahkan di /etc/wsl.conf lalu'
    echo '    [boot]'
    echo '    systemd=true'
    echo '  jalankan "wsl --shutdown" dari PowerShell Windows, masuk WSL lagi, lalu jalankan'
    echo '  ulang install.sh — unit systemd akan dipasang otomatis.'
  fi
}

if [ "$WANT_SERVICES" = 1 ] && [ "$PLATFORM" = termux ]; then
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
  # Service ai-memory (opsional, hanya kalau dipilih): proot-debian + bind loopback.
  if [ "$AIMEMORY" = yes ]; then
    am_home="$(dirname "$PREFIX")/home"
    if [ -d "$SVC_DIR/ai-memory" ]; then
      ok "service ai-memory sudah ada"
    else
      log "Pasang service ai-memory (autostart: ai-memory di proot-debian, 127.0.0.1:49374)"
      run mkdir -p "$SVC_DIR/ai-memory"
      {
        printf '#!/data/data/com.termux/files/usr/bin/sh\n'
        printf 'export HOME="%s"\n' "$am_home"
        printf 'export PATH="${PREFIX:-/data/data/com.termux/files/usr}/bin:$PATH"\n'
        printf '[ -f "$HOME/.hermes/.env" ] && . "$HOME/.hermes/.env"\n'
        printf '[ -f "$HOME/.hermes/aimemory.env" ] && . "$HOME/.hermes/aimemory.env"\n'
        printf 'exec proot-distro login debian --bind "$HOME/.local/share/ai-memory:/root/.local/share/ai-memory" -- /root/.local/bin/ai-memory serve --transport http --bind 127.0.0.1:49374 --data-dir /root/.local/share/ai-memory\n'
      } | run tee "$SVC_DIR/ai-memory/run" >/dev/null
      run chmod 700 "$SVC_DIR/ai-memory/run"
    fi
  fi
  if [ "$DRY" = 0 ]; then
    sv up hermes-serve 2>/dev/null || true
    case "$GATEWAY" in
      injector) sv up injector 2>/dev/null || true ;;
      9router)  sv up 9router 2>/dev/null || true ;;
    esac
    [ "$AIMEMORY" = yes ] && sv up ai-memory 2>/dev/null || true
  fi
  ok "service dipasang — gateway aktif: $GATEWAY (restart terminal supaya runsvdir memuatnya)"
elif [ "$WANT_SERVICES" = 1 ] && [ "$PLATFORM" = wsl2 ]; then
  wsl_service_setup
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
if [ "$PLATFORM" = wsl2 ]; then
  echo "  WSL2 (JALUR 2, beta): Desktop Companion dipasang manual dari sisi Windows (link ditampilkan di Langkah 0b — opsional)."
fi
echo "  hermes -z \"halo\"                 # pakai sekarang"
echo "  python3 $ROOT/health_check.py     # cek sehat semua provider"
echo "  python3 $ROOT/rotate_keys.py --rotate --providers $HERMES_HOME/providers.yaml"
echo "  hermes doctor"
