#!/data/data/com.termux/files/usr/bin/bash
# hermes-kit-update — tarik pembaruan kit dari GitHub tanpa menimpa config hidup.
#
# Git pull di ~/hermes-kit TIDAK PERNAH menyentuh $HOME/.hermes (config, .env,
# providers.yaml. memories, sessions) karena semua itu di luar repo. Yang perlu
# dijaga cuma providers.yaml milik kit sendiri.
#
# Pakai:
#   bash update.sh                 # pull + health check
#   bash update.sh --no-check      # pull saja
set -uo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DO_CHECK=1
for a in "$@"; do
  case "$a" in
    --no-check) DO_CHECK=0 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "argumen tidak dikenal: $a" >&2; exit 2 ;;
  esac
done

cd "$KIT" || exit 1
BEFORE=$(git rev-parse --short HEAD 2>/dev/null || echo "-")
echo "→ git pull di $KIT"
if ! git pull --ff-only 2>&1; then
  echo "✗ pull gagal (divergen / offline). Config hidup di ~/.hermes tidak tersentuh." >&2
  exit 1
fi
AFTER=$(git rev-parse --short HEAD 2>/dev/null || echo "-")
if [ "$BEFORE" = "$AFTER" ]; then echo "✓ sudah terbaru ($AFTER)"; else echo "✓ diperbarui $BEFORE → $AFTER"; fi

if [ "$DO_CHECK" = 1 ] && [ -f "$KIT/health_check.py" ]; then
  echo "→ health check"
  python3 "$KIT/health_check.py" --providers "${HERMES_HOME:-$HOME/.hermes}/providers.yaml" \
    --providers "$KIT/providers.yaml" --chat 2>/dev/null || true
fi
echo "✓ selesai. Config hidup (& .env) tidak diubah oleh update."
