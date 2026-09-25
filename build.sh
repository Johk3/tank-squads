#!/usr/bin/env bash
# Package the mod for the portal. Output: dist/tank-squads_<version>.zip
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(python3 -c "import json;print(json.load(open('$ROOT/info.json'))['version'])")"
OUT="$ROOT/dist/tank-squads_$VERSION.zip"
TMP_OUT="$OUT.tmp"
STAGE="$(mktemp -d)"
DEST="$STAGE/tank-squads_$VERSION"
mkdir -p "$DEST" "$ROOT/dist"
# thumbnail.png is the mod portal's and in-game mod list's picture.
for f in info.json thumbnail.png data.lua settings.lua control.lua changelog.txt README.md LICENSE prototypes scripts locale graphics; do
  cp -r "$ROOT/$f" "$DEST/"
done
# Local development notes stay out of the release.
rm -f "$DEST/graphics/README.md"

# This host has no `zip` binary, so build the archive with python3's zipfile
# module (already used by this script's own self-check below and by
# test/rcon.py). Build into a temp path and only replace $OUT with `mv` once
# the build and self-check both succeed: the previous version of this script
# ran `rm -f "$OUT"` before invoking `zip`, so a failed `zip` call deleted
# any previously published release zip and left nothing in its place.
rm -f "$TMP_OUT"
python3 -c "
import os
import zipfile

stage = '$STAGE'
tmp_out = '$TMP_OUT'
with zipfile.ZipFile(tmp_out, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk(stage):
        dirs.sort()
        for name in sorted(files):
            path = os.path.join(root, name)
            arcname = os.path.relpath(path, stage)
            z.write(path, arcname)
"
rm -rf "$STAGE"

python3 -c "
import zipfile
z = zipfile.ZipFile('$TMP_OUT')
tops = {n.split('/')[0] for n in z.namelist()}
assert tops == {'tank-squads_$VERSION'}, tops
assert any(n.endswith('info.json') for n in z.namelist())
assert 'tank-squads_$VERSION/thumbnail.png' in z.namelist(), 'thumbnail.png missing'
print('package ok')
"

mv -f "$TMP_OUT" "$OUT"
echo "$OUT"
