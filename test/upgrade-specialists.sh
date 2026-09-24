#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$ROOT"
WORK="$ROOT/test/.work/specialist-upgrade"
MODS="$WORK/current-mods"
MAP="$WORK/old-map.zip"
mkdir -p "$WORK/old-mods/tank-squads" "$MODS" "$WORK/saves"
git archive ddf7199 | tar -x -C "$WORK/old-mods/tank-squads"
ln -sfn "$ROOT" "$MODS/tank-squads"
cat > "$WORK/config.ini" <<EOF
[path]
read-data=__PATH__executable__/../../data
write-data=$WORK
[general]
locale=auto
EOF
"$FACTORIO" --config "$WORK/config.ini" --mod-directory "$WORK/old-mods" --create "$MAP" > "$WORK/create.log" 2>&1
MODS="$WORK/old-mods"
trap stop_server EXIT
start_server
python3 "$ROOT/test/rcon.py" "/silent-command __tank-squads__ game.forces.player.technologies['tank-squad-unlock'].researched=true local s=game.surfaces[1] local p=s.find_non_colliding_position('tank-squad-barracks',{0,0},100,1) local b=s.create_entity{name='tank-squad-barracks',position=p,force='player',raise_built=true} b.set_recipe('tank-squad-train-1') b.insert{name='steel-plate',count=13} local q=s.find_non_colliding_position('tank-squad-soldier-2',{p.x+5,p.y},100,1) local u=s.create_entity{name='tank-squad-soldier-2',position=q,force='player',raise_built=true} u.health=321 storage.upgrade_probe={unit=u.unit_number,barracks=b.unit_number} rcon.print(script.active_mods['tank-squads']) game.server_save('upgrade-source')"
for _ in $(seq 1 30); do
  [ -f "$WORK/saves/upgrade-source.zip" ] && break
  sleep 0.1
done
[ -f "$WORK/saves/upgrade-source.zip" ]
stop_server
MAP="$WORK/saves/upgrade-source.zip"
MODS="$WORK/current-mods"
start_server
RESULT=$(python3 "$ROOT/test/rcon.py" "/silent-command __tank-squads__ local ok,err=pcall(function() assert(script.active_mods['tank-squads']=='0.13.1','not upgraded') local f=game.forces.player assert(f.recipes['tank-squad-train-siege'].enabled and f.recipes['tank-squad-train-flame'].enabled,'specialists still locked') local u=assert(game.get_entity_by_unit_number(storage.upgrade_probe.unit),'carrier missing') assert(u.name=='tank-squad-soldier-2' and u.health>=321,'carrier lost') assert(storage.weapons[u.unit_number].gun.valid,'old carrier lost overlay') local b for _,e in pairs(game.surfaces[1].find_entities_filtered{name='tank-squad-barracks'}) do if e.unit_number==storage.upgrade_probe.barracks then b=e end end assert(b,'barracks lost') assert(b.get_item_count('steel-plate')==13,'inventory lost') assert(b.get_recipe().name=='tank-squad-train-1','recipe lost') end) rcon.print(ok and 'PASS: 0.8.1 researched save upgraded; specialist recipes unlocked; carrier, gun, barracks inventory and recipe preserved' or ('FAIL: '..tostring(err)))")
printf "%s\n" "$RESULT"
[[ "$RESULT" == PASS:* ]]
