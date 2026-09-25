#!/usr/bin/env bash
# A 0.17.0 save with one target shared by two linked barracks gives each
# barracks its share after loading the current version. The save is paused,
# so no sweep releases the links of the missing player before the check.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$ROOT"
WORK="$ROOT/test/.work/reinforcements-upgrade"
MODS="$WORK/current-mods"
MAP="$WORK/old-map.zip"
rm -rf "$WORK/old-mods" "$WORK/saves"
mkdir -p "$WORK/old-mods/tank-squads" "$MODS" "$WORK/saves"
git archive eb31ae6 | tar -x -C "$WORK/old-mods/tank-squads"
# The game upgrades a save only when the mod version changes.
sed -i 's/"version": "0.17.0"/"version": "0.16.99"/' "$WORK/old-mods/tank-squads/info.json"
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
python3 "$ROOT/test/rcon.py" "/silent-command __tank-squads__ local s=game.surfaces[1] local a=s.create_entity{name='tank-squad-barracks',position={-20,0},force='player',raise_built=true} local b=s.create_entity{name='tank-squad-barracks',position={20,0},force='player',raise_built=true} for _,r in ipairs(storage.barracks) do r.reinforcement={player_index=1,division=2} end storage.divisions={[1]={selected=0,slots={[2]={members={},mode='idle',render={rings={},route={}},reinforcement_sources={[a.unit_number]=true,[b.unit_number]=true},reinforcement_surface_index=1,reinforcement_target=5}}}} storage.upgrade_probe={a=a.unit_number,b=b.unit_number} game.tick_paused=true game.server_save('upgrade-source')"
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
RESULT=$(python3 "$ROOT/test/rcon.py" "/silent-command __tank-squads__ local ok,err=pcall(function() local p=storage.upgrade_probe local r=storage.divisions[1].slots[2] assert(r.reinforcement_target==nil,'shared target kept') local a,b=r.reinforcement_sources[p.a],r.reinforcement_sources[p.b] assert(type(a)=='table' and type(b)=='table','sources not converted') assert(a.target+b.target==5 and a.target==3,'target not split: '..a.target..'+'..b.target) end) rcon.print(ok and 'PASS: 0.17.0 shared target split between two barracks' or ('FAIL: '..tostring(err)))")
printf "%s\n" "$RESULT"
[[ "$RESULT" == PASS:* ]]
