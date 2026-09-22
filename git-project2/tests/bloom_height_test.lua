-- Policy altitude boundary regressions; no game process or game input.
HitType = { Rect = 0, Circle = 1, RotatableRect = 2 }
ExAttackType = { Medicine = 16 }
local dodge = dofile("dodge.lua")
local function config() return dofile("config.lua").dodge end
local checks = 0
local function check(value, message)
  checks = checks + 1
  assert(value, message)
end
local function near(actual, expected, message)
  check(math.abs(actual - expected) < 1e-8, (message or "value") .. ": " .. tostring(actual) .. " != " .. tostring(expected))
end
local function player(y, sensor)
  return { x = 0, y = y, speedFast = 4, speedSlow = 2, sensor = sensor,
    hitBodyRect = { type = HitType.Rect, width = 4, height = 4 },
    hitBodyCircle = { type = HitType.Circle, radius = 2 } }
end
local function bullet(x, y, vy, width, height)
  return { vx = 0, vy = vy or 0,
    hitBody = { type = HitType.Rect, x = x, y = y, width = width or 4, height = height or 4 } }
end
local function world(y, objects, sensor)
  return { player = player(y, sensor), bullets = objects or {}, enemies = {}, exAttacks = {} }
end
local function legal(result, y, label)
  check(y + result.vy >= math.min(150, y) - 1e-9, (label or "height") .. " selected an illegal next input")
  check(result.height_limited == true, "missing height diagnostic")
  check(result.height_recovering == (y < 150), "wrong recovery diagnostic")
end
local function choose(w, intent, state)
  intent = intent or { min_y = 150, target_y = 16, target_x = 100, focus = false }
  return dodge.choose(w, state or {}, config(), intent)
end

-- Crossing is assessed at the next real update, including diagonal lengths
-- and slow movement. An earlier intent's direction or focus preference may
-- never add a candidate back after this legal-input filter.
do
  for _, row in ipairs({ {150, 6}, {151, 6}, {152, 3}, {153, 1}, {154, 0} }) do
    for _, focus in ipairs({ false, true }) do
      local r = choose(world(row[1], {bullet(0, row[1] + 10, -2, 500, 4)}),
        { min_y = 150, target_y = 16, target_x = 100, focus = focus,
          focus_mismatch_cost = 1e30, position_weight = 1e30 }, { last_move_key = 16 })
      legal(r, row[1], "line and diagonal")
      check(r.height_rejected == row[2], "incorrect near-line candidate count at " .. row[1])
    end
  end
end

-- The height line is not a fake wall. The complete original 12-frame path
-- continues above it when the currently legal input is held in prediction.
-- This matters for both collision scoring and the resource-position cost.
do
  local r = choose(world(153, {bullet(0, 163, -2, 500, 4)}), { min_y = 150 })
  legal(r, 153)
  check(r.vy < 0 and r.terminal_y < 150, "legal upward path was clipped to the policy line")
  near(r.terminal_y, 153 + r.vy * 12, "forecast was shortened at the next input")
  near(r.segments[1].y, 153, "candidate was teleported")
  local cfg = config()
  check(cfg.field.min_y == 16 and cfg.field.max_y == 432, "physical field changed")
end

-- An overwhelming hazard must not make upward boundary violation legal.
-- An unchanged all-colliding ranking is computed over the legal set only.
do
  local r = choose(world(150, {bullet(0, 162, -2, 500, 500)}))
  legal(r, 150)
  check(r.collides and r.height_rejected == 6, "fixture must leave all paths dangerous")
  check(r.intent_cost == 0, "resource intent influenced all-colliding escape")
end

-- Starting above the desired band is possible after a changed setting or
-- prior movement. Move down by real speed when safe; never teleport to 150.
-- A damaging horizontal beam below the player may require waiting/lateral
-- evasion, but must still never produce further upward movement.
do
  local r = choose(world(100), { min_y = 150, target_y = 20 })
  legal(r, 100)
  check(r.vy > 0 and r.height_rejected == 6, "empty-field recovery did not move down")
  near(r.segments[1].y, 100)
  check(r.terminal_y <= 148 and 100 + r.vy <= 104, "recovery teleported into legal band")
  local beam = { id = 1, vx = 0, vy = 0,
    hitBody = { type = HitType.RotatableRect, x = -136, y = 110, width = 272, height = 8, angle = 0 } }
  local blocked = choose(world(100, {beam}), { min_y = 150, target_y = 20 })
  legal(blocked, 100)
  check(not blocked.collides and blocked.vy == 0, "recovery forced movement through a real laser")
end

-- Current poison movement, diagonal scale, cloud expiry and entering clouds
-- all retain their original physical paths. The NEXT input uses current
-- sensor factors, so a slow poisoned step may fit where fast movement fails.
do
  local sensor = { valid = true, state = 0, protectionFrames = 0,
    baseScaleX = 1, baseScaleY = 1, moveScaleX = 0.4, moveScaleY = 0.4,
    poisonClouds = { { x = 0, y = 150, radius = 64, age = 299, framesLeft = 1, active = true } } }
  local r = choose(world(150.9, {bullet(0, 160.9, -2, 500, 4)}, sensor), { min_y = 150 })
  legal(r, 150.9)
  check(r.height_rejected == 3, "poison next-step filter used nominal fast speed")
  check(r.focus and r.vy < 0, "poison fixture did not use a legal slow upward input")
  check(#r.segments >= 2 and r.segments[2].vy < r.segments[1].vy,
    "poison expiry was lost from the real movement forecast")
  check(r.terminal_y < 150, "poison path was clipped by policy line")

  local entering = { valid = true, state = 0, protectionFrames = 0,
    baseScaleX = 1, baseScaleY = 1, moveScaleX = 1, moveScaleY = 1,
    poisonClouds = { { x = 0, y = 87, radius = 64, age = 100, framesLeft = 200, active = true } } }
  local e = choose(world(152, {bullet(0, 162, -2, 500, 4)}, entering), { min_y = 150 })
  legal(e, 152)
  check(e.height_rejected == 3, "future poison wrongly made the first fast step legal")
  check(e.poison_clouds == 1, "dynamic poison geometry was dropped")
end

-- A moving/expanding laser keeps real history and geometric prediction;
-- the filtered candidate list is also used for the later intent comparison.
do
  local state = {}
  for frame = 1, 8 do
    local beam = { id = 71, enabled = true,
      hitBody = { type = HitType.RotatableRect, x = -136, y = 172 - frame,
        width = 272, height = 5 + frame * .25, angle = 0 } }
    state.frame = frame
    local r = choose(world(150, {beam}), { min_y = 150, target_y = 16, focus = true,
      position_weight = 1e30, focus_mismatch_cost = 1e30 }, state)
    legal(r, 150)
    check(r.height_rejected == 6, "laser path escaped legal filtering")
    if frame > 1 then check(r.dynamic_lasers == 1 and r.laser_sweep_tests > 0, "laser history was lost") end
  end
end

-- No min_y must retain the exact existing behavior (including optional
-- resource intent), while malformed min_y must not infect costs or inputs.
local baseline_path = "../../work/before-height-v2.0.3/dodge.lua"
local baseline_file = io.open(baseline_path, "r")
if baseline_file then
  baseline_file:close()
  local old = dofile(baseline_path)
  local old_states, new_states = { {}, {} }, { {}, {} }
  math.randomseed(203150)
  for frame = 1, 300 do
    local objects = {}
    for i = 1, 12 do objects[i] = bullet(math.random(-136, 136), math.random(16, 432), math.random(-3, 5)) end
    local w = world(math.random(30, 420), objects)
    for variant = 1, 2 do
      local intent = variant == 2 and { target_x = 80, target_y = 90, focus = frame % 3 == 0 } or nil
      old_states[variant].frame, new_states[variant].frame = frame, frame
      local a = old.choose(w, old_states[variant], config(), intent)
      local b = dodge.choose(w, new_states[variant], config(), intent)
      for _, field in ipairs({ "name", "key", "cost", "danger", "collides", "vx", "vy", "position_cost",
          "movement_segments", "objects_relevant", "trajectory_tests", "warning_lasers", "laser_history_resets" }) do
        check(a[field] == b[field], "missing min_y changed " .. field .. " at " .. frame)
      end
      check(not b.height_limited and not b.height_recovering and b.height_rejected == 0, "inactive height diagnostics")
    end
  end
  print("PASS height optional baseline: 300 nil-intent and 300 bloom-intent scenes")
end
for _, bad in ipairs({ false, "150", math.huge, -math.huge, 0/0 }) do
  local r = choose(world(150), { min_y = bad })
  check(not r.height_limited and r.cost == r.cost, "invalid optional height corrupted movement")
end
print("bloom_height_test: PASS " .. checks .. " assertions")
