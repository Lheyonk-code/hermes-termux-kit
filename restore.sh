#!/usr/bin/env bash
# restore.sh — pulihkan backup dari backup.sh ke ~/.hermes (SPEC #6).
#
# Keamanan: keadaan ~/.hermes SAAT INI dicadangkan dulu otomatis ke
# ~/hermes-backups/pre-restore-<tanggal>.tar.gz sebelum apa pun ditimpa.
#
# Pakai:
#   bash restore.sh <file.tar.gz>
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
SRC="${1:-}"
[ -n "$SRC" ] && [ -f "$SRC" ] || { echo "pakai: bash restore.sh <file.tar.gz dari backup.sh>" >&2; exit 2; }

case "$SRC" in
  *.tar.gz|*.tgz) : ;;
  *) echo "✗ file harus .tar.gz dari backup.sh" >&2; exit 2 ;;
esac
# Tolak tarball berisi path absolut / .. (jangan sampai menulis keluar HERMES_HOME)
if tar -tzf "$SRC" | grep -qE '^/|\.\./'; then
  echo "✗ tarball berisi path tidak aman (absolut/..) — ditolak" >&2; exit 1
fi

mkdir -p "$HERMES_HOME" "$HOME/hermes-backups"
if [ -n "$(ls -A "$HERMES_HOME" 2>/dev/null)" ]; then
  PRE="$HOME/hermes-backups/pre-restore-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar -czf "$PRE" -C "$HERMES_HOME" . && chmod 600 "$PRE"
  echo "✓ keadaan sekarang dicadangkan dulu: $PRE"
fi

tar -xzf "$SRC" -C "$HERMES_HOME"
[ -f "$HERMES_HOME/.env" ] && chmod 600 "$HERMES_HOME/.env"
echo "✓ restore selesai dari: $SRC"
echo "  Langkah lanjut: restart service (sv restart hermes-serve / restart Termux),"
echo "  lalu cek: python3 health_check.py"
