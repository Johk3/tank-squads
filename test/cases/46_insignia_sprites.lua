local s = game.surfaces[1]
local sprites = {}
for n = 1, 9 do sprites[#sprites + 1] = 'tank-squad-insignia-' .. n end
for rank = 0, 3 do sprites[#sprites + 1] = 'tank-squad-rank-' .. rank end
for _, sprite in ipairs(sprites) do
  if not helpers.is_valid_sprite_path(sprite) then error('missing sprite ' .. sprite) end
  local object = rendering.draw_sprite{sprite = sprite, target = {0, 0}, surface = s, time_to_live = 1}
  if not object.valid then error('sprite did not draw: ' .. sprite) end
  object.destroy()
end
return 'PASS: ' .. #sprites .. ' insignia and rank sprites load and draw'
