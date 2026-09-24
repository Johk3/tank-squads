#!/usr/bin/env bash
# Validate every __base__ asset path this mod references.
#
# Why this exists outside the RCON test suite: the headless server never loads
# image files, so a prototype naming a non-existent sprite loads perfectly in
# test/run.sh and then fails on a real client with
# "Failed to load mods: File __base__/graphics/... not found".
# That is exactly how __base__/graphics/technology/military-3.png shipped.
#
# Two checks, in order of strength:
#   1. If the game data directory has the file on disk, that is proof.
#   2. If graphics are stripped (headless installs are), fall back to asking
#      whether the base game's own prototypes reference that same path. An
#      invented filename fails this; a real one passes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="${FACTORIO_DATA:-$ROOT/test/.work/engine/factorio/data}"
BASE_PROTOTYPES="$DATA/base/prototypes"

python3 "$ROOT/test/check-local-assets.py"
if [ ! -d "$BASE_PROTOTYPES" ]; then
  echo "Missing isolated Factorio data: $DATA (set FACTORIO_DATA to a test installation)"
  exit 1
fi

fails=0
found=0

while read -r quoted; do
  [ -z "$quoted" ] && continue
  found=$((found + 1))
  path="${quoted%\"}"; path="${path#\"}"
  rel="${path#__base__/}"
  disk="$DATA/base/$rel"

  if [ -f "$disk" ]; then
    echo "OK (on disk)    $path"
  elif grep -rqF "$quoted" "$BASE_PROTOTYPES/"; then
    echo "OK (base uses)  $path"
  else
    echo "MISSING         $path"
    fails=$((fails + 1))
  fi
done < <(grep -rhoE '"__base__/graphics/[a-zA-Z0-9/_-]+\.(png|ogg)"' "$ROOT/prototypes/" | sort -u)

echo "---"
if [ "$found" -eq 0 ]; then
  echo "no __base__ asset paths found - check the grep, this should not be zero"
  exit 1
fi
if [ "$fails" -gt 0 ]; then
  echo "$fails asset path(s) not found"
  exit 1
fi
echo "$found asset path(s) OK"
