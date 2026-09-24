local config = require("scripts.config")

local definitions = {}
for i, d in ipairs(config.DEFINITIONS) do
  definitions[i] = {
    type = "int-setting", name = d.name, setting_type = "runtime-global",
    default_value = d.default, minimum_value = d.min, maximum_value = d.max,
    order = string.format("a-%02d", i),
  }
end
definitions[#definitions + 1] = {
  type = "bool-setting", name = config.VISION, setting_type = "runtime-global",
  default_value = true, order = "b-01",
}
data:extend(definitions)
