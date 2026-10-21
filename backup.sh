#!/usr/bin/env bash
# backup.sh — cadangkan config + memories Hermes ke satu tarball (SPEC #6).
#
# Isi: config.yaml, .env (RAHASIA — tarball di-chmod 600), providers.yaml,
# file *.mode kit, auth.json, memories/, sessions/, state.db, scripts/.
# Hanya file yang ada yang dimasukkan.
#
# Pakai:
#   bash backup.sh [folder-tujuan]     # default: ~/hermes-backups
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
DEST="${1:-$HOME/hermes-backups}"
[ -d "$HERMES_HOME" ] || { echo "✗ $HERMES_HOME tidak ada" >&2; exit 1; }
mkdir -p "$DEST"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DEST/hermes-backup-$TS.tar.gz"

items=()
for f in config.yaml .env providers.yaml auth.json state.db \
         gateway.mode aimemory.mode apk-check.mode desktop-check.mode; do
  [ -e "$HERMES_HOME/$f" ] && items+=("$f")
done
for d in memories sessions scripts cron skills; do
  [ -d "$HERMES_HOME/$d" ] && items+=("$d")
done
[ ${#items[@]} -gt 0 ] || { echo "✗ tidak ada yang bisa dicadangkan di $HERMES_HOME" >&2; exit 1; }

tar -czf "$OUT" -C "$HERMES_HOME" "${items[@]}"
chmod 600 "$OUT"
echo "✓ backup: $OUT"
echo "  isi    : ${items[*]}"
echo "  sha256 : $(sha256sum "$OUT" | cut -d' ' -f1)"
echo "  ⚠ tarball ini berisi .env (API key) — simpan seperti menyimpan key itu sendiri."
