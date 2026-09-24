# Tank Squads

**Train an army of tanks at a barracks and command it RTS-style.** Drag to select, bind divisions to number keys, send them to attack, patrol, scout the map or guard a teammate. Every soldier is a native engine unit, so pathfinding and combat run in the game engine. The mod adds no per-tick scripting, even with hundreds of tanks on the map.

Requires Factorio 2.0.56 or newer. No other mods needed.

---

## Features

- **Three kinds of tanks.** Fast chaingun carriers in three ammunition tiers, a long-range siege tank with an oversized cannon, and a heavily armored flame tank.
- **Mobile headquarters.** A huge, slow, unarmed command vehicle. It heals nearby soldiers, and wherever it parks it sets up camp with a far-reaching roboport, a long-range radar and solar decks that power a nearby grid.
- **Barracks.** A 3x3 military bunker that trains soldiers like an assembler trains items. It needs no power, heals nearby soldiers, and plays a door animation when a new tank rolls out.
- **RTS controls.** Drag-select with the command tool, alt-drag to move or attack, and use **Ctrl + 1–9** / **Alt + 1–9** to assign and recall up to nine divisions.
- **Patrol routes.** Draw a waypoint loop for a division. It spreads out over the area the route encloses instead of walking it in single file.
- **Scout mode.** A division splits into up to four teams that each explore their own direction. Flame tanks lead, carriers follow and siege tanks cover them from 30 tiles back. Teams keep pushing outward until water or cliffs stop them.
- **Escorts.** Assign a division to any player on your team, as a **defensive** ring around them or an **offensive** roaming band that clears everything it finds.
- **Nest assaults.** Mixed offensive divisions attack biter nests in stages. Siege tanks shell the worms from out of range, flame tanks push in, and carriers follow.
- **Healing retreat.** Badly damaged escort and scout soldiers drive back to the nearest barracks in guarded convoys, heal, and return to their post. A scout team that takes too much damage pulls back together.
- **Automatic reinforcements.** Link a barracks to a division and set a target strength. It replaces losses automatically and pauses when the division is full.
- **Map vision.** Soldiers keep the map live around themselves, so you can watch fights from the map view without radars.
- **Multiplayer ready.** Selections, divisions, route overlays and labels are private to each player. Everything is per force.

---

## Getting started

1. Research **Tank Squads** (military science).
2. Build a **Barracks** and a **Rally Flag** near it.
3. Choose a training recipe in the barracks and supply steel plate, iron gear wheels and ammunition. New soldiers drive out and guard the nearest rally flag.
4. Take the **command tool** from the shortcut bar and start giving orders.

---

## Units

| Unit | HP | Range | Speed | Training cost | Time |
|---|---:|---:|---:|---|---:|
| Chaingun Carrier Mk1 | 400 | 20 | fast | 15 steel, 20 gears, 10 firearm magazines | 10 s |
| Chaingun Carrier Mk2 | 500 | 20 | fast | 15 steel, 20 gears, 10 piercing magazines | 10 s |
| Chaingun Carrier Mk3 | 600 | 20 | fast | 15 steel, 20 gears, 10 uranium magazines | 10 s |
| Siege Tank | 900 | 52 | slow | 40 steel, 30 gears, 10 cannon shells | 30 s |
| Flame Tank | 2,400 | 10 | slowest | 60 steel, 40 gears, 10 flamethrower ammo | 30 s |

- The ammunition is used up during training. Soldiers never run out of ammo in the field.
- Your normal weapon research applies: bullet damage for carriers, cannon research for siege tanks, and flamethrower research for flame tanks.
- The siege tank outranges every worm, including behemoths.
- The flame tank has 90% fire resistance, and its flames leave no fires on the ground.

### Mobile headquarters

Research **Mobile headquarters** (automation to utility science), then choose **Build Mobile Headquarters** in a barracks. It costs 2,000 steel, 500 gears, 200 electric engines, 200 processing units, 200 solar panels, 200 accumulators, 20 roboports and 20 radars, and takes 10 minutes.

- **Body:** about 9 by 14 tiles, 400 HP, one-sixth of a carrier's speed. It has no weapon and never fights back, so escort it.
- **Healing:** 20 HP per second to every soldier within 24 tiles, also while it drives.
- **Camp:** when it parks, it sets up a roboport with 25 times the normal reach (625-tile logistics, 1,375-tile construction), a radar that keeps 8 chunks around it live and scans out to 32, 12 MW of solar decks and a 1 GJ battery. The camp stays where it was while the headquarters drives, and moves to it when it parks again.
- **Power:** a camp within 12 tiles of one of your electric poles wires itself to that pole, so the grid shares its solar power and battery. It never links two grids.
- **Robots:** open the headquarters to put construction and logistic robots and repair packs into its roboport. Robots build from your logistic network like any roboport's. If the headquarters is destroyed, its docked robots and repair packs drop on the ground.
- **Orders:** select it with the command tool and move it or give it a patrol route like any soldier. An attack order moves it to the area. Scouting and escort formations leave it where it is.

---

## Controls

| Action | How |
|---|---|
| Select soldiers | Drag with the command tool |
| Move | Alt-drag over empty ground |
| Attack an area | Alt-drag over enemies |
| Assign selection to a division | Ctrl + 1–9 |
| Select a division | Alt + 1–9, or click its row in the division panel |
| Patrol | Toggle patrol mode on the shortcut bar, then alt-drag to place waypoints |
| Scout | Select a division and toggle scout mode on the shortcut bar |
| Escort | Select a numbered division, press the escort shortcut, then pick a player and a formation |
| Reinforce | Open a barracks and use the **Automatic reinforcements** panel |

All keys can be rebound in the controls menu. Each soldier belongs to one division at a time.

---

## Escorts in detail

- **Defensive:** the division holds an evenly spaced ring 160 tiles from the player. When enemies come within 224 tiles of the player or of the ring's centre, the nearest half of the division intercepts them and the rest hold the ring.
- **Offensive:** the division roams 256–448 tiles from the player and attacks the nearest biters, nests, worms, turrets or enemy players.
- The escort only relocates once the player has stopped and moved more than 64 tiles, so it never chases a train.
- Soldiers below 35% health retreat to a barracks within 1,000 tiles and come back at 95%.
- The escorted player can dismiss the escort at any time.

---

## Scouting in detail

- **Teams:** one team per three soldiers, at most four. A bigger division makes bigger teams. Each kind of tank is spread evenly, and every team gets at least one flame tank or carrier to screen its siege tanks.
- **Directions:** the teams split the compass from where scouting started, so each explores its own slice. Inside its slice a team always heads for the nearest uncharted chunk.
- **Formation:** flame tanks at the front, carriers in a V behind them, and siege tanks 30 tiles back, where their cannons still reach past the front. Teams move in 32-tile hops and wait for every tank before the next hop.
- **Healing:** a tank below 35% health drives to a barracks within 1,000 tiles and comes back at 95%, with guards in teams of more than 10. A team below half its total health, or down to half its tanks, drives back together and returns when every tank is healed.
- **Far out:** when everything nearby is charted, a team marches straight outward until it finds fog again. A team blocked by water or cliffs, or left with only siege tanks, joins the nearest team. Scouting stops only when every direction is blocked.

---

## Mod settings

All of these are map settings and can be changed during a game (*Settings → Mod settings → Map*):

- Defensive ring radius and threat radius
- Offensive band inner and outer edge
- Escort follow distance
- Retreat health, rejoin health, and barracks search range
- **Soldiers reveal the map** (turn this off to save the charting work on very large armies)

---

## Performance

Tank Squads soldiers are native `unit` entities, the same type as biters. Movement, pathfinding, targeting and damage run in the engine's C++. The mod's scripts only react to events and run one light sweep per second, spread across ten slices. There is no `on_tick` handler.

In testing, 200 carriers in constant combat cost about **0.01 ms per tick** of script time.

A mobile headquarters' camp moves only when it parks, because the engine takes a few milliseconds to move a roboport with such a large reach. Its once-a-second sweep is otherwise light.

---

## Compatibility

- Works in single player and multiplayer, and can be added to existing saves.
- Soldiers from *AAI Programmable Vehicles* are separate entities and are not converted.
- Space Age is not required.

---

## License

Copyright (C) 2026 johk. Licensed under the [GNU General Public License v3.0](https://github.com/johk3/tank-squads/blob/master/LICENSE): you may share and modify this mod, as long as your version stays under the same license.

---

## Development

Build a release zip for the mod portal:

```sh
./build.sh          # writes dist/tank-squads_<version>.zip
```

Run the tests:

```sh
python3 test/unit.py               # server-free regressions (needs Python and lupa)
python3 test/check-local-assets.py # bundled artwork checks
./test/run.sh                      # engine suite
```

The engine suite runs a separate, disposable Factorio installation under `test/.work/engine/factorio/` on ports 34198 and 27016. Set `FACTORIO` and `FACTORIO_DATA` to use another test installation. It refuses ports that are already in use and only stops the process it started.
