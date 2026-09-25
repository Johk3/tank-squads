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
for n = 1, 9 do
  local badge = rendering.draw_text{text = '[img=tank-squad-insignia-' .. n .. ']', use_rich_text = true,
    color = {1, 1, 1}, target = {0, 0}, surface = s, render_mode = 'chart', alignment = 'center',
    vertical_alignment = 'bottom', scale = 3, scale_with_zoom = true, time_to_live = 1}
  if not (badge.valid and badge.use_rich_text and badge.scale_with_zoom) then error('map badge did not draw: ' .. n) end
  badge.destroy()
end
return 'PASS: ' .. #sprites .. ' insignia and rank sprites load and draw'
