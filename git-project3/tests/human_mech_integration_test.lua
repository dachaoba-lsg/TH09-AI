-- 3.8 mech must execute the complete 3.7 main/observer/bloom/dodge behavior.
-- Two isolated Lua 5.1 environments receive independent copies of each fixture.
-- The small feedback driver is NOT an emulation of TH09 charge/damage physics.
-- Run from the project root with tests/run_native_lua.py. Optional environment:
-- TH09_HUMAN_AI_BASELINE = directory containing the unchanged 3.7 main.lua.
local real_loadfile, real_open = loadfile, io.open
local baseline = os and os.getenv and os.getenv('TH09_HUMAN_AI_BASELINE')
if not baseline or baseline == '' then baseline = '../../work/before-human-movement-3.8.0/src/ai' end
baseline = baseline:gsub('\\', '/'):gsub('/$', '')
local probe = real_open(baseline .. '/main.lua', 'rb')
if not probe then
  print('human_mech_integration_test: SKIP (3.7 baseline missing; set TH09_HUMAN_AI_BASELINE)')
  return
end
probe:close()

local checks, cases, callbacks, human_callbacks = 0, 0, 0, 0
local function check(ok, message) checks = checks + 1; assert(ok, message) end
local function eq(actual, expected, message)
  check(actual == expected, message .. ': ' .. tostring(actual) .. ' ~= ' .. tostring(expected))
end
local function copy(value)
  if type(value) ~= 'table' then return value end
  local result = {}; for key, entry in pairs(value) do result[key] = copy(entry) end
  return result
end
local function bit(mask, value) return math.floor(mask / value) % 2 == 1 end
local function clamp(value, low, high) return math.max(low, math.min(high, value)) end
local function split(line)
  local result = {}
  for value in (line:gsub('[\r\n]', '') .. ','):gmatch('(.-),') do result[#result + 1] = value end
  return result
end
-- Only additive human movement diagnostics may be absent from the old result.
-- Every original field, including rescue evidence and nested trajectories,
-- remains exact. No numeric tolerance hides different planning decisions.
local poison_diagnostic = {poison_cost=true, poison_nav_active=true, poison_level=true, poison_risk=true, poison_target_x=true, poison_target_y=true, poison_probe_count=true, poison_nav_samples=true}
local function same(actual, expected, path, allow_human)
  eq(type(actual), type(expected), path .. ' type')
  if type(expected) ~= 'table' then eq(actual, expected, path); return end
  for key, value in pairs(expected) do same(actual[key], value, path .. '.' .. tostring(key), allow_human) end
  for key in pairs(actual) do
    check(expected[key] ~= nil or (allow_human and type(key) == 'string' and (key:match('^human_') or poison_diagnostic[key])),
      path .. ' unexpected field ' .. tostring(key))
  end
end
local function player()
  return { character = 13, x = 0, y = 320, life = 10, spellPoint = 0, combo = 0,
    currentCharge = 0, currentChargeMax = 300, chargeSpeed = 10, speedFast = 4, speedSlow = 2,
    hitBodyRect = { type = 0, x = 0, y = 320, width = 4, height = 4 },
    hitBodyCircle = { type = 1, x = 0, y = 320, radius = 2 },
    sensor = { apiVersion = 1, valid = true, state = 0, protectionFrames = 0, canCharge = true,
      chargeBlockFrames = 0, chargeWarmupFrames = 0, timeScale = 1, cutIn = false,
      movementEnabled = true, baseScaleX = 1, baseScaleY = 1, moveScaleX = 1, moveScaleY = 1,
      poisonClouds = {}, followupApiVersion = 1, canPressZ = true, c1ActionActive = false,
      c1ActionAge = 0, c1ActionDuration = 0, opponentApiVersion = 1,
      opponent = { valid = true, chargeCurrent = 0, chargeMax = 100, chargeSpeed = 10,
        state = 0, protectionFrames = 0, life = 10, spellPoint = 0, combo = 0 } } }
end
local function world()
  return { player = player(), chargeType = 0, bullets = {}, enemies = {}, exAttacks = {} }
end
local function bullet(id, x, y, vx, vy, shape)
  return { id = id, enabled = true, hittable = true, isErasable = true,
    x = x, y = y, vx = vx or 0, vy = vy or 0,
    hitBody = shape or { type = 1, x = x, y = y, radius = 2 } }
end
local function fixture(root, ai, selected, seconds)
  local f = { output = {}, masks = {}, logs = {}, choose_calls = 0, update_calls = 0 }
  local env = {}; for key, value in pairs(_G) do env[key] = value end
  env._G, env.io, env.os = env, {}, { clock = function() return 0 end }
  env.HitType, env.ExAttackType, env.ChargeType = { Rect = 0, Circle = 1, RotatableRect = 2 },
    { Medicine = 16 }, { Slow = 0, Charge = 1 }
  env.print = function(message) f.logs[#f.logs + 1] = message end
  local function load(path)
    local chunk = assert(real_loadfile(root .. '/' .. path)); setfenv(chunk, env); return chunk
  end
  env.loadfile = function(path)
    if path == 'runtime-settings.lua' then return function() return { seconds = seconds or 0, ai = copy(ai) } end end
    return load(path)
  end
  env.io.open = function(path, mode)
    if path == 'runtime-settings.lua' and mode == 'r' then return { close = function() end } end
    if mode == 'r' then return nil end
    check(mode == 'w' and path:match('^ai_debug_'), 'unexpected sandbox I/O ' .. tostring(path))
    return { write = function(_, text) f.output[#f.output + 1] = text end,
      flush = function() end, close = function() end }
  end
  env.dofile = function(path)
    local module = load(path)()
    if path == 'config.lua' then
      -- This suite isolates the 3.8 human-style/mech contract. 3.9 toxin
      -- navigation is intentionally common to all tiers and tested separately.
      if module.dodge.poison_navigation then module.dodge.poison_navigation.enabled = false end
      module.debug_log, module.debug_log_interval_frames = true, 1; f.config = module
    elseif path == 'dodge.lua' then
      local choose = module.choose
      module.choose = function(side, state, cfg, intent)
        f.choose_calls, f.state, f.effective = f.choose_calls + 1, state, cfg
        f.movement = choose(side, state, cfg, intent); return f.movement
      end
    elseif path == 'bloom.lua' then
      local update = module.update
      module.update = function(side, state, cfg, observation)
        f.update_calls, f.bloom, f.observation = f.update_calls + 1, state, observation
        f.plan = update(side, state, cfg, observation); return f.plan
      end
    end
    return module
  end
  f.side, f.other, f.selected = world(), world(), selected or 2
  f.other.player.character, f.other.player.currentChargeMax = 9, 17
  env.player_side, env.game_sides = f.selected, { [f.selected] = f.side, [3 - f.selected] = f.other }
  env.sendKeys = function(mask) f.masks[#f.masks + 1] = mask end
  load('main.lua')(); f.header = split(f.output[1])
  function f.step()
    f.movement, f.plan, f.observation = nil, nil, nil
    local old_rows = #f.output
    env.main()
    eq(#f.masks, (f.steps or 0) + 1, 'one actual sendKeys per callback')
    f.steps = (f.steps or 0) + 1
    f.row = nil
    if #f.output > old_rows then
      local values = split(f.output[#f.output]); f.row = {}
      eq(#values, #f.header, 'CSV row/header alignment')
      for index, name in ipairs(f.header) do f.row[name] = values[index] end
    end
    return f.masks[#f.masks]
  end
  return f
end
local ignored_csv = { ai_version = true, dodge_ms = true, observe_ms = true, bloom_ms = true }
local function compare(current, old, label)
  local new_mask, old_mask = current.step(), old.step(); callbacks = callbacks + 1
  eq(new_mask, old_mask, label .. ' complete input mask')
  check(not bit(new_mask, 2), label .. ' forbidden X')
  eq(current.choose_calls, old.choose_calls, label .. ' planner gating')
  eq(current.update_calls, old.update_calls, label .. ' resource gating')
  same(current.movement, old.movement, label .. '.movement', true)
  same(current.plan, old.plan, label .. '.plan', false)
  same(current.observation, old.observation, label .. '.observation', false)
  if old.state then
    check(current.state.human_movement == nil, label .. ' mech acquired human movement memory')
    same(current.state.bloom, old.state.bloom, label .. '.bloom_after_feedback', false)
    same(current.state.observer, old.state.observer, label .. '.observer_cache', false)
    -- This includes attention IDs/tokens, laser history, movement budget,
    -- round/hit counters and old log-edge state, excluding no old fields.
    for key, value in pairs(old.state) do same(current.state[key], value, label .. '.state.' .. key, false) end
  end
  eq(current.row == nil, old.row == nil, label .. ' CSV event presence')
  if old.row then
    for key, value in pairs(old.row) do
      if not ignored_csv[key] then eq(current.row[key], value, label .. '.csv.' .. key) end
    end
  end
  return new_mask
end
local function pair(ai, side, seconds)
  cases = cases + 1
  return fixture('.', ai, side, seconds), fixture(baseline, ai, side, seconds)
end
local function updateHitbox(p)
  p.hitBodyRect.x, p.hitBodyRect.y, p.hitBodyCircle.x, p.hitBodyCircle.y = p.x, p.y, p.x, p.y
end
local function drive(f, mask)
  local p, s = f.side.player, f.side.player.sensor
  if s.valid and f.side.chargeType == 0 and s.state ~= 4 and s.state ~= 5
      and not s.cutIn and s.timeScale > 0 then
    if f.movement and s.movementEnabled ~= false then
      p.x = clamp(p.x + f.movement.vx * s.timeScale, -136, 136)
      p.y = clamp(p.y + f.movement.vy * s.timeScale, 16, 432)
    end
    if bit(mask, 1) and s.canCharge then p.currentCharge = math.min(p.currentChargeMax, p.currentCharge + 10)
    elseif not bit(mask, 1) then p.currentCharge = 0 end
  end
  updateHitbox(p)
end
local function populate(f, frame)
  local side, p = f.side, f.side.player
  local s = p.sensor
  side.chargeType, s.valid, s.state = 0, true, (frame == 1 or frame == 85) and 5 or 0
  s.timeScale, s.cutIn, s.movementEnabled = 1, false, true
  s.canCharge, s.canPressZ, s.c1ActionActive = true, true, false
  s.protectionFrames, s.poisonClouds, s.moveScaleX, s.moveScaleY = 0, {}, 1, 1
  p.chargeSpeed = 10
  if frame >= 30 and frame <= 32 then s.cutIn = true end
  if frame == 33 then s.timeScale = 0 elseif frame == 34 then s.timeScale = 0.5 end
  if frame == 42 then s.movementEnabled = false end
  if frame == 55 then p.life = p.life - 2 end
  if frame >= 55 and frame <= 57 then s.state = 4 end
  if frame == 65 or frame == 66 then s.valid = false end
  if frame == 69 then p.chargeSpeed = 0 end
  if frame == 73 then side.chargeType = 1 end
  if frame == 85 then p.life, p.currentCharge = 10, 0 end
  if frame >= 95 and frame <= 102 then s.state, s.protectionFrames = 3, 103 - frame end
  if frame >= 110 and frame <= 112 then s.c1ActionActive, s.canCharge = true, false end
  p.spellPoint = frame % 45 >= 35 and 500000 + frame or 0
  side.bullets, side.enemies, side.exAttacks = {}, {}, {}
  for index = 1, 26 do
    local x, y = ((index * 37 + frame * (index % 5 - 2)) % 320) - 160,
      160 + (index * 23 + frame * (index % 4 + 1)) % 280
    local shape = index % 4 == 0 and { type = 0, x = x, y = y, width = 5, height = 9 } or nil
    side.bullets[#side.bullets + 1] = bullet(index + 100 * math.floor(frame / 43), x, y,
      index % 3 - 1, 0.75 + index % 6, shape)
  end
  local x, y = -110 + frame % 15, 260 + frame % 37
  side.bullets[#side.bullets + 1] = bullet(500, x, y, 0, 0,
    { type = 2, x = x, y = y, width = 160 + frame % 23,
      height = frame % 23 < 4 and 0 or 3, angle = frame * 0.004 })
  -- A shape outside sight must stay equally invisible in both versions.
  side.bullets[#side.bullets + 1] = bullet(501, 1000, p.y, -100, 0)
  for index = 1, 4 do
    local ex, ey = (index - 2.5) * 22, 230 + index * 12
    side.enemies[index] = { id = 700 + index, x = ex, y = ey, vx = 0, vy = 0,
      enabled = true, isSpirit = index == 4, isActivatedSpirit = frame % 30 < 10,
      isBoss = false, isLily = false, isPseudoEnemy = false,
      hitBody = { type = 1, x = ex, y = ey, radius = 4 } }
  end
  if frame % 60 >= 20 and frame % 60 <= 45 then
    s.poisonClouds = { { x = 0, y = 320, radius = 64, age = 60, framesLeft = 240, active = true },
      { x = 15, y = 335, radius = 64, age = 80, framesLeft = 220, active = true } }
    local factor = 1
    for _, cloud in ipairs(s.poisonClouds) do
      if (p.x-cloud.x)^2 + (p.y-cloud.y)^2 < cloud.radius^2 then factor = factor * 0.4 end
    end
    s.moveScaleX, s.moveScaleY = factor, factor
    side.exAttacks[1] = bullet(800, 0, 320, 0, 0, { type = 1, x = 0, y = 320, radius = 64 })
    side.exAttacks[1].type = 16
  end
  -- Deliberately unrelated opponent events must not replace the chosen side.
  f.other.player.life = frame % 10
  f.other.player.sensor.state = frame % 2 == 0 and 5 or 0
end

local configurations = {
  { difficulty = 'mech' },
  { difficulty = 'mech', enabled = true },
  { difficulty = 'mech', move_change_budget = 2, vision_radius = 42,
    attention_capacity = 3, attention_recovery_per_second = 0.2, plan_interval = 6 },
  { difficulty = 'mech', enabled = true, move_change_budget = 10, vision_radius = 640,
    attention_capacity = 256, attention_recovery_per_second = 256, plan_interval = 1 },
}
for index, ai in ipairs(configurations) do
  for selected = 1, 2 do
    local current, old = pair(ai, selected)
    for frame = 1, 144 do
      populate(current, frame); populate(old, frame)
      local label = 'mech' .. index .. '/side' .. selected .. '/frame' .. frame
      local mask = compare(current, old, label)
      if current.effective then
        if current.effective.human_movement then check(current.effective.human_movement.mech == true, label .. ' explicit mech gate') end
        eq(current.effective.attention.enabled, ai.enabled == true, label .. ' legacy enabled override')
      end
      if frame == 65 or frame == 66 or frame == 69 or frame == 73 then eq(mask, 0, label .. ' fault stops all input') end
      drive(current, mask); drive(old, old.masks[#old.masks])
      eq(current.side.player.x, old.side.player.x, label .. ' closed-loop x')
      eq(current.side.player.y, old.side.player.y, label .. ' closed-loop y')
    end
    eq(current.state.round_id, 2, 'initialization really exercised round reset')
    eq(current.state.hits_total, 1, 'damage really exercised hit handling')
  end
end

-- A funded blocked scene exercises the rescue branch, actual charge reset,
-- native protection confirmation and recovery; equality cannot pass solely on
-- calm movement with no resource actions.
do
  local current, old = pair({ difficulty = 'mech' }, 2)
  local released, confirmed = false, false
  for frame = 1, 22 do
    for _, f in ipairs({ current, old }) do
      local p, s = f.side.player, f.side.player.sensor
      p.currentCharge = frame == 5 and 190 or (frame == 6 and 200 or 0)
      s.state = frame >= 7 and frame <= 14 and 3 or 0
      s.protectionFrames = s.state == 3 and 30 - frame or 0
      s.canCharge = s.state ~= 3
      s.c1ActionActive, s.c1ActionAge, s.canPressZ = s.state == 3, math.max(0, frame - 6), s.state ~= 3
      p.currentChargeMax = frame >= 7 and 100 or 300
      f.side.bullets = frame <= 6 and { bullet(900, p.x, p.y, 0, 0,
        { type = 1, x = p.x, y = p.y, radius = 20 }) } or {}
    end
    compare(current, old, 'rescue/frame' .. frame)
    released = released or current.plan.release_c2 > 0
    confirmed = confirmed or current.bloom.rescue_confirmed == true
  end
  check(released, 'fixture did not request a real C2 release')
  check(confirmed, 'fixture did not exercise native C2 confirmation')
end

-- Ordinary deadline C1 remains reachable independently of defensive C2.
do
  local current, old = pair({ difficulty = 'mech' }, 2)
  current.side.player.currentChargeMax, old.side.player.currentChargeMax = 100, 100
  local released = false
  for frame = 1, 510 do
    local mask = compare(current, old, 'c1-cadence/frame' .. frame)
    released = released or current.plan.release_c1 > 0
    eq(current.plan.release_c2, 0, 'C1-only stock cannot request C2')
    drive(current, mask); drive(old, old.masks[#old.masks])
  end
  check(released, 'fixture did not exercise ordinary deadline C1')
end

-- Global timeout keeps every key released even if a later round appears.
do
  local current, old = pair({ difficulty = 'mech', enabled = true }, 1, 1)
  for frame = 1, 68 do
    for _, f in ipairs({ current, old }) do f.side.player.sensor.state = (frame == 30 or frame > 62) and 5 or 0 end
    local mask = compare(current, old, 'timeout/frame' .. frame)
    if frame > 60 then eq(mask, 0, 'timeout must remain latched across initialization') end
  end
  eq(current.choose_calls, 60, 'time limit grants exactly sixty planner callbacks')
end

-- A named human tier with attention explicitly disabled is still human style.
-- Exercise reset call sites through real main instead of calling resetHuman
-- directly or constructing the planner's internal memory by hand.
local legacy_header = fixture(baseline, { difficulty = 'mech' }, 2).header
local human_columns = { 'human_enabled', 'human_pressure', 'human_slow',
  'human_speed_held', 'human_speed_override', 'human_lane_cost' }
local function humanStep(f, label)
  human_callbacks = human_callbacks + 1
  local mask = f.step()
  eq(#f.header, #legacy_header + #human_columns + 8, label .. ' appended CSV width')
  for index, name in ipairs(legacy_header) do eq(f.header[index], name, label .. ' CSV prefix ' .. index) end
  for index, name in ipairs(human_columns) do
    eq(f.header[#legacy_header + index], name, label .. ' appended CSV name ' .. index)
    if f.row then
      local value = f.movement[name]
      if name == 'human_pressure' or name == 'human_lane_cost' then value = value or 0
      else value = value == true end
      eq(f.row[name], tostring(value), label .. ' live diagnostic ' .. name)
    end
  end
  check(not bit(mask, 2), label .. ' forbidden X')
  return mask
end
local function denseHuman(f)
  f.side.player.currentCharge, f.side.player.currentChargeMax = 0, 0
  f.side.bullets = {}
  for index = 1, 100 do
    f.side.bullets[index] = bullet(index, (index % 17 - 8) * 4, 280 + (index % 6) * 2, 0, -0.5)
  end
end
local function prepareHuman(f, label)
  for frame = 1, 20 do humanStep(f, label .. '/prepare' .. frame) end
  check(f.state.human_movement and f.state.human_movement.slow, label .. ' no real accumulated slow state')
  check(f.movement.human_enabled and f.movement.human_slow, label .. ' style not active')
  return f.state.human_movement
end
local function freshHuman(f, prior, label)
  humanStep(f, label)
  check(f.state.human_movement ~= nil and f.state.human_movement ~= prior, label .. ' old human memory survived')
  check(not f.state.human_movement.slow, label .. ' stale slow intent survived reset')
  eq(f.state.human_movement.enter_age, 1, label .. ' must start with one fresh dense observation')
end
for _, ai in ipairs({ { difficulty = 'human200', enabled = false },
    { difficulty = 'custom', enabled = false }, { difficulty = 'infinite', enabled = false },
    { difficulty = 'unlimited' } }) do
  cases = cases + 1
  local f, label = fixture('.', ai, 2), ai.difficulty .. '/main-reset'
  denseHuman(f)
  local previous = prepareHuman(f, label)
  eq(f.effective.human_movement.mech, false, label .. ' non-mech falsely bypassed')
  eq(f.effective.attention.enabled, ai.enabled ~= false, label .. ' explicit attention setting')
  eq(f.row.human_enabled, 'true', label .. ' style reported disabled')
  if ai.enabled == false then eq(f.row.attention_enabled, 'false', label .. ' attention silently re-enabled') end

  f.side.player.sensor.valid = false
  eq(humanStep(f, label .. '/sensor-fault'), 0, label .. ' sensor fault must stop keys')
  check(f.state.human_movement == nil and f.row == nil, label .. ' sensor fault retained style or planning row')
  f.side.player.sensor.valid = true; freshHuman(f, previous, label .. '/sensor-recovery')

  previous = prepareHuman(f, label)
  f.side.chargeType = 1
  eq(humanStep(f, label .. '/charge-fault'), 0, label .. ' Charge layout must stop keys')
  check(f.state.human_movement == nil and f.row == nil, label .. ' Charge fault retained style or planning row')
  f.side.chargeType = 0; freshHuman(f, previous, label .. '/charge-recovery')

  previous = prepareHuman(f, label)
  f.side.player.life = f.side.player.life - 1
  freshHuman(f, previous, label .. '/hit')
  check(f.state.hit and f.state.hits_total == 1, label .. ' fixture failed to register real health decrease')

  previous = prepareHuman(f, label)
  local previous_state, previous_round = f.state, f.state.round_id
  f.side.player.sensor.state = 5
  humanStep(f, label .. '/new-round')
  check(f.state ~= previous_state and f.state.round_id == previous_round + 1, label .. ' real main did not replace round state')
  check(f.state.human_movement == nil and not f.movement.human_enabled, label .. ' initializing round retained style')
  f.side.player.sensor.state = 0; freshHuman(f, previous, label .. '/new-round-playing')

  for _, mode in ipairs({ 'cutIn', 'timeScale', 'movementEnabled' }) do
    previous = prepareHuman(f, label)
    if mode == 'cutIn' then f.side.player.sensor.cutIn = true
    elseif mode == 'timeScale' then f.side.player.sensor.timeScale = 0
    else f.side.player.sensor.movementEnabled = false end
    humanStep(f, label .. '/freeze-' .. mode)
    check(f.state.human_movement == nil and not f.movement.human_enabled, label .. ' freeze retained style ' .. mode)
    if mode == 'cutIn' then f.side.player.sensor.cutIn = false
    elseif mode == 'timeScale' then f.side.player.sensor.timeScale = 1
    else f.side.player.sensor.movementEnabled = true end
    freshHuman(f, previous, label .. '/resume-' .. mode)
  end
end
do
  cases = cases + 1
  local f = fixture('.', { difficulty = 'human200', enabled = false }, 2, 1)
  denseHuman(f); prepareHuman(f, 'human-timeout')
  for frame = 21, 65 do
    local mask = humanStep(f, 'human-timeout/' .. frame)
    if frame > 60 then
      eq(mask, 0, 'human timeout releases all input')
      check(f.state.human_movement == nil, 'human timeout clears speed and pressure memory')
    end
  end
end
print(string.format('human_mech_integration_test: PASS (%d scenarios, %d paired mech callbacks, %d human callbacks, %d checks; baseline=%s)',
  cases, callbacks, human_callbacks, checks, baseline))
