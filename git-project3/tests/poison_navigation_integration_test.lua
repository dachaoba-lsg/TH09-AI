-- 3.9 no-poison behavior must retain complete 3.8 decisions at every difficulty.
-- Two isolated Lua 5.1 environments receive independent copies of each fixture.
-- The small feedback driver is NOT an emulation of TH09 charge/damage physics.
-- Run from the project root with tests/run_native_lua.py. Optional environment:
-- TH09_POISON_AI_BASELINE = directory containing the unchanged 3.8 main.lua.
local real_loadfile, real_open = loadfile, io.open
local baseline = os and os.getenv and os.getenv('TH09_POISON_AI_BASELINE')
if not baseline or baseline == '' then baseline = '../../work/before-poison-navigation-3.9.0/src/ai' end
baseline = baseline:gsub('\\', '/'):gsub('/$', '')
local probe = real_open(baseline .. '/main.lua', 'rb')
if not probe then
  print('poison_navigation_integration_test: SKIP (3.8 baseline missing; set TH09_POISON_AI_BASELINE)')
  return
end

probe:close()

local checks, cases, callbacks, poison_callbacks = 0, 0, 0, 0
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
-- Only additive poison navigation diagnostics may be absent from the old result.
-- Every original field, including rescue evidence and nested trajectories,
-- remains exact. No numeric tolerance hides different planning decisions.
local function same(actual, expected, path, allow_poison)
  eq(type(actual), type(expected), path .. ' type')
  if type(expected) ~= 'table' then eq(actual, expected, path); return end
  for key, value in pairs(expected) do same(actual[key], value, path .. '.' .. tostring(key), allow_poison) end
  for key in pairs(actual) do
    check(expected[key] ~= nil or (allow_poison and type(key) == 'string' and key:match('^poison_')),
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
local function fixture(root, ai, selected, seconds, disable_poison)
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
      module.debug_log, module.debug_log_interval_frames = true, 1; f.config = module
      if disable_poison and module.dodge.poison_navigation then module.dodge.poison_navigation.enabled = false end
    elseif path == 'dodge.lua' then
      f.dodge = module
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
    check(current.state.poison_navigation == nil, label .. ' no-poison scene acquired navigation memory')
    same(current.state.bloom, old.state.bloom, label .. '.bloom_after_feedback', false)
    same(current.state.observer, old.state.observer, label .. '.observer_cache', false)
    -- This includes attention IDs/tokens, laser history, movement budget,
    -- round/hit counters and old log-edge state, excluding no old fields.
    for key, value in pairs(old.state) do same(current.state[key], value, label .. '.state.' .. key, false) end
    for key in pairs(current.state) do
      check(old.state[key] ~= nil or key:match('^poison_') or key:match('^last_debug_poison_'), label .. ' unexpected old-state change ' .. key)
    end
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

-- Each named difficulty keeps its existing complete behavior in poison-free
-- input. Explicit attention switches remain independent of the difficulty.
local tiers = { 'mech', 'human45', 'human90', 'human120', 'human150', 'human180',
  'human200', 'human240', 'human300', 'human480', 'unlimited', 'custom', 'infinite' }
local configurations = {}
for _, tier in ipairs(tiers) do configurations[#configurations + 1] = { difficulty = tier } end
configurations[#configurations + 1] = { difficulty = 'mech', enabled = true,
  move_change_budget = 2, vision_radius = 42, attention_capacity = 3, attention_recovery_per_second = 0.2 }
configurations[#configurations + 1] = { difficulty = 'human300', enabled = false,
  move_change_budget = 10, vision_radius = 640, attention_capacity = 256, attention_recovery_per_second = 256 }
for index, ai in ipairs(configurations) do
  local current, old = pair(ai, index % 2 + 1)
  for frame = 1, 120 do
    for _, f in ipairs({ current, old }) do
      populate(f, frame)
      f.side.player.sensor.poisonClouds = {}
      f.side.player.sensor.moveScaleX, f.side.player.sensor.moveScaleY = 1, 1
      f.side.exAttacks = {}
      if frame % 3 == 0 then
        -- Identical raw hidden terrain in both versions must remain absent
        -- from planning even for the largest public view radius.
        f.side.player.sensor.poisonClouds = {
          { x=1000,y=320,radius=64,age=60,framesLeft=240,active=true } }
      end
    end
    local label = 'no-poison/' .. index .. '/' .. frame
    local mask = compare(current, old, label)
    drive(current, mask); drive(old, old.masks[#old.masks])
    eq(current.side.player.x, old.side.player.x, label .. ' closed-loop x')
    eq(current.side.player.y, old.side.player.y, label .. ' closed-loop y')
  end
  eq(current.state.round_id, 2, 'no-poison fixture exercised a new round')
  eq(current.state.hits_total, 1, 'no-poison fixture exercised real health decrease')
end

-- No C-policy/observer/input-map implementation is part of this feature.
for _, name in ipairs({ 'bloom.lua', 'bloom_observer.lua', 'keyutils.lua' }) do
  local a = assert(real_open(name, 'rb')); local current = a:read('*a'); a:close()
  local b = assert(real_open(baseline .. '/' .. name, 'rb')); local old = b:read('*a'); b:close()
  eq(current, old, 'unchanged resource/input source ' .. name)
end

local poison_columns = { 'poison_nav_active', 'poison_level', 'poison_risk',
  'poison_target_x', 'poison_target_y', 'poison_probe_count', 'poison_nav_samples', 'poison_cost' }
local legacy_header = fixture(baseline, { difficulty = 'mech' }, 2).header
local function poisonStep(f, label)
  poison_callbacks = poison_callbacks + 1
  local mask = f.step()
  eq(#f.header, #legacy_header + #poison_columns, label .. ' append-only CSV width')
  for index, name in ipairs(legacy_header) do eq(f.header[index], name, label .. ' CSV prefix ' .. index) end
  for index, name in ipairs(poison_columns) do
    eq(f.header[#legacy_header + index], name, label .. ' new CSV column ' .. index)
    if f.row then eq(f.row[name], tostring(f.movement[name] or 0), label .. ' live CSV ' .. name) end
  end
  check(not bit(mask, 2), label .. ' forbidden X')
  return mask
end
local function clouds(side, count, x, y)
  local p, sensor = side.player, side.player.sensor
  sensor.poisonClouds = {}
  for index = 1, count do sensor.poisonClouds[index] = {
    x = x or p.x, y = y or p.y, radius = 64, age = 60 + index, framesLeft = 240 - index, active = true } end
  local factor = 1
  for _, cloud in ipairs(sensor.poisonClouds) do
    if (p.x - cloud.x)^2 + (p.y - cloud.y)^2 < cloud.radius^2 then factor = factor * 0.4 end
  end
  sensor.moveScaleX, sensor.moveScaleY = factor, factor
end
local function updateClouds(side)
  local p, sensor = side.player, side.player.sensor
  local factor = 1
  for _, cloud in ipairs(sensor.poisonClouds) do
    cloud.age, cloud.framesLeft = cloud.age + 1, cloud.framesLeft - 1
    if cloud.age > 20 and cloud.framesLeft > 0 and (p.x-cloud.x)^2+(p.y-cloud.y)^2 < cloud.radius^2 then factor = factor * 0.4 end
  end
  sensor.moveScaleX, sensor.moveScaleY = factor, factor
end
local function targetBounds(f, label)
  local memory = f.state and f.state.poison_navigation
  if memory and memory.target_x then
    local p, radius = f.side.player, f.effective.vision_radius
    check((memory.target_x-p.x)^2+(memory.target_y-p.y)^2 <= radius^2 + 1e-7, label .. ' target exceeds current circle')
    check(memory.target_y >= math.min(p.y, f.config.bloom.min_y), label .. ' target violates movement height')
  end
end
for _, ai in ipairs(configurations) do
  cases = cases + 1
  local f, disabled = fixture('.', ai, 2), fixture('.', ai, 2, 0, true)
  f.side.player.currentChargeMax, disabled.side.player.currentChargeMax = 0, 0
  clouds(f.side, 2); clouds(disabled.side, 2)
  local label = 'all-difficulties/' .. ai.difficulty .. '/' .. tostring(ai.enabled)
  local mask = poisonStep(f, label)
  disabled.step()
  check(f.movement.poison_nav_active > 0 and f.state.poison_navigation, label .. ' navigation inactive')
  check(f.movement.vx ~= 0 or f.movement.vy ~= 0, label .. ' no actual movement from dense poison centre')
  check(disabled.movement.vx == 0 and disabled.movement.vy == 0, label .. ' comparison was not the former idle case')
  eq(f.plan.press_z, disabled.plan.press_z, label .. ' poison must not directly trigger Z')
  eq(f.plan.target_level, disabled.plan.target_level, label .. ' poison must not choose C level')
  local start_risk = f.movement.poison_risk
  for frame = 1, 32 do
    targetBounds(f, label)
    if ai.difficulty == 'mech' then check(f.state.human_movement == nil, label .. ' mech gained human style') end
    check(not f.movement.collides, label .. ' harmless poison became a hard hit')
    check(math.sqrt(f.movement.vx^2 + f.movement.vy^2) <= 4 * 0.16 + 1e-7, label .. ' poison speed was bypassed')
    drive(f, mask); updateClouds(f.side)
    mask = poisonStep(f, label .. '/' .. frame)
  end
  check(f.side.player.x^2 + (f.side.player.y-320)^2 > 25, label .. ' selected movement did not make real progress')
  check(f.movement.poison_risk < start_risk, label .. ' movement did not lower local poison risk')
end

-- The raw world may contain a cloud that neither movement nor C is allowed
-- to see. Such a cloud cannot change navigation, keys or old policy state.
do
  cases = cases + 1
  local a, b = fixture('.', { difficulty = 'mech', vision_radius = 42 }, 2),
    fixture('.', { difficulty = 'mech', vision_radius = 42 }, 2)
  clouds(a.side, 1, 200, 320)
  for frame = 1, 20 do
    local ka, kb = poisonStep(a, 'hidden-cloud/' .. frame), b.step()
    eq(ka, kb, 'hidden cloud cannot change complete input')
    same(a.movement, b.movement, 'hidden-cloud movement', false)
    same(a.plan, b.plan, 'hidden-cloud C decision', false)
    check(a.state.poison_navigation == nil and a.movement.poison_nav_active == 0, 'hidden cloud created target')
    eq(a.row.vision_hidden_poison, '1', 'fixture must actually hide one current cloud')
  end
end

-- Score identical poisoned snapshots in real main with navigation on/off.
-- Do not mutate stock, life, geometry, attention or existing style settings to
-- manufacture a wider safety allowance for the new terrain preference.
for scene = 1, 45 do
  cases = cases + 1
  local ai = { difficulty = scene % 3 == 0 and 'mech' or 'unlimited' }
  local current, disabled = fixture('.', ai, 2), fixture('.', ai, 2, 0, true)
  for _, f in ipairs({ current, disabled }) do
    f.side.player.x = ((scene * 29) % 180) - 90
    f.side.player.y = scene % 5 == 0 and 150 or 270 + scene % 100
    updateHitbox(f.side.player); f.side.player.currentChargeMax = 0
    clouds(f.side, 1, f.side.player.x + scene % 20 - 10, f.side.player.y)
    for index = 1, 16 do
      local x = f.side.player.x + ((scene * 11 + index * 23) % 150) - 75
      local y = f.side.player.y + ((scene * 19 + index * 17) % 100) - 50
      f.side.bullets[index] = bullet(index, x, y, (index % 5 - 2) * 0.4, 0.5 + index % 4)
    end
  end
  poisonStep(current, 'risk-gates/' .. scene); disabled.step()
  local a, b = current.movement, disabled.movement
  if not b.collides then check(not a.collides, 'poison preference purchased a collision in scene ' .. scene) end
  check(a.danger <= b.danger + 1e-7, 'poison preference increased existing near-risk in scene ' .. scene)
  check(a.terrain_cost <= b.terrain_cost + 1e-7, 'poison preference increased wall exposure in scene ' .. scene)
  if a.collides and b.collides then eq(a.key, b.key, 'all-colliding field preserves old escape ordering') end
  check(current.side.player.y + a.vy >= 150 - 1e-7, 'poison preference crossed height boundary')
  same(current.config.bloom, disabled.config.bloom, 'unchanged C configuration')
  same(current.observation, disabled.observation, 'same limited observer snapshot')
  same(current.plan, disabled.plan, 'no direct poison control over current C plan')
end

-- The direction cap is an actual selectable-pool restriction even when the
-- low-poison exit points in a different direction.
do
  cases = cases + 1
  local f = fixture('.', { difficulty = 'mech', move_change_budget = 1 }, 2)
  f.side.player.currentChargeMax = 0
  f.side.bullets = {
    bullet(1, 0, 310, 0, 0, { type=0, x=0, y=310, width=240, height=2 }),
    bullet(2, 0, 330, 0, 0, { type=0, x=0, y=330, width=240, height=2 }),
    bullet(3, -20, 320, 2, 0, { type=0, x=-20, y=320, width=4, height=40 }) }
  poisonStep(f, 'direction-cap/start')
  check(f.movement.vx > 0 and f.movement.vy == 0, 'cap fixture must establish actual rightward choice')
  clouds(f.side, 1, 30, 320)
  for frame = 1, 4 do
    poisonStep(f, 'direction-cap/' .. frame)
    eq(f.movement.rescue_routes_total, 2, 'direction dwell must restrict to its fast/slow pair')
    check(f.movement.vx > 0 and f.movement.vy == 0, 'poison escape bypassed direction cap')
  end
end

-- Confirmed post-C2 endpoint safety retains the 3.8 resource-suppression gate.
-- This uses real dodge after normal main has resolved the selected difficulty.
for _, tier in ipairs({ 'mech', 'unlimited' }) do
  cases = cases + 1
  local f, disabled = fixture('.', { difficulty=tier }, 2), fixture('.', { difficulty=tier }, 2, 0, true)
  f.step(); disabled.step()
  local side = world(); side.player.sensor.state, side.player.sensor.protectionFrames = 3, 48
  clouds(side, 1)
  side.bullets = { bullet(9,0,320,0,0,{type=0,x=0,y=320,width=500,height=500}) }
  local intent = { protected_followup=true,min_y=150,focus=false,target_x=100,target_y=320,
    position_weight=0.002,focus_mismatch_cost=8 }
  local a = f.dodge.choose(copy(side), {}, f.effective, copy(intent))
  local b = disabled.dodge.choose(copy(side), {}, disabled.effective, copy(intent))
  check(a.protected_route_checked and not a.protected_route_safe and a.protected_route_collides,
    'all covered protection endpoints must remain unsafe ' .. tier)
  eq(a.key,b.key,'poison cannot replace rejected protection escape ' .. tier)
  eq(a.intent_cost,0,'poison cannot resurrect rejected resource intent ' .. tier)
end

-- A new poisoned terrain preference cannot erase an already established
-- low-speed decision or repeatedly flip Shift under the 3.8 speed hold.
do
  cases = cases + 1
  local ai = { difficulty='unlimited',enabled=false }
  local f, disabled = fixture('.',ai,2), fixture('.',ai,2,0,true)
  for _, instance in ipairs({f,disabled}) do
    instance.side.player.currentChargeMax=0
    for index=1,100 do instance.side.bullets[index]=bullet(index,(index%17-8)*4,280+(index%6)*2,0,-0.5) end
  end
  for frame=1,20 do f.step();disabled.step() end
  check(f.movement.focus and disabled.movement.focus and f.state.human_movement.slow,'real high pressure failed to establish slow mode')
  clouds(f.side,1);clouds(disabled.side,1)
  for frame=1,10 do
    poisonStep(f,'human-speed-hold/'..frame);disabled.step()
    eq(f.movement.focus,disabled.movement.focus,'poison changed existing 3.8 speed choice')
    check(f.movement.focus and f.state.human_movement.slow,'poison canceled high-pressure low speed')
    eq(f.movement.human_speed_held,disabled.movement.human_speed_held,'poison reset the speed hold')
    eq(f.state.human_movement.hold_age,disabled.state.human_movement.hold_age,'poison changed speed timer')
  end
end

-- Main lifecycle failures discard navigation targets and reacquire from the
-- current cloud snapshot. No test writes an artificial navigation memory.
do
  cases = cases + 1
  local f = fixture('.',{difficulty='mech'},2)
  f.side.player.currentChargeMax=0;clouds(f.side,2)
  local function prepared(label)
    poisonStep(f,label)
    check(f.state.poison_navigation and f.state.poison_navigation.target_x,'real cloud fixture created no target')
    return f.state.poison_navigation
  end
  local previous=prepared('lifecycle/start')
  f.side.player.sensor.valid=false
  eq(poisonStep(f,'lifecycle/sensor-fault'),0,'sensor fault stops all keys')
  check(f.state.poison_navigation==nil,'sensor fault retained navigation cache')
  f.side.player.sensor.valid=true;check(prepared('lifecycle/sensor-resume')~=previous,'sensor resume reused stale target memory')
  previous=f.state.poison_navigation;f.side.chargeType=1
  eq(poisonStep(f,'lifecycle/charge-fault'),0,'Charge fault stops all keys')
  check(f.state.poison_navigation==nil,'Charge fault retained navigation cache')
  f.side.chargeType=0;check(prepared('lifecycle/charge-resume')~=previous,'Charge resume reused stale target memory')
  previous=f.state.poison_navigation;f.side.player.life=9
  check(prepared('lifecycle/hit')~=previous and f.state.hit,'hit retained old target or failed to register')
  previous=f.state.poison_navigation;f.side.player.sensor.state=5
  poisonStep(f,'lifecycle/new-round');check(f.state.poison_navigation==nil,'initialization retained target')
  f.side.player.sensor.state=0;check(prepared('lifecycle/new-round-playing')~=previous,'new round reused old memory')
  for _, name in ipairs({'cutIn','timeScale','movementEnabled'}) do
    previous=f.state.poison_navigation
    if name=='cutIn' then f.side.player.sensor.cutIn=true
    elseif name=='timeScale' then f.side.player.sensor.timeScale=0
    else f.side.player.sensor.movementEnabled=false end
    poisonStep(f,'lifecycle/freeze-'..name);check(f.state.poison_navigation==nil,'inactive snapshot retained target '..name)
    if name=='cutIn' then f.side.player.sensor.cutIn=false
    elseif name=='timeScale' then f.side.player.sensor.timeScale=1
    else f.side.player.sensor.movementEnabled=true end
    check(prepared('lifecycle/resume-'..name)~=previous,'resume reused stale target '..name)
  end
  f.side.player.sensor.poisonClouds={};f.side.player.sensor.moveScaleX=1;f.side.player.sensor.moveScaleY=1
  poisonStep(f,'lifecycle/cloud-removed')
  check(f.state.poison_navigation==nil and f.movement.poison_nav_active==0,'removed cloud left stale terrain steering')
end

-- A cached exit is not an authorization to keep steering through a newly
-- poisoned destination, nor to remember a destination outside today's view.
do
  cases = cases + 1
  local f = fixture('.', {difficulty='mech'}, 2)
  f.side.player.currentChargeMax=0;clouds(f.side,2)
  poisonStep(f,'cache/new-poison/start')
  local previous=f.state.poison_navigation
  check(previous and previous.target_x,'new-poison cache fixture has no target')
  local tx,ty,plan_frame=previous.target_x,previous.target_y,previous.plan_frame
  for index=1,6 do
    f.side.player.sensor.poisonClouds[#f.side.player.sensor.poisonClouds+1]={
      x=tx,y=ty,radius=64,age=100,framesLeft=180,active=true }
  end
  poisonStep(f,'cache/new-poison/replan')
  local memory=f.state.poison_navigation
  check(memory~=previous and memory.plan_frame>plan_frame,'new target poison waited for periodic replanning')
  check(not memory.target_x or (memory.target_x-tx)^2+(memory.target_y-ty)^2>1,
    'newly dense old target survived hysteresis')
  targetBounds(f,'new-poison replacement')
end
do
  cases = cases + 1
  local f = fixture('.', {difficulty='mech'}, 2)
  f.side.player.currentChargeMax=0;clouds(f.side,2)
  poisonStep(f,'cache/moving-circle/start')
  local previous=f.state.poison_navigation
  check(previous and previous.target_x,'moving-circle fixture has no target')
  local tx,ty,plan_frame=previous.target_x,previous.target_y,previous.plan_frame
  local p=f.side.player
  p.x=tx<0 and 55 or -55;updateHitbox(p)
  check((tx-p.x)^2+(ty-p.y)^2>f.effective.vision_radius^2,'old target did not actually leave the current circle')
  check(p.x^2+(p.y-320)^2<64^2,'player must still be in original poison')
  poisonStep(f,'cache/moving-circle/replan')
  local memory=f.state.poison_navigation
  check(memory~=previous and memory.plan_frame>plan_frame,'current-circle invalidation waited for cadence or 64-unit relocation')
  check(not memory.target_x or (memory.target_x-tx)^2+(memory.target_y-ty)^2>1,'out-of-view target survived cache validation')
  targetBounds(f,'moving-circle replacement')
end
print(string.format('poison_navigation_integration_test: PASS (%d scenarios, %d paired no-poison main callbacks, %d poison main callbacks, %d checks; baseline=%s)',
  cases,callbacks,poison_callbacks,checks,baseline))
