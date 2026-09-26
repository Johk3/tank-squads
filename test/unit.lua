local divisions = require("scripts.divisions")
local patrol = require("scripts.patrol")
local scout = require("scripts.scout")
local commands = require("scripts.commands")
local barracks = require("scripts.barracks")
local names = require("scripts.names")
local entities, players, draws, surface, handlers, charted_lookup, event_filters
local passed, failed = 0, 0

local function gui_element(args)
  local element = {valid = true, style = {}, children = {}}
  for key, value in pairs(args or {}) do element[key] = value end
  -- A style given by name reads back as a style object, as in the game.
  if type(element.style) ~= "table" then element.style = {name = element.style} end
  element.add = function(spec)
    local child = gui_element(spec)
    element.children[#element.children + 1] = child
    if spec.name then element[spec.name] = child end
    return child
  end
  element.destroy = function() element.valid = false end
  return element
end

local function reset()
  storage = {}
  entities, players, draws, handlers = {}, {}, {}, {}
  defines = {behavior_result = {success = 0, fail = 1}, inventory = {chest = 1}, command = {go_to_location = 1, attack_area = 2}, distraction = {by_enemy = 1}, events = {}}
  local events = {"on_built_entity", "on_robot_built_entity", "script_raised_built", "script_raised_revive", "on_entity_cloned", "on_entity_died", "on_ai_command_completed", "on_player_selected_area", "on_player_alt_selected_area", "on_lua_shortcut", "on_player_removed", "on_player_changed_force", "on_gui_click", "on_script_trigger_effect", "script_raised_destroy", "on_entity_spawned", "on_entity_damaged", "on_gui_opened", "on_gui_closed", "on_runtime_mod_setting_changed", "on_pre_player_mined_item", "on_robot_pre_mined", "on_selected_entity_changed"}
  for _, event in ipairs(events) do defines.events[event] = event end
  surface = {index = 1}
  surface.find_nearest_enemy = function() return nil end
  -- Dry land everywhere; a test marks water with surface.wet(x, y).
  surface.is_chunk_generated = function() return true end
  surface.request_to_generate_chunks = function() end
  surface.get_tile = function(x, y)
    return {collides_with = function(layer) return layer == "water_tile" and surface.wet ~= nil and surface.wet(x, y) end}
  end
  surface.find_entities_filtered = function(query)
    local found = {}
    for _, e in ipairs(entities) do
      local match = not query.name or e.name == query.name
      if type(query.name) == "table" then
        match = false
        for _, name in ipairs(query.name) do if e.name == name then match = true end end
      end
      if query.force and e.force ~= query.force then match = false end
      if query.radius then
        local dx, dy = e.position.x - query.position.x, e.position.y - query.position.y
        if dx * dx + dy * dy > query.radius * query.radius then match = false end
      end
      if query.area then
        local a, b = query.area[1], query.area[2]
        if a and (e.position.x < a[1] or e.position.x > b[1] or e.position.y < a[2] or e.position.y > b[2]) then match = false end
      end
      if match and e.valid and e.surface == surface then found[#found + 1] = e end
    end
    return found
  end
  -- Counts through whichever find_entities_filtered the test installed.
  surface.count_entities_filtered = function(query)
    local found = #surface.find_entities_filtered(query)
    return query.limit and math.min(found, query.limit) or found
  end
  local charted = {}
  local force = {
    index = 1,
    technologies = {},
    chart = function(_, area)
      local a, b = area[1] or area.left_top, area[2] or area.right_bottom
      for cx = math.floor(a.x / 32), math.floor(b.x / 32) do
        for cy = math.floor(a.y / 32), math.floor(b.y / 32) do
          charted[cx .. ":" .. cy] = true
        end
      end
    end,
    is_chunk_charted = function(_, chunk) return charted[chunk.x .. ":" .. chunk.y] == true end,
  }
  players[1] = {index = 1, force = force, surface = surface, gui = {left = gui_element(), relative = gui_element(), screen = gui_element()}}
  players[1].set_shortcut_toggled = function(_, value) players[1].shortcut_toggled = value end
  players[1].force_index = 1
  players[1].flying = {}
  players[1].create_local_flying_text = function(args) players[1].flying[#players[1].flying + 1] = args end
  force.connected_players = {players[1]}
  force.get_ammo_damage_modifier = function() return 0 end
  charted_lookup = charted
  -- A single connected player, like a real solo test session.
  game = {tick = 0, surfaces = {surface}, forces = {force}, players = players, connected_players = {players[1]},
    get_player = function(index) return players[index] end,
    get_entity_by_unit_number = function(id) return entities[id] end}
  -- Map settings at their defaults; tests override single values.
  settings = {global = {}}
  for _, d in ipairs(require("scripts.config").DEFINITIONS) do settings.global[d.name] = {value = d.default} end
  settings.global[require("scripts.config").VISION] = {value = true}
  local function draw(args)
    local obj = {valid = true, args = args}
    obj.destroy = function() obj.valid = false end
    draws[#draws + 1] = obj
    return obj
  end
  rendering = {draw_circle = draw, draw_animation = draw, draw_line = draw, draw_text = draw, draw_sprite = draw}
  event_filters = {}
  script = {on_event = function(event, handler, filters) handlers[event] = handler; event_filters[event] = filters end,
    on_nth_tick = function(period, handler) handlers.nth_tick = {period = period, handler = handler} end, on_init = function() end,
    on_configuration_changed = function(handler) handlers.configuration_changed = handler end}
  remote = {add_interface = function() end}
end

local function soldier(force, other_surface, x, y)
  local e_surface = other_surface or surface
  local e = {valid = true, name = names.soldier_names[1], unit_number = #entities + 1,
    force = force == "enemy" and "enemy" or (type(force) == "table" and force or players[1].force), surface = e_surface,
    -- LuaEntity.surface_index mirrors e.surface.index (real Factorio exposes
    -- both); escort.lua's hot paths read the cheaper direct field.
    surface_index = e_surface.index,
    position = {x = x or 0, y = y or 0}, health = 400, max_health = 400, commandable = {},
    speed = 0.12, prototype = {speed = 0.12}}
  setmetatable(e, {__index = function(t, key)
    if key == "force_object" then error("LuaEntity does not contain key force_object") end
    -- LuaEntity.force_index follows the entity's current force, so tests
    -- that reassign e.force change it too.
    if key == "force_index" then
      local f = rawget(t, "force")
      return type(f) == "table" and (f.index or f) or f
    end
  end})
  e.commandable.set_command = function(command) e.command = command end
  e.damaged = {}
  e.damage = function(amount, force, kind, source, cause)
    e.damaged[#e.damaged + 1] = {amount = amount, force = force, type = kind, source = source, cause = cause}
  end
  entities[e.unit_number] = e
  return e
end

-- Counts reads of one field, which stands in for a Factorio API property
-- read. Returns a table whose n grows with every read.
local function count_reads(object, key)
  local value, reads = rawget(object, key), {n = 0}
  object[key] = nil
  local mt = getmetatable(object)
  local old = mt and mt.__index
  setmetatable(object, {__index = function(t, k)
    if k == key then reads.n = reads.n + 1; return value end
    if type(old) == "function" then return old(t, k) end
    return old and old[k]
  end})
  return reads
end

local function building()
  local b = soldier()
  b.name = names.barracks
  b.active = true
  local output = {}
  local inv = {
    get_item_count = function(name) return output[name] or 0 end,
    remove = function(stack)
      local have = output[stack.name] or 0
      local taken = math.min(have, stack.count)
      output[stack.name] = have - taken
      return taken
    end,
  }
  b.get_output_inventory = function() return inv end
  b.get_recipe = function() return nil end
  surface.find_non_colliding_position = function() return {x = 0, y = 3} end
  surface.create_entity = function(args) local s = soldier(); s.name = args.name; return s end
  barracks.register(b)
  return b, output
end

local function test(name, run)
  reset()
  local ok, err = pcall(run)
  if ok then passed = passed + 1; print("PASS " .. name)
  else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end

test("area selection fills slot 0 with private rings and replaces them", function()
  local a, b = soldier(), soldier()
  divisions.select_area(1, {a})
  assert(#draws == 1, "no selection ring")
  local ring = draws[1]
  assert(ring.args.players[1] == 1 and #ring.args.players == 1, "ring leaks to other players")
  assert(not ring.args.time_to_live or ring.args.time_to_live == 0, "ring expires")
  assert(divisions.selected(1) == 0, "area selection did not select slot 0")
  divisions.select_area(1, {b})
  assert(not ring.valid and draws[2].valid, "reselection leaves old ring")
end)

test("selection excludes foreign forces and revalidates ownership", function()
  local own, foreign = soldier(), soldier("enemy")
  assert(divisions.select_area(1, {own, foreign}) == 1, "foreign soldier selected")
  own.force = "enemy"
  assert(divisions.size(1, 0) == 0, "changed force still controllable")
  assert(not draws[1].valid, "changed force still highlighted")
end)

test("assignment is exclusive and coloured per division", function()
  local a = soldier()
  divisions.select_area(1, {a})
  divisions.assign(1, 1, {a})
  assert(divisions.size(1, 1) == 1 and divisions.size(1, 0) == 0, "assignment did not move the soldier out of slot 0")
  divisions.assign(1, 3, {a})
  assert(divisions.size(1, 1) == 0, "soldier stayed in division 1")
  assert(divisions.size(1, 3) == 1, "soldier did not join division 3")
  local ring = draws[#draws]
  local expected = require("scripts.render").COLORS[3]
  assert(ring.args.color.r == expected.r and ring.args.color.g == expected.g, "division 3 does not use its own colour")
end)

test("recall selects a division and redraws only its rings", function()
  local a, b = soldier(), soldier()
  divisions.assign(1, 1, {a})
  divisions.assign(1, 2, {b})
  assert(divisions.recall(1, 1) == 1, "recall returned the wrong size")
  assert(divisions.selected(1) == 1, "recall did not select division 1")
  assert(divisions.size(1, 2) == 1, "recall disturbed another division")
end)

test("assigning an empty selection clears the division", function()
  local a = soldier()
  divisions.assign(1, 4, {a})
  assert(divisions.assign(1, 4, {}) == 0, "empty assignment reported members")
  assert(divisions.size(1, 4) == 0, "division not cleared")
  assert(not draws[1].valid, "cleared division kept its rings")
end)

test("move replaces the selected division's patrol instead of resuming it", function()
  local a = soldier()
  divisions.assign(1, 1, {a})
  patrol.add_waypoint(1, 1, {x = 20, y = 20}, surface)
  patrol.start(1, 1)
  commands.order(1, {left_top = {x = 30, y = 30}, right_bottom = {x = 32, y = 32}}, surface)
  patrol.advance(a.unit_number)
  assert(patrol.index(1, 1, a.unit_number) == nil and a.command.destination.x == 31, "old patrol overrides move")
end)

test("patrol refuses waypoints on another surface", function()
  divisions.assign(1, 1, {soldier()})
  assert(patrol.add_waypoint(1, 1, {x = 10, y = 10}, surface) == 1)
  assert(patrol.add_waypoint(1, 1, {x = 20, y = 20}, {index = 2}) == nil, "mixed-surface waypoint accepted")
  assert(#divisions.record(1, 1).patrol.waypoints == 1)
end)

test("patrol commands only soldiers on its surface", function()
  local a, b = soldier(), soldier("player", {index = 2})
  divisions.assign(1, 1, {a, b})
  patrol.add_waypoint(1, 1, {x = 10, y = 10}, surface)
  patrol.start(1, 1)
  assert(a.command and not b.command, "cross-surface command issued")
end)

test("two divisions keep separate routes", function()
  local a, b = soldier(), soldier()
  divisions.assign(1, 1, {a})
  divisions.assign(1, 2, {b})
  patrol.add_waypoint(1, 1, {x = 10, y = 0}, surface)
  patrol.add_waypoint(1, 1, {x = 20, y = 0}, surface)
  patrol.add_waypoint(1, 2, {x = 0, y = 50}, surface)
  patrol.start(1, 1)
  patrol.start(1, 2)
  assert(a.command.destination.x == 15 and a.command.destination.y == 0, "division 1 got the wrong leg")
  assert(b.command.destination.y == 50, "division 2 got the wrong leg")
  local other = b.command
  patrol.advance(a.unit_number)
  assert(patrol.index(1, 1, a.unit_number) == 2 and patrol.index(1, 2, b.unit_number) == 0 and b.command == other,
    "advancing one route advanced the other")
end)

-- The engine reports each finished distraction (a fight on the way) as its
-- own completion, then resumes the original command by itself.
test("a finished distraction does not advance the patrol", function()
  dofile("control.lua")
  local a = soldier()
  divisions.assign(1, 1, {a})
  patrol.add_waypoint(1, 1, {x = 10, y = 0}, surface)
  patrol.add_waypoint(1, 1, {x = 20, y = 0}, surface)
  patrol.start(1, 1)
  local success = defines.behavior_result.success
  handlers.on_ai_command_completed{unit_number = a.unit_number, result = success, was_distracted = true}
  assert(patrol.index(1, 1, a.unit_number) == 0, "a fight on the way skipped a waypoint")
  handlers.on_ai_command_completed{unit_number = a.unit_number, result = success, was_distracted = false}
  assert(patrol.index(1, 1, a.unit_number) == 2, "arrival did not advance the patrol")
end)

test("failed patrol legs wait for the sweep and back off when every waypoint fails", function()
  local a = soldier()
  divisions.assign(1, 1, {a})
  patrol.add_waypoint(1, 1, {x = 10, y = 0}, surface)
  patrol.add_waypoint(1, 1, {x = 20, y = 0}, surface)
  patrol.start(1, 1)
  local fail, success = defines.behavior_result.fail, defines.behavior_result.success
  a.command = nil
  patrol.advance(a.unit_number, fail)
  assert(patrol.index(1, 1, a.unit_number) == 2 and a.command == nil, "failed path re-requested in the same tick")
  patrol.tick()
  assert(a.command.destination.x == 20, "next leg not sent on the sweep")
  a.command = nil
  patrol.advance(a.unit_number, fail)
  game.tick = patrol.RETRY_TICKS - 1
  patrol.tick()
  assert(a.command == nil, "fully unreachable route retried before the back-off")
  game.tick = patrol.RETRY_TICKS
  patrol.tick()
  assert(a.command.destination.x == 10, "route did not retry after the back-off")
  patrol.advance(a.unit_number, success)
  patrol.advance(a.unit_number, fail)
  patrol.tick()
  assert(a.command.destination.x == 10, "a success did not reset the failure count")
end)

test("selecting a division draws its route and deselecting removes it", function()
  local a = soldier()
  divisions.assign(1, 1, {a})
  patrol.add_waypoint(1, 1, {x = 10, y = 0}, surface)
  patrol.add_waypoint(1, 1, {x = 20, y = 0}, surface)
  patrol.draw(1, 1)
  local lines = 0
  for _, draw in ipairs(draws) do
    if draw.valid and draw.args.from and draw.args.render_mode ~= "chart" then
      lines = lines + 1
      assert(draw.args.players[1] == 1 and #draw.args.players == 1, "route leaks to other players")
    end
  end
  assert(lines == 2, "expected a closed two-waypoint loop, drew " .. lines .. " lines")
  patrol.clear(1, 1)
  for _, draw in ipairs(draws) do
    assert(not (draw.valid and draw.args.from), "cleared route left a line behind")
  end
end)

test("dead soldiers lose rings without affecting another player's division", function()
  players[2] = {index = 2, force = players[1].force, surface = surface, gui = {left = gui_element(), screen = gui_element()}}
  players[2].set_shortcut_toggled = function() end
  local a, b = soldier(), soldier()
  divisions.assign(1, 1, {a})
  divisions.assign(2, 1, {b})
  divisions.forget(a.unit_number)
  assert(#draws == 2 and not draws[1].valid and draws[2].valid, "ring cleanup is not per soldier")
end)

test("refresh restores expired render objects", function()
  local a = soldier()
  divisions.assign(1, 1, {a})
  draws[1].valid = false
  divisions.refresh()
  assert(draws[2].valid and draws[2].args.radius, "refresh did not recreate the ring")
  a.valid = false
  divisions.refresh()
  assert(not draws[2].valid and divisions.size(1, 1) == 0, "dead member kept its ring")
end)

test("healing uses circular radius and clamps health", function()
  building()
  local corner, near = soldier("player", nil, 11, 11), soldier("player", nil, 11, 0)
  corner.health = 100
  near.health = 395
  barracks.tick()
  assert(corner.health == 100, "healing reaches outside radius")
  assert(near.health == 400, "healing exceeds max health")
end)

test("a finished recruit becomes a soldier of its tier", function()
  local b, output = building()
  output["tank-squad-recruit-2"] = 1
  barracks.tick()
  assert(output["tank-squad-recruit-2"] == 0, "recruit item not consumed")
  local made
  for _, e in pairs(entities) do if e.name == names.soldier_names[2] then made = e end end
  assert(made, "no tier 2 soldier deployed")
  assert(made.command and made.command.destination, "deployed soldier got no rally order")
end)

test("blocked deployment leaves the recruit in the output and consumes nothing", function()
  local b, output = building()
  output["tank-squad-recruit-1"] = 1
  surface.find_non_colliding_position = function() return nil end
  for _ = 1, 5 do barracks.tick() end
  assert(output["tank-squad-recruit-1"] == 1, "blocked deployment consumed the recruit")
  for _, draw in ipairs(draws) do
    assert(draw.args.animation ~= "tank-squad-barracks-deploy", "door opened without a soldier")
  end
  surface.find_non_colliding_position = function() return {x = 0, y = 3} end
  barracks.tick()
  assert(output["tank-squad-recruit-1"] == 0, "recruit not deployed once space freed")
end)

test("deployment animation plays once per soldier and starts closed", function()
  game.tick = 37
  local b, output = building()
  output["tank-squad-recruit-1"] = 1
  barracks.tick()
  local deployment = draws[#draws]
  assert(deployment and deployment.args.animation == "tank-squad-barracks-deploy", "no deployment animation")
  assert(deployment.args.time_to_live == 60, "deployment should play once")
  local frame = (37 * deployment.args.animation_speed + deployment.args.animation_offset) % 4
  assert(math.abs(frame) < 0.000001, "deployment starts halfway through door animation")
end)

test("mining a barracks deploys its finished recruits instead of handing out items", function()
  dofile("control.lua")
  for _, event in ipairs({"on_pre_player_mined_item", "on_robot_pre_mined"}) do
    local b, output = building()
    output["tank-squad-recruit-1"], output["tank-squad-recruit-siege"] = 2, 1
    local before = #entities
    assert(handlers[event], event .. " is not handled")
    handlers[event]{entity = b, player_index = 1}
    assert(output["tank-squad-recruit-1"] == 0 and output["tank-squad-recruit-siege"] == 0,
      event .. " left recruits for the player's inventory")
    assert(#entities - before == 3, event .. " did not deploy every buffered recruit")
  end
end)

test("mining a linked barracks fills its division and sends the rest to the rally point", function()
  dofile("control.lua")
  local member = soldier()
  divisions.assign(1, 4, {member})
  local b, output = building()
  assert(barracks.configure(b, 1, 4, 2))
  output["tank-squad-recruit-1"] = 3
  handlers.on_pre_player_mined_item{entity = b, player_index = 1}
  assert(output["tank-squad-recruit-1"] == 0, "recruits left behind")
  assert(divisions.size(1, 4) == 3, "quota not filled, or overfilled")
  local rallied = 0
  for _, e in pairs(entities) do
    if e ~= member and e.name == names.soldier_names[1] and e.command and not divisions.owner(e.unit_number) then
      rallied = rallied + 1
    end
  end
  assert(rallied == 1, "surplus recruits did not head for the rally point")
end)

test("registering a barracks twice cannot double its production", function()
  local b = building()
  barracks.register(b)
  assert(#storage.barracks == 1, "duplicate producer registered")
end)

test("revived and cloned barracks register through events", function()
  dofile("control.lua")
  assert(handlers.script_raised_revive and handlers.on_entity_cloned, "missing lifecycle events")
  local b = soldier(); b.name = names.barracks
  handlers.script_raised_revive{entity = b}
  local clone = soldier(); clone.name = names.barracks
  handlers.on_entity_cloned{source = b, destination = clone}
  assert(#storage.barracks == 2, "clone or revive missing from production")
end)

test("removed players and force changes clear only their own selection", function()
  dofile("control.lua")
  players[2] = {index = 2, force = players[1].force, surface = surface, gui = {left = gui_element(), screen = gui_element()}}
  divisions.select_area(1, {soldier()})
  divisions.select_area(2, {soldier()})
  assert(divisions.size(1, 0) == 1 and divisions.size(2, 0) == 1, "selection did not take before the clear")
  players[1].shortcut_toggled = true
  storage.patrol_mode = {[1] = true}
  assert(handlers.on_player_changed_force and handlers.on_player_removed)
  handlers.on_player_changed_force{player_index = 1}
  assert(not draws[1].valid and draws[2].valid)
  assert(players[1].shortcut_toggled == false, "patrol shortcut still shows enabled after force change")
  assert(divisions.size(1, 0) == 0, "force change did not clear the player's own selection")
  assert(divisions.size(2, 0) == 1, "force change disturbed another player's selection")
  players[2] = nil
  handlers.on_player_removed{player_index = 2}
  assert(not draws[2].valid)
end)

test("upgrade discovers unregistered barracks", function()
  building()
  local missed = soldier(); missed.name = names.barracks
  dofile("control.lua")
  assert(handlers.configuration_changed, "upgrade does not repair registry")
  handlers.configuration_changed{}
  assert(#storage.barracks == 2, "upgrade lost a producer")
end)

test("barracks prototype is a crafting machine with three training recipes", function()
  local function copy(t)
    if type(t) ~= "table" then return t end
    local out = {}; for k, v in pairs(t) do out[k] = copy(v) end; return out
  end
  package.loaded.util = {table = {deepcopy = copy}}
  data = {raw = {item = {["steel-chest"] = {type = "item", stack_size = 50}}}}
  data.extend = function(_, prototypes)
    for _, prototype in ipairs(prototypes) do
      data.raw[prototype.type] = data.raw[prototype.type] or {}
      data.raw[prototype.type][prototype.name] = prototype
    end
  end
  dofile("prototypes/barracks.lua")
  dofile("prototypes/recipes.lua")

  local machine = data.raw["assembling-machine"][names.barracks]
  assert(machine, "barracks is not an assembling machine")
  assert(machine.tile_width == 3 and machine.tile_height == 3, "barracks footprint is not 3x3")
  assert(machine.energy_source.type == "void", "barracks demands a power network")
  assert(machine.crafting_categories[1] == "tank-squad-training", "wrong crafting category")
  assert(data.raw["recipe-category"]["tank-squad-training"], "recipe category missing")
  assert(machine.graphics_set and machine.graphics_set.animation, "idle graphics missing")
  assert(machine.graphics_set.working_visualisations, "training graphics missing")

  for tier = 1, 3 do
    local recipe = data.raw.recipe["tank-squad-train-" .. tier]
    assert(recipe, "training recipe missing for tier " .. tier)
    assert(recipe.category == "tank-squad-training", "training recipe in wrong category")
    assert(recipe.energy_required == 10, "training no longer takes ten seconds")
    assert(recipe.results[1].name == names.recruit_names[tier], "recipe does not produce its recruit")
    local item = data.raw.item[names.recruit_names[tier]]
    assert(item and item.hidden == true, "recruit item missing or visible in the crafting menu")
    assert(item.stack_size == 1, "recruit item stacks")
  end

  -- A recipe without its own name borrows its product's; one of the two
  -- must be in the locale, or the barracks shows an unknown key.
  local locale, section, keys = io.open("locale/en/tank-squads.cfg"):read("*a"), nil, {}
  for line in locale:gmatch("[^\n]+") do
    local header = line:match("^%[(.+)%]$")
    if header then section = header; keys[section] = keys[section] or {}
    elseif section then
      local key = line:match("^([^=]+)=")
      if key then keys[section][key] = true end
    end
  end
  for name, recipe in pairs(data.raw.recipe) do
    local product = recipe.results and recipe.results[1] and recipe.results[1].name
    assert(keys["recipe-name"][name] or (product and keys["item-name"][product]),
      "recipe " .. name .. " has no locale name")
  end
end)

test("division keybindings assign and recall through control.lua", function()
  dofile("control.lua")
  local a, b = soldier(), soldier()
  divisions.select_area(1, {a, b})
  assert(handlers["tank-squad-assign-division-2"], "assign keybinding not wired")
  handlers["tank-squad-assign-division-2"]{player_index = 1}
  assert(divisions.size(1, 2) == 2, "assignment did not take")
  assert(divisions.selected(1) == 2, "assignment did not select the division")
  divisions.select_area(1, {})
  assert(handlers["tank-squad-select-division-2"], "recall keybinding not wired")
  handlers["tank-squad-select-division-2"]{player_index = 1}
  assert(divisions.selected(1) == 2 and divisions.size(1, 2) == 2, "recall did not restore the division")
end)

test("scout mode charts around the division and heads for an uncharted chunk", function()
  local a = soldier()
  divisions.assign(1, 1, {a})
  assert(scout.set(1, 1, true) == true, "scout mode did not switch on")
  scout.tick()
  assert(charted_lookup["0:0"], "scout did not chart its own chunk")
  assert(a.command and a.command.type == defines.command.go_to_location, "scout got no leg order")
  local target = a.command.destination
  assert(math.abs(target.x) > 16 or math.abs(target.y) > 16, "scout targeted the chunk it stands in")
end)

test("scout mode replaces a patrol route and patrol replaces scout mode", function()
  local a = soldier()
  divisions.assign(1, 1, {a})
  patrol.add_waypoint(1, 1, {x = 10, y = 0}, surface)
  patrol.start(1, 1)
  scout.set(1, 1, true)
  assert(divisions.record(1, 1).patrol == nil, "scout mode kept the patrol route")
  patrol.add_waypoint(1, 1, {x = 10, y = 0}, surface)
  patrol.start(1, 1)
  assert(divisions.record(1, 1).mode == "patrol", "patrol did not take over from scouting")
  assert(divisions.record(1, 1).scout == nil, "scout state survived a patrol order")
end)

test("scout chunk search is bounded per sweep and resumes where it stopped", function()
  local a = soldier()
  divisions.assign(1, 1, {a})
  for cx = -20, 20 do for cy = -20, 20 do charted_lookup[cx .. ":" .. cy] = true end end
  scout.set(1, 1, true)
  local seen = {}
  local real = players[1].force.is_chunk_charted
  players[1].force.is_chunk_charted = function(s, chunk)
    local key = chunk.x .. ":" .. chunk.y
    assert(not seen[key], "scout re-tested chunk " .. key .. " instead of resuming past it")
    seen[key] = true
    return real(s, chunk)
  end
  scout.tick()
  local tested1 = 0
  for _ in pairs(seen) do tested1 = tested1 + 1 end
  assert(tested1 <= scout.CHUNK_BUDGET, "scout tested " .. tested1 .. " chunks in one sweep")
  local state = divisions.record(1, 1).scout.teams[1]
  assert(state and state.ring and state.ring > 1, "scout did not record where it stopped")
  assert(state.offset ~= nil, "scout did not record an offset to resume from")
  local ring1, offset1 = state.ring, state.offset
  scout.tick()
  local tested2 = 0
  for _ in pairs(seen) do tested2 = tested2 + 1 end
  assert(tested2 > tested1, "a second sweep made no forward progress")
  local state2 = divisions.record(1, 1).scout.teams[1]
  assert(state2.ring > ring1 or (state2.ring == ring1 and state2.offset > offset1),
    "scout did not resume past the ring and offset it stopped at")
end)

test("a scouting division with no living members goes idle", function()
  local a = soldier()
  divisions.assign(1, 1, {a})
  scout.set(1, 1, true)
  a.valid = false
  scout.tick()
  assert(divisions.record(1, 1).mode == "idle", "empty division kept scouting")
end)

test("an attack order asks the engine for one enemy, not every entity in the area", function()
  local a = soldier()
  divisions.assign(1, 1, {a})
  for i = 1, 50 do soldier("enemy", nil, 20 + i % 3, 20) end
  local count, limit = surface.count_entities_filtered, nil
  surface.count_entities_filtered = function(query) limit = query.limit; return count(query) end
  assert(commands.order(1, {left_top = {x = 19, y = 19}, right_bottom = {x = 24, y = 21}}, surface) == "attack")
  assert(a.command.type == defines.command.attack_area, "enemies in the area did not make an attack order")
  assert(limit == 1, "the order fetched every entity in the area to test for one enemy")
end)

test("manual orders cancel scout mode", function()
  local a = soldier()
  divisions.assign(1, 1, {a})
  scout.set(1, 1, true)
  commands.order(1, {left_top = {x = 20, y = 20}, right_bottom = {x = 22, y = 22}}, surface)
  local order = a.command
  scout.tick()
  assert(divisions.record(1, 1).mode == "idle", "manual order kept scout mode")
  assert(a.command == order, "scouting replaced manual order")
end)

test("scouts do not command members on other surfaces", function()
  local a = soldier()
  local b = soldier(nil, {index = 2}, 10000, 10000)
  divisions.assign(1, 1, {a, b})
  scout.set(1, 1, true)
  scout.tick()
  assert(charted_lookup["0:0"], "chart origin mixed surfaces")
  assert(b.command == nil, "scout sent coordinates to another surface")
end)

test("scout completion storms defer charting and orders to the sweep", function()
  local a, b = soldier(), soldier()
  divisions.assign(1, 1, {a, b})
  scout.set(1, 1, true)
  scout.tick()
  local calls = 0
  players[1].force.chart = function() calls = calls + 1 end
  local order = a.command
  for i = 1, 100 do
    scout.on_command_completed(a.unit_number)
    scout.on_command_completed(b.unit_number)
  end
  assert(calls == 0 and a.command == order, "completion events trigger chart work or orders")
  scout.tick()
  assert(calls == 1, "sweep failed to resume scouting")
end)

test("map markers follow one member per surface without redraws", function()
  local a, b = soldier(), soldier()
  divisions.assign(1, 3, {a, b})
  divisions.refresh()
  local labels = {}
  for _, draw in ipairs(draws) do
    if draw.valid and draw.args.render_mode == "chart" and draw.args.target == a and draw.args.text
        and not draw.args.use_rich_text then
      labels[#labels + 1] = draw
      assert(draw.args.text == "3", "map marker lacks division number")
      assert(draw.args.scale_with_zoom == true, "map marker shrinks when zooming out")
      assert(draw.args.players[1] == 1, "map marker not private")
    end
  end
  assert(#labels == 1, "missing single division marker")
  labels[1].scale_with_zoom = false
  labels[1].scale = 1.5
  local count = #draws
  divisions.refresh()
  assert(labels[1].scale_with_zoom == true and labels[1].scale > 1.5, "existing save kept small map marker")
  assert(#draws == count, "unchanged markers recreated")
  a.valid = false
  divisions.refresh()
  assert(not labels[1].valid, "dead leader kept map marker")
  local found = false
  for _, draw in ipairs(draws) do
    if draw.valid and draw.args.render_mode == "chart" and draw.args.target == b and draw.args.text then found = true end
  end
  assert(found, "surviving division lost map marker")
  divisions.clear_player(1)
  for _, draw in ipairs(draws) do assert(not draw.valid, "player cleanup leaked rendering") end
end)

test("patrol paths render on map and disappear after manual orders", function()
  divisions.assign(1, 2, {soldier()})
  patrol.add_waypoint(1, 2, {x = 10, y = 0}, surface)
  patrol.add_waypoint(1, 2, {x = 20, y = 0}, surface)
  local lines = 0
  for _, draw in ipairs(draws) do
    if draw.valid and draw.args.from and draw.args.render_mode == "chart" then lines = lines + 1 end
  end
  assert(lines == 2, "map route missing")
  commands.order(1, {left_top = {x = 30, y = 0}, right_bottom = {x = 32, y = 2}}, surface)
  for _, draw in ipairs(draws) do assert(not (draw.valid and draw.args.from), "cancelled route remains visible") end
end)

test("division panel lists bindings, counts, selection and scout status", function()
  local panel = require("scripts.panel")
  players[1].gui = {left = gui_element(), screen = gui_element()}
  local toggles = {}
  players[1].set_shortcut_toggled = function(name, value) toggles[name] = value end
  divisions.assign(1, 4, {soldier(), soldier()})
  panel.update(1)
  local frame = players[1].gui.screen.tank_squads_divisions
  assert(frame and frame.valid and frame.visible, "division panel missing")
  local button = frame.body.divisions.row_4.division_4
  assert(button.enabled and button.toggled, "assigned division not selectable and highlighted")
  assert(button.caption[2] == 4 and button.caption[3] == 2, "division/count missing")
  assert(button.caption[4][1] == "tank-squads.select-key-4", "binding is hardcoded")
  assert(not frame.body.divisions.row_2.division_2.enabled, "empty division enabled")
  scout.set(1, 4, true)
  panel.update(1)
  assert(toggles["tank-squad-scout-mode"], "scout shortcut not synchronized")
  divisions.recall(1, 2)
  panel.update(1)
  assert(not toggles["tank-squad-scout-mode"], "recall leaves stale scout shortcut")
  divisions.clear_player(1)
  panel.update(1)
  assert(not frame.visible, "empty panel remains visible")
end)

test("division panel short rows hide the title so the window narrows", function()
  local panel = require("scripts.panel")
  players[1].gui = {left = gui_element(), screen = gui_element()}
  players[1].set_shortcut_toggled = function() end
  divisions.assign(1, 3, {soldier()})
  panel.update(1)
  local frame = players[1].gui.screen.tank_squads_divisions
  local bar, row = frame.titlebar, frame.body.divisions.row_3
  assert(bar.title.visible ~= false and frame.body.help.visible ~= false, "full rows lost the title or help")
  panel.click({element = bar.compact, player_index = 1})
  assert(bar.title.visible == false and frame.body.help.visible == false, "short rows keep the wide title")
  assert(row.division_3.style.minimal_width == 0, "short rows keep the full width")
  panel.update(1)
  assert(row.division_3.caption[1] == "tank-squads.division-row-compact", "short caption missing")
  panel.click({element = bar.compact, player_index = 1})
  assert(bar.title.visible == true and row.division_3.style.minimal_width > 0, "full rows not restored")
  -- A window kept from an older version gains the layout on upgrade.
  storage.panel[1].compact = true
  panel.rearrange(1)
  assert(bar.title.visible == false, "upgrade left the wide title on short rows")
end)

test("division panel loads an empty division saved without reinforcement sources", function()
  local panel = require("scripts.panel")
  players[1].gui = {left = gui_element(), screen = gui_element()}
  players[1].set_shortcut_toggled = function() end
  divisions.assign(1, 4, {soldier()})
  divisions.assign(1, 2, {soldier()})
  -- Older versions kept empty records and had no reinforcement_sources field.
  local record = storage.divisions[1].slots[2]
  record.members, record.reinforcement_sources = {}, nil
  assert(divisions.is_reinforced(record) == false, "is_reinforced is not a boolean")
  panel.update(1)
  local button = players[1].gui.screen.tank_squads_divisions.body.divisions.row_2.division_2
  assert(button.enabled == false, "empty legacy division enabled or given nil")
end)

test("division window folds, switches to short rows and keeps its choices", function()
  dofile("control.lua")
  local panel = require("scripts.panel")
  divisions.assign(1, 4, {soldier(), soldier()})
  panel.update(1)
  local frame = players[1].gui.screen.tank_squads_divisions
  assert(frame.titlebar.drag_target == frame and frame.titlebar.drag.drag_target == frame, "window cannot be dragged")
  local button = frame.body.divisions.row_4.division_4
  assert(button.style.minimal_width == 260 and frame.body.help.visible ~= false, "full rows changed")
  handlers.on_gui_click{player_index = 1, element = frame.titlebar.compact}
  assert(frame.body.help.visible == false and button.style.minimal_width == 0, "compact rows kept the help and width")
  assert(button.caption[1] == "tank-squads.division-row-compact" and button.caption[3] == 2, "compact row caption")
  handlers.on_gui_click{player_index = 1, element = frame.titlebar.collapse}
  assert(frame.body.visible == false and frame.visible, "folding hid the whole window or kept the rows")
  assert(frame.titlebar.collapse.sprite == "utility/expand")
  -- Folded, the sweep leaves the rows alone; clicks on a division still work by key.
  divisions.assign(1, 5, {soldier()})
  panel.update(1)
  local row = frame.body.divisions.row_5.division_5
  assert(row.caption[3] == 0 and not row.enabled, "a folded window refreshed its rows")
  handlers.on_gui_click{player_index = 1, element = frame.titlebar.collapse}
  assert(frame.body.visible == true and row.caption[3] == 1 and row.enabled, "unfolding did not refresh the rows")
  handlers.on_gui_click{player_index = 1, element = frame.titlebar.compact}
  assert(frame.body.help.visible == true and button.style.minimal_width == 260)
  assert(button.caption[1] == "tank-squads.division-row-named", "full rows did not come back")
end)

test("a selected headquarters gets a ring wide enough to show round its body", function()
  local tank, hq = soldier(), soldier()
  hq.name = names.headquarters
  divisions.assign(1, 1, {tank, hq})
  local radius = {}
  for _, draw in ipairs(draws) do
    if draw.valid and draw.args.radius then radius[draw.args.target] = draw.args.radius end
  end
  assert(radius[tank] == 1.7, "a tank ring changed size")
  assert(radius[hq] and radius[hq] > 7.9, "the headquarters ring hides under its body")
  -- Rings drawn by an older version are redrawn on upgrade.
  dofile("control.lua")
  storage.headquarters = {[hq.unit_number] = {entity = hq, force_index = hq.force_index, helpers = {}}}
  local ring = divisions.record(1, 1).render.rings[hq.unit_number]
  local kept = divisions.record(1, 1).render.rings[tank.unit_number]
  handlers.configuration_changed()
  assert(not ring.valid and divisions.record(1, 1).render.rings[hq.unit_number].valid, "the old ring stayed")
  assert(kept.valid, "a tank ring was redrawn")
end)

test("division window replaces the old side panel", function()
  local panel = require("scripts.panel")
  local old = players[1].gui.left.add{type = "frame", name = "tank_squads_divisions"}
  divisions.assign(1, 4, {soldier()})
  panel.update(1)
  assert(not old.valid, "the old side panel stayed")
  assert(players[1].gui.screen.tank_squads_divisions.visible, "no window on the screen")
end)

test("GUI division clicks recall members and update selection", function()
  dofile("control.lua")
  divisions.assign(1, 2, {soldier()})
  divisions.assign(1, 3, {soldier()})
  require("scripts.panel").update(1)
  local button = players[1].gui.screen.tank_squads_divisions.body.divisions.row_2.division_2
  handlers.on_gui_click{player_index = 1, element = button}
  assert(divisions.selected(1) == 2 and button.toggled, "click failed to recall division")
end)

test("empty divisions remove abandoned routes and mode", function()
  local a = soldier()
  divisions.assign(1, 1, {a})
  patrol.add_waypoint(1, 1, {x = 10, y = 0}, surface)
  patrol.add_waypoint(1, 1, {x = 20, y = 0}, surface)
  patrol.start(1, 1)
  a.valid = false
  divisions.refresh()
  local record = divisions.record(1, 1)
  assert(record.mode == "idle" and record.patrol == nil, "empty division retained patrol")
  for _, draw in ipairs(draws) do assert(not draw.valid, "empty division left map clutter") end
end)

test("chaingun follows attack targets without rebuilding the overlay", function()
  local weapons = require("scripts.weapons")
  local a, enemy = soldier(), soldier("enemy", nil, 10, 0)
  weapons.register(a)
  weapons.register(a)
  assert(#draws == 1, "duplicate turret overlay")
  local gun = draws[1]
  assert(gun.args.target == a and gun.args.use_target_orientation, "idle turret does not follow hull")
  weapons.on_shot{effect_id = "tank-squad-shot", source_entity = a, target_entity = enemy, tick = 10}
  assert(gun.orientation_target == enemy and gun.use_target_orientation == false, "gun does not aim at enemy")
  for tick = 11, 30 do
    weapons.on_shot{effect_id = "tank-squad-shot", source_entity = a, target_entity = enemy, tick = tick}
  end
  assert(#draws == 1, "shots create extra render objects")
  game.tick = 31
  weapons.tick()
  assert(gun.orientation_target == enemy, "maintenance cancels active aiming")
  enemy.valid = false
  weapons.tick()
  assert(gun.orientation_target == a and gun.use_target_orientation == true, "dead target retained")
  a.valid = false
  weapons.tick()
  assert(not gun.valid and next(storage.weapons) == nil, "destroyed carrier leaked turret")
end)

test("chaingun recovers rendering and returns to hull facing after shooting", function()
  local weapons = require("scripts.weapons")
  local a, enemy = soldier(), soldier("enemy", nil, 10, 0)
  weapons.on_shot{effect_id = "tank-squad-shot", source_entity = a, target_entity = enemy, tick = 0}
  draws[1].valid = false
  weapons.tick()
  assert(#draws == 2 and draws[2].valid, "missing overlay not repaired")
  weapons.on_shot{effect_id = "tank-squad-shot", source_entity = a, target_entity = enemy, tick = 1}
  game.tick = 120
  weapons.tick()
  assert(draws[2].orientation_target == a, "inactive gun keeps tracking old enemy")
end)

test("sustained fire at one target only refreshes the aim timestamp", function()
  local weapons = require("scripts.weapons")
  local a, enemy = soldier(), soldier("enemy", nil, 10, 0)
  weapons.register(a)
  local reads = {count_reads(a, "surface"), count_reads(enemy, "surface")}
  for tick = 0, 24, 12 do
    weapons.on_shot{effect_id = "tank-squad-shot", source_entity = a, target_entity = enemy, tick = tick}
  end
  assert(reads[1].n + reads[2].n == 0, "each shot builds surface objects to compare")
  assert(draws[1].orientation_target == enemy, "gun does not aim at the target")
  assert(storage.weapons[a.unit_number].last_shot == 24, "aim timestamp not refreshed")
end)

test("barracks deployment and upgrade attach chainguns", function()
  local b, output = building()
  output["tank-squad-recruit-1"] = 1
  barracks.tick()
  local attached = 0
  for _, record in pairs(storage.weapons or {}) do
    assert(record.entity.name == names.soldier_names[1], "gun attached to wrong entity")
    attached = attached + 1
  end
  assert(attached == 1, "new recruit has no chaingun")
  local old = soldier()
  dofile("control.lua")
  handlers.configuration_changed{}
  assert(storage.weapons[old.unit_number], "upgrade left old soldiers without guns")
end)

test("the one-second sweep checks each soldier's gun once, spread over the slices", function()
  dofile("control.lua")
  local weapons = require("scripts.weapons")
  -- Vision reads soldiers on its own schedule; switch it off to isolate guns.
  settings.global[require("scripts.config").VISION].value = false
  local sweep = handlers.nth_tick
  local slices = 60 / sweep.period
  local reads = {}
  for i = 1, 20 do
    local e = soldier()
    weapons.register(e)
    reads[i] = count_reads(e, "valid")
  end
  local largest, before = 0, 0
  for tick = 0, 60 - sweep.period, sweep.period do
    game.tick = tick
    sweep.handler{tick = tick}
    local total = 0
    for _, r in ipairs(reads) do total = total + r.n end
    largest, before = math.max(largest, total - before), total
  end
  for i, r in ipairs(reads) do assert(r.n == 1, "soldier " .. i .. " checked " .. r.n .. " times in one second") end
  assert(largest <= math.ceil(20 / slices), "one slice checked " .. largest .. " of 20 guns")
end)

test("a sweep slice visits only its own soldiers' guns", function()
  dofile("control.lua")
  local weapons = require("scripts.weapons")
  settings.global[require("scripts.config").VISION].value = false
  local sweep = handlers.nth_tick
  local function second()
    for tick = 0, 60 - sweep.period, sweep.period do
      game.tick = tick
      sweep.handler{tick = tick}
    end
  end
  local soldiers, reads = {}, {}
  for i = 1, 20 do
    soldiers[i] = soldier()
    weapons.register(soldiers[i])
  end
  -- Saves from before the slice index build it on their first sweep.
  second()
  local scans = 0
  setmetatable(storage.weapons, {__pairs = function(t)
    scans = scans + 1
    return next, t, nil
  end})
  local late = soldier()
  weapons.register(late)
  for i, e in ipairs(soldiers) do reads[i] = count_reads(e, "valid") end
  local late_reads = count_reads(late, "valid")
  second()
  assert(scans == 0, "a slice walked the whole gun registry " .. scans .. " times")
  for i, r in ipairs(reads) do assert(r.n == 1, "soldier " .. i .. " checked " .. r.n .. " times in one second") end
  assert(late_reads.n == 1, "a soldier registered after the index was built is never checked")
  soldiers[1].valid = false
  second()
  assert(storage.weapons[soldiers[1].unit_number] == nil, "destroyed soldier kept its gun")
  local index = storage.weapon_slices
  assert(index.slices[soldiers[1].unit_number % index.phases][soldiers[1].unit_number] == nil,
    "destroyed soldier stays in its slice")
end)

test("entity events are filtered to the mod's own entities", function()
  dofile("control.lua")
  assert(handlers.on_entity_spawned == nil, "every biter spawn reaches Lua")
  local expected = {[names.barracks] = true}
  for _, name in ipairs(names.unit_names) do expected[name] = true end
  local helpers = {}
  for _, name in ipairs(require("scripts.headquarters").HELPER_NAMES) do helpers[name] = true end
  local function check(event, allowed)
    local filters = assert(event_filters[event], event .. " is unfiltered")
    local seen = {}
    for _, f in ipairs(filters) do
      assert(f.filter == "name" and allowed[f.name] and not f.mode, event .. " has an unexpected filter")
      seen[f.name] = true
    end
    for name in pairs(allowed) do assert(seen[name], event .. " misses " .. name) end
  end
  for _, event in ipairs({"on_built_entity", "on_robot_built_entity", "script_raised_built",
      "script_raised_revive"}) do
    check(event, expected)
  end
  -- Deaths also reach Lua for the enemy side only, to credit kills.
  local own, kills = {}, {}
  for _, f in ipairs(event_filters.on_entity_died) do
    if f.filter == "name" then own[#own + 1] = f else kills[#kills + 1] = f end
  end
  event_filters.on_entity_died = own
  check("on_entity_died", expected)
  local kill_filters = require("scripts.veterans").KILL_FILTERS
  assert(#kills == #kill_filters, "kill credit filters changed")
  for i, f in ipairs(kills) do
    assert(f.filter == kill_filters[i].filter and not f.mode, "kill filters narrow the unit filters")
  end
  -- Clones of headquarters helpers are removed; a cloned headquarters builds its own.
  local cloned = {}
  for name in pairs(expected) do cloned[name] = true end
  for name in pairs(helpers) do cloned[name] = true end
  check("on_entity_cloned", cloned)
  local units = {}
  for _, name in ipairs(names.unit_names) do units[name] = true end
  check("script_raised_destroy", units)
  local filters = assert(event_filters.on_entity_damaged, "on_entity_damaged is unfiltered")
  assert(#filters == #names.unit_names, "on_entity_damaged is not limited to soldiers and headquarters")
end)

test("the one-second sweep visits each division and barracks once, spread over the second", function()
  dofile("control.lua")
  local sweep = handlers.nth_tick
  assert(sweep and 60 % sweep.period == 0 and sweep.period < 60, "sweep is not sliced")
  local members = {}
  for n = 1, 9 do
    members[n] = soldier()
    divisions.assign(1, n, {members[n]})
  end
  local linked, output = building()
  local plain = building()
  assert(barracks.configure(linked, 1, 4, 5))
  output["tank-squad-recruit-1"] = 1
  local resolved, lookup = {}, game.get_entity_by_unit_number
  game.get_entity_by_unit_number = function(id) resolved[id] = (resolved[id] or 0) + 1; return lookup(id) end
  local heals = {}
  surface.find_entities_filtered = function(query)
    if query.radius == 12 then heals[#heals + 1] = query.position end
    return {}
  end
  local busiest = 0
  for tick = 60, 119, sweep.period do
    game.tick = tick
    local before = 0
    for _ in pairs(resolved) do before = before + 1 end
    sweep.handler{tick = tick}
    local after = 0
    for _ in pairs(resolved) do after = after + 1 end
    busiest = math.max(busiest, after - before)
  end
  game.get_entity_by_unit_number = lookup
  for n = 1, 9 do
    assert(resolved[members[n].unit_number] == 1, "division " .. n .. " swept " .. tostring(resolved[members[n].unit_number]) .. " times")
  end
  assert(busiest <= 2, "one slice swept " .. busiest .. " divisions")
  assert(#heals == 2, "barracks healed " .. #heals .. " times in one second")
  assert(#divisions.get(1, 4) == 2, "linked barracks did not deploy into its division")
end)

test("shot events ignore unrelated effects and invalid sources", function()
  dofile("control.lua")
  local a, enemy = soldier(), soldier("enemy")
  handlers.on_script_trigger_effect{effect_id = "another-mod", source_entity = a, target_entity = enemy}
  handlers.on_script_trigger_effect{effect_id = "tank-squad-shot", target_entity = enemy}
  assert(#draws == 0, "unrelated effects create guns")
end)

test("custom vehicles keep combat balance and add harmless native tracers", function()
  local function copy(t)
    if type(t) ~= "table" then return t end
    local out = {}; for k, v in pairs(t) do out[k] = copy(v) end; return out
  end
  package.loaded.util = {table = {deepcopy = copy}}
  data = {raw = {car = {tank = {animation = {filename = "vanilla-tank"}}},
    ["ammo-turret"] = {["gun-turret"] = {attack_parameters = {sound = {filename = "native-gunshot"}}}}}}
  data.extend = function(_, prototypes)
    for _, prototype in ipairs(prototypes) do
      data.raw[prototype.type] = data.raw[prototype.type] or {}
      data.raw[prototype.type][prototype.name] = prototype
    end
  end
  dofile("prototypes/soldier.lua")
  local damage = {6, 10, 16}
  for tier = 1, 3 do
    local unit = data.raw.unit[names.soldier_names[tier]]
    assert(unit.type == "unit" and unit.max_health == 300 + tier * 100, "vehicle no longer compatible")
    local attack = unit.attack_parameters
    assert(attack.range == 20 and attack.cooldown == 12 and attack.ammo_category == "bullet", "combat stats changed")
    assert(unit.run_animation.filename == "__tank-squads__/graphics/chaingun-chassis.png", "old tank artwork retained")
    local actual_damage, tracer, aiming, sparks = 0, false, false, nil
    for _, action in ipairs(attack.ammo_type.action) do
      local delivery = action.action_delivery
      if delivery.type == "projectile" then
        tracer = delivery.projectile == "tank-squad-tracer"
        assert(action.probability and action.probability > 0 and action.probability < 1, "every shot spawns a tracer")
      end
      for _, effect in ipairs(delivery.target_effects or {}) do
        if effect.type == "damage" then
          assert(not action.probability, "damage depends on a cosmetic roll")
          actual_damage = actual_damage + effect.damage.amount
        end
        if effect.type == "script" and effect.effect_id == "tank-squad-shot" then aiming = not action.probability end
        if effect.type == "create-entity" then
          -- The shot hook's rank bonus can kill the target, and the engine
          -- stops the game when an oriented spark is created without one.
          assert(not aiming, "hit sparks come after the shot hook")
          sparks = effect
        end
      end
    end
    assert(actual_damage == damage[tier], "bullet damage changed")
    assert(tracer and aiming, "missing tracer or native shot target hook")
    assert(sparks and sparks.only_when_visible, "hit sparks spawn where nobody can see them")
  end
  local tracer = data.raw.projectile["tank-squad-tracer"]
  assert(tracer and not tracer.action, "cosmetic tracer adds damage")
end)

test("chainguns follow clone and destroy lifecycle events", function()
  dofile("control.lua")
  local a, clone = soldier(), soldier()
  handlers.script_raised_built{entity = a}
  handlers.on_entity_cloned{source = a, destination = clone}
  assert(storage.weapons[a.unit_number] and storage.weapons[clone.unit_number], "clone lost gun")
  local original = storage.weapons[a.unit_number].gun
  local copied = storage.weapons[clone.unit_number].gun
  assert(original ~= copied, "clone shares gun with original")
  handlers.script_raised_destroy{entity = clone}
  assert(not copied.valid and original.valid, "destroying clone changed original gun")
end)

test("chainguns stop tracking targets moved to another surface", function()
  local weapons = require("scripts.weapons")
  local a, enemy = soldier(), soldier("enemy")
  weapons.on_shot{effect_id = "tank-squad-shot", source_entity = a, target_entity = enemy, tick = 0}
  enemy.surface, enemy.surface_index = {index = 2}, 2
  weapons.tick()
  assert(draws[1].orientation_target == a, "gun tracks coordinates on another surface")
end)

test("review: a reassigned soldier cannot advance its old patrol", function()
  local a, b = soldier(), soldier()
  divisions.assign(1, 1, {a, b})
  patrol.add_waypoint(1, 1, {x=10,y=0}, surface)
  patrol.add_waypoint(1, 1, {x=20,y=0}, surface)
  patrol.start(1, 1)
  divisions.assign(1, 2, {a})
  divisions.refresh()
  local before, command = patrol.index(1, 1, b.unit_number), b.command
  assert(patrol.advance(a.unit_number) == nil and patrol.index(1, 1, a.unit_number) == nil)
  assert(patrol.index(1, 1, b.unit_number) == before and b.command == command,
    "detached soldier advanced old division and overwrote remaining member command")
end)
test("review: same-force players cannot keep conflicting automated ownership", function()
  local a = soldier()
  players[2] = {index=2, force=players[1].force, surface=surface}
  divisions.assign(1, 1, {a})
  patrol.add_waypoint(1, 1, {x=10,y=0}, surface)
  patrol.start(1, 1)
  divisions.assign(2, 1, {a})
  scout.set(2, 1, true)
  scout.tick()
  assert(divisions.size(1, 1) == 0, "unit remains in player 1 patrol and player 2 scout simultaneously")
end)
test("review: failed scout destination is skipped", function()
  local a = soldier()
  divisions.assign(1, 1, {a})
  scout.set(1, 1, true)
  scout.tick()
  local team = divisions.record(1, 1).scout.teams[1]
  for i = 1, 4 do
    local target = team.target
    scout.on_command_completed(a.unit_number, defines.behavior_result.fail)
    scout.tick()
    assert(team.target and (team.target.x ~= target.x or team.target.y ~= target.y),
      "unreachable uncharted chunk is retried indefinitely")
    assert(team.failed[target.x .. ":" .. target.y], "failed chunk was not blocked")
  end
end)

test("patrol handover: the soldier left takes over the whole route after its leg", function()
  local a, b = soldier(), soldier()
  divisions.assign(1, 1, {a,b})
  patrol.add_waypoint(1, 1, {x=10,y=0}, surface)
  patrol.add_waypoint(1, 1, {x=20,y=0}, surface)
  patrol.start(1, 1)
  patrol.advance(a.unit_number)
  local walking = b.command
  divisions.assign(1, 2, {a})
  local r = divisions.record(1,1).patrol
  assert(r.posts[b.unit_number] and not r.posts[a.unit_number])
  assert(#r.posts[b.unit_number].points == 2, "the soldier left does not walk the whole route")
  assert(b.command == walking, "the handover interrupted a leg")
  patrol.advance(b.unit_number)
  assert(b.command.destination.x == 15)
  patrol.advance(b.unit_number)
  assert(b.command.destination.x == 20)
end)

test("upgrade removes duplicate ownership and repairs legacy leader", function()
  local a,b = soldier(),soldier()
  players[2] = {index=2,force=players[1].force,surface=surface}
  divisions.assign(1,1,{a})
  local record = divisions.record(2,1)
  record.members = {a.unit_number,b.unit_number}
  record.mode = "patrol"
  record.patrol = {waypoints={{x=10,y=0}},index=1,surface_index=1,leader=a.unit_number}
  divisions.reconcile_ownership()
  assert(#record.members == 1 and record.members[1] == b.unit_number)
  assert(record.patrol.posts[b.unit_number] and not record.patrol.posts[a.unit_number] and record.patrol.leader == nil)
  divisions.reconcile_ownership()
  assert(divisions.size(1,1)==1 and divisions.size(2,1)==1)
end)

test("scout success does not blacklist and failures expire with bounded storage", function()
  local a = soldier()
  divisions.assign(1,1,{a})
  scout.set(1,1,true)
  scout.tick()
  local team = divisions.record(1,1).scout.teams[1]
  scout.on_command_completed(a.unit_number, defines.behavior_result.success)
  scout.tick()
  assert(not team.failed or next(team.failed) == nil, "a successful hop blocked its target")
  for i=1,scout.FAILURE_LIMIT+10 do
    -- The stall rule would block the team first; it has its own tests.
    team.target, team.idle = {x=i,y=50}, nil
    scout.on_command_completed(a.unit_number, defines.behavior_result.fail)
    scout.tick()
    game.tick = game.tick + 1
  end
  local count = 0
  for _ in pairs(team.failed) do count=count+1 end
  assert(count == scout.FAILURE_LIMIT, "blocked chunks grew to " .. count)
  game.tick = game.tick + scout.FAILURE_TTL
  scout.tick()
  assert(next(team.failed) == nil, "blocked chunks never expired")
end)

test("large transfers reconcile each affected patrol only once", function()
  local members = {}
  for i=1,2000 do members[i] = soldier() end
  local remaining = soldier()
  members[#members+1] = remaining
  divisions.assign(1,1,members)
  patrol.add_waypoint(1,1,{x=10,y=0},surface)
  patrol.start(1,1)
  members[#members] = nil
  local calls = 0
  remaining.commandable.set_command = function(command) calls=calls+1; remaining.command=command end
  divisions.assign(1,2,members)
  assert(calls <= 1, "transfer reissued remaining patrol once per transferred unit")
  assert(divisions.size(1,1)==1 and divisions.size(1,2)==2000)
end)

require('test.specialists'){test=test, soldier=soldier, building=building, handlers=function() return handlers end}
require('test.config'){test = test}
require('test.retreat'){test = test, soldier = soldier, building = building, count_reads = count_reads}
require('test.combat'){test = test, soldier = soldier, count_reads = count_reads}
require('test.reinforcements'){test = test, soldier = soldier, building = building, gui_element = gui_element, handlers = function() return handlers end}
require('test.escort'){test = test, soldier = soldier, building = building, gui_element = gui_element,
  handlers = function() return handlers end, draws = function() return draws end, count_reads = count_reads}
require('test.division_index'){test=test, soldier=soldier, building=building}
require('test.patrol'){test = test, soldier = soldier, building = building, count_reads = count_reads}
require('test.vision'){test = test, soldier = soldier, count_reads = count_reads, handlers = function() return handlers end}
require('test.assault'){test = test, soldier = soldier, building = building, gui_element = gui_element,
  handlers = function() return handlers end}
require('test.scout_geometry'){test = test}
require('test.scout_teams'){test = test, soldier = soldier, building = building, draws = function() return draws end}
require('test.headquarters'){test = test, soldier = soldier}
require('test.insignia'){test = test, soldier = soldier, handlers = function() return handlers end,
  draws = function() return draws end, players = function() return players end}
require('test.unit_card'){test = test, soldier = soldier, handlers = function() return handlers end,
  players = function() return players end}
require('test.veterans'){test = test, soldier = soldier, handlers = function() return handlers end,
  draws = function() return draws end, players = function() return players end, count_reads = count_reads}
require('test.selection'){test = test, soldier = soldier, building = building,
  handlers = function() return handlers end, players = function() return players end}
require('test.veterans_gui'){test = test, soldier = soldier, gui_element = gui_element,
  handlers = function() return handlers end, players = function() return players end}
print(string.format("%d passed, %d failed", passed, failed))
assert(failed == 0, "regression tests failed")
