return function(ctx)
  local test = ctx.test
  local config = require('scripts.config')

  local function set(name, value) settings.global[name] = {value = value} end

  test('config: defaults match the escort settings', function()
    local v = config.escort()
    assert(v.ring == 160 and v.detect == 224 and v.band_min == 256 and v.band_max == 448 and v.step == 64,
      'wrong distance defaults')
    assert(v.retreat == 0.35 and v.rejoin == 0.95 and v.range == 1000, 'wrong retreat defaults')
  end)

  test('config: detection reaches at least 16 tiles past the ring', function()
    set('tank-squads-escort-ring-radius', 300)
    set('tank-squads-escort-detect-radius', 100)
    assert(config.escort().detect == 316)
  end)

  test('config: the band outer edge stays at least 32 tiles past the inner edge', function()
    set('tank-squads-escort-band-min', 600)
    set('tank-squads-escort-band-max', 500)
    assert(config.escort().band_max == 632)
  end)

  test('config: rejoin health stays above retreat health and at most 100 %', function()
    set('tank-squads-retreat-health', 90)
    set('tank-squads-rejoin-health', 50)
    assert(config.escort().rejoin == 0.95, 'rejoin not raised to retreat + 5')
    set('tank-squads-rejoin-health', 100)
    assert(config.escort().rejoin == 1, 'rejoin above 100 %')
  end)

  test('config: settings stage defines every setting as a map setting with locale', function()
    local defined
    data = {extend = function(_, list) defined = list end}
    dofile('settings.lua')
    data = nil
    local locale = io.open('locale/en/tank-squads.cfg'):read('*a')
    assert(#defined == #config.DEFINITIONS + 1, 'setting count mismatch')
    for i, d in ipairs(config.DEFINITIONS) do
      local s = defined[i]
      assert(s.type == 'int-setting' and s.setting_type == 'runtime-global' and s.name == d.name, d.name)
      assert(s.default_value == d.default and s.minimum_value == d.min and s.maximum_value == d.max, d.name)
      assert(d.default >= d.min and d.default <= d.max, d.name .. ' default out of range')
      local _, names = locale:gsub('\n' .. d.name:gsub('%-', '%%-') .. '=', '')
      assert(names == 2, d.name .. ' needs a locale name and description')
    end
    local vision = defined[#defined]
    assert(vision.type == 'bool-setting' and vision.setting_type == 'runtime-global'
      and vision.name == config.VISION and vision.default_value == true, 'soldier vision setting')
    local _, names = locale:gsub('\n' .. config.VISION:gsub('%-', '%%-') .. '=', '')
    assert(names == 2, config.VISION .. ' needs a locale name and description')
  end)
end
