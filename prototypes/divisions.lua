local inputs = {}

-- Bare and SHIFT-modified number keys belong to the quickbar, so these
-- defaults use CONTROL and ALT and consume the game action rather than letting
-- it through. Both families are rebindable in the options menu.
for n = 1, 9 do
  table.insert(inputs, {
    type = "custom-input",
    name = "tank-squad-assign-division-" .. n,
    key_sequence = "CONTROL + " .. n,
    consuming = "game-only",
    action = "lua",
  })
  table.insert(inputs, {
    type = "custom-input",
    name = "tank-squad-select-division-" .. n,
    key_sequence = "ALT + " .. n,
    consuming = "game-only",
    action = "lua",
  })
end

-- Follows the player's own "open" binding, without consuming it.
table.insert(inputs, {
  type = "custom-input",
  name = "tank-squad-open-headquarters",
  key_sequence = "",
  linked_game_control = "open-gui",
  action = "lua",
})

data:extend(inputs)
