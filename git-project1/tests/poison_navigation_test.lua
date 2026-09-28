-- v0.1.9.2 synthetic navigation regression. No game process or input.
-- Run from the project root: python tests/run_native_lua.py tests/poison_navigation_test.lua
-- The physical rollout below is independent of dodge's predicted segments.
HitType = { Rect = 0, Circle = 1, RotatableRect = 2 }
ExAttackType = { Medicine = 16, Eiki = 19, Reimu = 0 }
local dodge = dofile("dodge.lua")
local abs, sqrt, floor = math.abs, math.sqrt, math.floor
local old_path = "../../work/before-0192-20260928-100137/src/ai/dodge.lua"
local old_file = io.open(old_path, "r")
local baseline
if old_file then old_file:close(); baseline = dofile(old_path) end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}; for k, v in pairs(value) do result[k] = copy(v) end
  return result
end
local function config()
  local cfg = dofile("config.lua").dodge
  assert(cfg.poison_navigation and cfg.poison_navigation.enabled,
    "release defaults must enable poison navigation")
  return cfg
end
local function cloud(x, y, age)
  age = age or 21
  return { x = x or 0, y = y or 320, radius = 64, age = age,
    ageInt = floor(age), active = floor(age) > 20 and floor(age) < 300,
    framesLeft = 300 - age }
end
local function layers(n, x, y, age)
  local result = {}; for i = 1, n do result[i] = cloud(x, y, age) end
  return result
end
local function world(clouds, x, y)
  x, y = x or 0, y or 320
  return { player = { x = x, y = y, speedFast = 4, speedSlow = 2,
    hitBodyRect = { type = HitType.Rect, x = x, y = y, width = 4, height = 4 },
    hitBodyCircle = { type = HitType.Circle, x = x, y = y, radius = 2 },
    sensor = { apiVersion = 1, valid = true, state = 0, protectionFrames = 0,
      canCharge = true, movementEnabled = true, timeScale = 1, cutIn = false,
      baseScaleX = 1, baseScaleY = 1, moveScaleX = 1, moveScaleY = 1,
      poisonClouds = clouds or {} } }, bullets = {}, enemies = {}, exAttacks = {} }
end
local function dose(w, x, y)
  local p, count = w.player, 0
  x, y = x or p.x, y or p.y
  for _, c in ipairs(p.sensor.poisonClouds) do
    local dx, dy = x - c.x, y - c.y
    if floor(c.age) > 20 and floor(c.age) < 300 and dx * dx + dy * dy < c.radius * c.radius then
      count = count + 1
    end
  end
  return count
end
local function refresh(w)
  local p = w.player
  local factor = 0.4 ^ dose(w)
  p.sensor.moveScaleX = p.sensor.baseScaleX * factor
  p.sensor.moveScaleY = p.sensor.baseScaleY * factor
  p.hitBodyRect.x, p.hitBodyRect.y = p.x, p.y
  p.hitBodyCircle.x, p.hitBodyCircle.y = p.x, p.y
  for _, c in ipairs(p.sensor.poisonClouds) do
    c.ageInt, c.framesLeft = floor(c.age), 300 - c.age
    c.active = c.ageInt > 20 and c.ageInt < 300
  end
end
local function bit(key, mask) return floor(key / mask) % 2 end
local function velocity(w, key)
  local p = w.player
  local dx, dy = bit(key, 128) - bit(key, 64), bit(key, 32) - bit(key, 16)
  local speed = bit(key, 4) == 1 and p.speedSlow or p.speedFast
  if dx ~= 0 and dy ~= 0 then speed = speed / sqrt(2) end
  return dx * speed * p.sensor.moveScaleX, dy * speed * p.sensor.moveScaleY
end
local function near(actual, expected, label)
  assert(abs(actual - expected) < 1e-7,
    (label or "number") .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
end
local function advance(w, choice, cfg)
  local p, field = w.player, cfg.field
  local vx, vy = velocity(w, choice.key)
  near(choice.vx, vx, "first-frame actual X velocity")
  near(choice.vy, vy, "first-frame actual Y velocity")
  local x = math.max(field.min_x, math.min(field.max_x, p.x + vx))
  local y = math.max(field.min_y, math.min(field.max_y, p.y + vy))
  local distance = sqrt((x - p.x)^2 + (y - p.y)^2)
  p.x, p.y = x, y
  for _, c in ipairs(p.sensor.poisonClouds) do c.age = c.age + 1 end
  for _, b in ipairs(w.bullets) do
    b.hitBody.x, b.hitBody.y = b.hitBody.x + (b.vx or 0), b.hitBody.y + (b.vy or 0)
  end
  if p.sensor.state == 3 then p.sensor.protectionFrames = math.max(0, p.sensor.protectionFrames - 1) end
  refresh(w)
  return distance
end
local function rollout(w, frames, cfg, implementation)
  local state, distance, exposure, moving, slow, reversals = {}, 0, 0, 0, 0, 0
  local initial_x, initial_y = w.player.x, w.player.y
  local first_escape, last_dx, last_dy, first, last, min_radius = nil, 0, 0, nil, nil, math.huge
  refresh(w)
  for frame = 1, frames do
    state.frame = frame
    local result = (implementation or dodge).choose(w, state, cfg)
    first, last = first or result, result
    exposure = exposure + dose(w)
    local vx, vy = velocity(w, result.key)
    if vx ~= 0 or vy ~= 0 then
      moving = moving + 1
      if bit(result.key, 4) == 1 then slow = slow + 1 end
      if vx * last_dx + vy * last_dy < -1e-8 then reversals = reversals + 1 end
      last_dx, last_dy = vx, vy
    end
    distance = distance + advance(w, result, cfg)
    local radius = sqrt((w.player.x - initial_x)^2 + (w.player.y - initial_y)^2)
    if frame > 1 then min_radius = math.min(min_radius, radius) end
    assert(w.player.x >= cfg.field.min_x and w.player.x <= cfg.field.max_x
      and w.player.y >= cfg.field.min_y and w.player.y <= cfg.field.max_y, "left field")
    if dose(w) == 0 and not first_escape then first_escape = frame end
  end
  local displacement = sqrt((w.player.x - initial_x)^2 + (w.player.y - initial_y)^2)
  return { world = w, distance = distance, displacement = displacement, exposure = exposure,
    moving = moving, slow = slow, reversals = reversals, escape = first_escape,
    first = first, last = last }
end
local function rect(x, y, vx, vy, width, height)
  return { vx = vx or 0, vy = vy or 0,
    hitBody = { type = HitType.Rect, x = x, y = y, width = width or 4, height = height or 4 } }
end
local passed, failures = 0, {}
local function test(name, fn)
  local ok, error_message = pcall(fn)
  if ok then passed = passed + 1; print("PASS " .. name)
  else failures[#failures + 1] = name .. ": " .. tostring(error_message); print("FAIL " .. failures[#failures]) end
end

test("zero poison preserves v0.1.9 choices and geometry", function()
  local cfg = config()
  for i = 0, 19 do
    local w = world({}, (i % 5 - 2) * 42, 100 + (i % 4) * 90)
    if i > 0 then
      for j = 1, i * 3 do
        w.bullets[j] = rect((j * 37) % 240 - 120, (j * 53) % 390 + 24,
          math.sin(j) * 2, 1 + j % 4, 4 + j % 5, 4 + j % 3)
      end
    end
    refresh(w)
    local disabled = copy(cfg); disabled.poison_navigation.enabled = false
    local old = (baseline or dodge).choose(copy(w), { last_move_key = 64 }, disabled)
    local new = dodge.choose(copy(w), { last_move_key = 64 }, cfg)
    assert(new.key == old.key and new.collides == old.collides, "no-poison choice changed in fixture " .. i)
    near(new.danger, old.danger, "no-poison danger")
    near(new.cost, old.cost, "no-poison cost")
    assert(new.movement_segments == old.movement_segments, "no-poison geometry changed")
    assert((new.poison_nav_active or 0) == 0, "empty screen has a terrain goal")
  end
end)

test("disabled navigation retains poisoned v0.1.9 behavior", function()
  local cfg = config(); cfg.poison_navigation.enabled = false
  local w = world(layers(3)); refresh(w)
  local r = dodge.choose(w, {}, cfg)
  assert(r.key == 0, "disabled navigation moved on empty concentric terrain")
  if baseline then near(r.cost, baseline.choose(copy(w), {}, cfg).cost) end
end)

for _, n in ipairs({ 1, 3 }) do
  test(n .. " central layers: actual escape before expiry and less exposure", function()
    local cfg = config()
    local new = rollout(world(layers(n)), 270, cfg)
    local oldcfg = copy(cfg); oldcfg.poison_navigation.enabled = false
    local old = rollout(world(layers(n)), 270, oldcfg, baseline or dodge)
    assert(new.first.key ~= 0, "camped at the cloud centre")
    assert(new.escape and new.escape < 270, "did not physically exit before finite clouds expired")
    assert(new.exposure < old.exposure, "no cumulative exposure improvement")
    assert(new.reversals <= 3, "escaped by excessive direction reversal")
    print(string.format("  %d layer(s): exit=%d updates, dose=%d vs baseline=%d, reversals=%d",
      n, new.escape, new.exposure, old.exposure, new.reversals))
  end)
end

test("five central layers: honest slow progress without jitter or magical escape", function()
  local cfg = config()
  local result = rollout(world(layers(5)), 120, cfg)
  assert(result.first.key ~= 0 and result.moving >= 110, "heavy poison caused idle fallback")
  assert(result.displacement >= 4, "did not make measurable outward progress")
  assert(result.displacement >= result.distance * 0.9 and result.reversals <= 1,
    "heavy poison produced back-and-forth jitter")
  assert(not result.escape and dose(result.world) == 5, "fixture falsely claims escape before physical reach")
  assert(result.distance <= 4 * 0.4^5 * 120 + 1e-6, "used unpoisoned or impossible speed")
  print(string.format("  five layers: displacement=%.6f, travelled=%.6f, still inside (expected)",
    result.displacement, result.distance))
end)

test("five overlapping edge layers: regain speed only after actual exit", function()
  local cfg = config()
  local result = rollout(world(layers(5, -63.75)), 35, cfg)
  assert(result.escape and result.escape < 20, "failed to cross nearby five-layer boundary")
  assert(result.world.player.x > 0, "moved into the heavy interior")
  assert(result.distance > 3 and dose(result.world) == 0, "did not regain mobility after exit")
end)

test("real impact outranks poison even at extreme terrain weight", function()
  local cfg = config(); cfg.poison_navigation.risk_weight = 1000000
  local w = world({ cloud(70) })
  w.bullets = { rect(-12, 320, 1.2, 0, 4, 1000) }
  refresh(w)
  local r = dodge.choose(w, {}, cfg)
  assert(not r.collides and r.vx > 0, "terrain preference selected a real collision")
  for i = 1, 12 do
    -- Independent swept collision oracle for this full-height moving wall:
    -- horizontal separation is linear within one physical update, so both
    -- endpoints > the combined half-width prove no intervening contact.
    local gap = w.player.x - w.bullets[1].hitBody.x
    local vx = velocity(w, r.key)
    assert(math.min(gap, gap + vx - 1.2) > 4, "actual poisoned movement crossed the damaging wall")
    advance(w, r, cfg)
    r.vx, r.vy = velocity(w, r.key)
  end
  assert(dose(w) > 0, "fixture did not enter poison to avoid damage")
end)

test("imminent natural expiry does not cause a large evacuation", function()
  local cfg = config()
  local last_tick = world(layers(3, 0, 320, 299)); refresh(last_tick)
  assert(dodge.choose(last_tick, {}, cfg).key == 0, "one-update cloud triggered needless travel")
  local result = rollout(world(layers(3, 0, 320, 293)), 10, cfg)
  assert(result.distance < 6, "expiring cloud caused excessive travel")
  assert(dose(result.world) == 0, "expired fixture remained poisonous")
end)

test("asymmetric overlap escapes towards lower concentration", function()
  local clouds = { cloud(0) }
  for i = 1, 4 do clouds[#clouds + 1] = cloud(63) end
  local result = rollout(world(clouds), 80, config())
  assert(result.world.player.x < -1, "did not move away from four additional clouds")
  assert(dose(result.world) < 5, "did not reduce overlapping layers")
  assert(result.reversals <= 2, "overlap boundary produced repeated reversal")
end)

test("wall corner evacuation remains reachable and bounded", function()
  local result = rollout(world(layers(1, 128, 424), 128, 424), 70, config())
  assert(result.escape and result.escape < 65, "corner escape stuck against field edge")
  assert(result.world.player.x < 100 or result.world.player.y < 390, "did not move inward from corner")
end)

test("protection is not immunity to slowing terrain", function()
  local w = world(layers(3))
  w.player.sensor.state, w.player.sensor.protectionFrames = 3, 128
  local result = rollout(w, 80, config())
  assert(result.first.key ~= 0 and result.displacement > 18,
    "protected player camped in poison or did not progress")
  assert(result.distance <= 80 * 4 * 0.4^3 + 1e-6, "C protection removed poison slowing")
  assert(result.first.protection_frames == 128, "raw protection diagnostic changed")
end)

test("fast and slow candidate speeds preserve poison and axis scales", function()
  for _, slow in ipairs({ false, true }) do
    local w = world(layers(1)); w.player.sensor.baseScaleX, w.player.sensor.baseScaleY = 0.5, 1.25
    if slow then w.player.speedFast = w.player.speedSlow end
    refresh(w)
    local r = dodge.choose(w, {}, config())
    local vx, vy = velocity(w, r.key)
    near(r.vx, vx); near(r.vy, vy)
    assert(r.key ~= 0 and (abs(vx) > 0 or abs(vy) > 0), "scaled player stayed idle")
    advance(w, r, config())
  end
  local w, cfg = world(layers(1)), config()
  cfg.preferred_x, cfg.preferred_y, cfg.position_cost = 9.6, 320, 100
  refresh(w)
  local r = dodge.choose(w, {}, cfg)
  assert(bit(r.key, 4) == 1 and bit(r.key, 128) == 1,
    "precision-position fixture did not select the actual slow-right candidate")
  near(r.vx, 0.8, "slow speed must also include poison")
  near(r.vy, 0, "slow-right vertical speed")
  advance(w, r, cfg)
end)

test("cloud removal clears stale navigation target", function()
  local cfg, w, state = config(), world(layers(1)), {}
  refresh(w); dodge.choose(w, state, cfg)
  w.player.sensor.poisonClouds = {}; refresh(w)
  local r = dodge.choose(w, state, cfg)
  assert(r.key == 0 and r.poison_nav_active == 0, "continued escaping a vanished cloud")
  assert((r.poison_cost or 0) == 0, "stale poison cost remained")
end)

print(string.format("Poison navigation: %d passed, %d failed; baseline=%s",
  passed, #failures, baseline and "v0.1.9 snapshot" or "disabled-navigation fallback"))
if #failures > 0 then error(table.concat(failures, "\n")) end
