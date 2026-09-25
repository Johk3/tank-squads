#!/usr/bin/env bash
# A 0.16.4 save gains service records and names after loading the
# current version.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$ROOT"
WORK="$ROOT/test/.work/veterans-upgrade"
MODS="$WORK/current-mods"
MAP="$WORK/old-map.zip"
rm -rf "$WORK/old-mods"
mkdir -p "$WORK/old-mods/tank-squads" "$MODS" "$WORK/saves"
git archive 9c8f9f5 | tar -x -C "$WORK/old-mods/tank-squads"
ln -sfn "$ROOT" "$MODS/tank-squads"
cat > "$WORK/config.ini" <<EOC
[path]
read-data=__PATH__executable__/../../data
write-data=$WORK
[general]
locale=auto
EOC
"$FACTORIO" --config "$WORK/config.ini" --mod-directory "$WORK/old-mods" --create "$MAP" > "$WORK/create.log" 2>&1
MODS="$WORK/old-mods"
trap stop_server EXIT
start_server
python3 "$ROOT/test/rcon.py" "/silent-command __tank-squads__ local s=game.surfaces[1] local q=s.find_non_colliding_position('tank-squad-soldier-2',{0,0},100,1) local u=s.create_entity{name='tank-squad-soldier-2',position=q,force='player',raise_built=true} storage.upgrade_probe={unit=u.unit_number} game.server_save('upgrade-source')"
for _ in $(seq 1 30); do
  [ -f "$WORK/saves/upgrade-source.zip" ] && break
  sleep 0.1
done
[ -f "$WORK/saves/upgrade-source.zip" ]
stop_server
MAP="$WORK/saves/upgrade-source.zip"
MODS="$WORK/current-mods"
start_server
sleep 2
RESULT=$(python3 "$ROOT/test/rcon.py" "/silent-command __tank-squads__ local ok,err=pcall(function() local id=storage.upgrade_probe.unit local u=assert(game.get_entity_by_unit_number(id),'carrier missing') local r=assert(storage.veterans and storage.veterans[id],'no service record') assert(r.adjective and r.noun and r.rank==0 and r.xp==0 and r.kills==0,'record not a recruit') end) rcon.print(ok and 'PASS: 0.16.4 soldier enlisted with a name' or ('FAIL: '..tostring(err)))")
printf "%s\n" "$RESULT"
[[ "$RESULT" == PASS:* ]]
