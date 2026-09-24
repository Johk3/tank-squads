local proto = prototypes.entity["tank-squad-barracks"]
if proto.type ~= "assembling-machine" then error("barracks is a " .. proto.type .. ", expected assembling-machine") end
if proto.tile_width ~= 3 or proto.tile_height ~= 3 then
  error("barracks footprint is " .. proto.tile_width .. "x" .. proto.tile_height .. ", expected 3x3")
end
if not proto.crafting_categories["tank-squad-training"] then error("barracks cannot craft training recipes") end
