-- 3.0 opponent gauge wiring through main.lua: a valid read-only sub-snapshot
-- is accepted and exported; a malformed one is a deployment fault that releases
-- AI input instead of being read as an energy level.
HitType = { Rect = 0, Circle = 1, RotatableRect = 2 }
local actual_dofile, actual_open = dofile, io.open
local scenario = nil
local function run(opponent)
  local output, sent = {}, {}
  local cfg = actual_dofile('config.lua')
  cfg.debug_log, cfg.debug_log_interval_frames = true, 1
  dofile = function(path)
    if path == 'config.lua' then return cfg end
    return actual_dofile(path)
  end
  io.open = function(path, mode)
    if path == 'runtime-settings.lua' then return nil end
    assert(type(path) == 'string' and path:match('^ai_debug_.+%.csv$') and mode == 'w',
      'unexpected I/O: ' .. tostring(path))
    return { write = function(_, text) output[#output + 1] = text end,
      flush = function() end, close = function() end }
  end
  function sendKeys(mask) sent[#sent + 1] = mask end
  local sensor = { apiVersion = 1, valid = true, state = 0, protectionFrames = 0, canCharge = true,
    chargeBlockFrames = 0, chargeWarmupFrames = 11, timeScale = 1, baseScaleX = 1, baseScaleY = 1,
    moveScaleX = 1, moveScaleY = 1, poisonClouds = {},
    followupApiVersion = 1, canPressZ = true, c1ActionActive = false }
  if opponent ~= nil then
    sensor.opponentApiVersion, sensor.opponent = 1, opponent
  end
  local player = { x = 0, y = 320, life = 10, spellPoint = 0, combo = 0,
    currentCharge = 0, currentChargeMax = 200, chargeSpeed = 10, speedFast = 4, speedSlow = 2,
    hitBodyRect = { type = HitType.Rect, width = 4, height = 4 },
    hitBodyCircle = { radius = 2 }, sensor = sensor }
  player_side = 2
  game_sides = { [2] = { player = player, bullets = {}, enemies = {}, exAttacks = {} } }
  actual_dofile('main.lua')
  main()
  io.open, dofile = actual_open, actual_dofile
  return output, sent
end

local function columns(line)
  local result = {}
  for value in (line:gsub('\n', '') .. ','):gmatch('(.-),') do result[#result + 1] = value end
  return result
end
local function readRow(output)
  local header = columns(output[1])
  local out = {}
  for index, name in ipairs(header) do out[name] = index end
  local first = columns(output[2])
  return out, first
end

local valid = { valid = true, chargeCurrent = 120, chargeMax = 260, chargeSpeed = 10,
  state = 0, protectionFrames = 0, life = 5, spellPoint = 12345, combo = 3 }
local output, sent = run(valid)
local map, first = readRow(output)
assert(#output == 2, 'valid opponent scenario writes header and one sample')
assert(tonumber(first[map.sensor_valid]) == 1, 'valid opponent must not fail the sensor')
assert(first[map.opp_sensor_valid] == 'true', 'valid opponent must be exported as available')
assert(tonumber(first[map.opp_charge_max]) == 260 and tonumber(first[map.opp_charge_current]) == 120,
  'opponent gauge values must reach the diagnostics')
assert(#sent >= 1, 'AI input must still be sent with a valid opponent')

local missing = run(nil)
local mmap = readRow(missing)
assert(tonumber(columns(missing[2])[mmap.sensor_valid]) == 1, 'absent opponent sub-snapshot stays compatible')
assert(columns(missing[2])[mmap.opp_sensor_valid] == '', 'absent opponent reported unavailable')

for name, broken in pairs({
  gauge = { valid = true, chargeCurrent = 0, chargeMax = 401, chargeSpeed = 10, state = 0,
    protectionFrames = 0, life = 5, spellPoint = 0, combo = 0 },
  nan = { valid = true, chargeCurrent = 0 / 0, chargeMax = 200, chargeSpeed = 10, state = 0,
    protectionFrames = 0, life = 5, spellPoint = 0, combo = 0 },
  flag = { valid = 'yes', chargeCurrent = 0, chargeMax = 200, chargeSpeed = 10, state = 0,
    protectionFrames = 0, life = 5, spellPoint = 0, combo = 0 } }) do
  local out, sent2 = run(broken)
  assert(#out == 1, 'malformed opponent (' .. name .. ') must stop before writing policy samples')
  assert(#sent2 >= 1, 'faulted sensor must still send an explicit release')
  for _, key in ipairs(sent2) do assert(key == 0, 'malformed opponent must release AI input') end
end
print('PASS: main-loop opponent gauge validation, diagnostics and fail-closed input release')
