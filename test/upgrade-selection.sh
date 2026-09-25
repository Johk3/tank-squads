#!/usr/bin/env bash
# A 0.18.0 save whose drag selection runs a patrol loads with the patrol
# taken off the selection and no selection entries in the ownership index.
# A headless server has no player, so this covers the upgrade without a
# division to promote into; test/selection.lua covers promotion.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$ROOT"
WORK="$ROOT/test/.work/selection-upgrade"
MODS="$WORK/current-mods"
MAP="$WORK/old-map.zip"
rm -rf "$WORK/old-mods" "$WORK/saves"
mkdir -p "$WORK/old-mods/tank-squads" "$MODS" "$WORK/saves"
git archive a7a96ce | tar -x -C "$WORK/old-mods/tank-squads"
# The game upgrades a save only when the mod version changes.
sed -i 's/"version": "0.18.0"/"version": "0.17.99"/' "$WORK/old-mods/tank-squads/info.json"
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
python3 "$ROOT/test/rcon.py" "/silent-command __tank-squads__ local s=game.surfaces[1] local a=s.create_entity{name='tank-squad-soldier-1',position={0,10},force='player',raise_built=true} local b=s.create_entity{name='tank-squad-soldier-1',position={3,10},force='player',raise_built=true} storage.divisions={[1]={selected=0,slots={[0]={members={a.unit_number,b.unit_number},mode='patrol',patrol={waypoints={{x=10,y=0},{x=20,y=0}},surface_index=1},render={rings={},route={}}}}}} storage.unit_divisions={[a.unit_number]={player_index=1,division=0},[b.unit_number]={player_index=1,division=0}} game.tick_paused=true game.server_save('upgrade-source')"
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
RESULT=$(python3 "$ROOT/test/rcon.py" "/silent-command __tank-squads__ local ok,err=pcall(function() local slot=storage.divisions[1] and storage.divisions[1].slots[0] assert(not (slot and slot.patrol),'the selection kept its patrol') assert(not (slot and slot.mode=='patrol'),'the selection is still patrolling') for id,owner in pairs(storage.unit_divisions or {}) do assert(owner.division~=0,'selection still owns '..id) end end) rcon.print(ok and 'PASS: 0.18.0 selection patrol removed and selection unindexed' or ('FAIL: '..tostring(err)))")
printf "%s\n" "$RESULT"
[[ "$RESULT" == PASS:* ]]
