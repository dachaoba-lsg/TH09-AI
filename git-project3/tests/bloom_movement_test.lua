-- Synthetic bloom movement intent tests; no game process or input.
HitType = { Rect = 0, Circle = 1, RotatableRect = 2 }
ExAttackType = { Medicine = 16 }
local dodge = dofile("dodge.lua")
local function config()
  local cfg = dofile("config.lua").dodge
  -- These assertions describe the original dodge geometry. The 3.1 attention
  -- limit changes which objects are scored at all, so it is disabled here the
  -- same way the 3.0 movement cap is disabled for the legacy audit below;
  -- tests/attention_test.lua asserts the limit itself.
  cfg.attention = { enabled = false }
  return cfg
end
local function player(x, y, sensor)
  x, y = x or 0, y or 320
  return { x = x, y = y, speedFast = 4, speedSlow = 2, sensor = sensor,
    hitBodyRect = { type = HitType.Rect, x = x, y = y, width = 4, height = 4 },
    hitBodyCircle = { type = HitType.Circle, x = x, y = y, radius = 2 } }
end
local function bullet(x, y, vx, vy, width, height)
  return { vx = vx or 0, vy = vy or 0,
    hitBody = { type = HitType.Rect, x = x, y = y, width = width or 4, height = height or 4 } }
end
local function world(p, bullets)
  return { player = p or player(), bullets = bullets or {}, enemies = {}, exAttacks = {} }
end
local function near(a, b, message)
  assert(a and math.abs(a - b) < 1e-7, (message or "value") .. ": " .. tostring(a) .. " != " .. tostring(b))
end
local function checkSafe(world, intent)
  local baseline = dodge.choose(world, {}, config())
  local chosen = dodge.choose(world, {}, config(), intent)
  assert(not baseline.collides and not chosen.collides, "intent overrode a collision-free escape")
  assert(chosen.terrain_cost <= baseline.terrain_cost + 1e-7, "intent bought additional wall/boundary exposure")
  assert(chosen.danger <= baseline.danger + 5.6 + 1e-7, "intent exceeded its soft danger budget")
  return chosen, baseline
end

-- Standing and focusing are separate: no invented movement is needed to
-- preserve fairy supply or activate a deliberate capture window.
do
  local w = world()
  local legacy = dodge.choose(w, {}, config())
  assert(legacy.name == "stay" and legacy.key == 0 and legacy.movement_segments == 17)
  local focused = dodge.choose(w, {}, config(), { focus = true })
  assert(focused.name == "slow-stay" and focused.key == 4 and focused.focus)
  assert(focused.vx == 0 and focused.vy == 0 and focused.movement_segments == 18)
  local unfocused = dodge.choose(w, {}, config(), { focus = false })
  assert(unfocused.name == "stay" and unfocused.key == 0 and not unfocused.focus)
end

-- Active resource positioning can beat the old stay preference, with the
-- matching fast/slow trajectory already present during collision prediction.
do
  local fast = checkSafe(world(), { focus = false, target_x = 100, target_y = 320 })
  assert(fast.name == "fast-right" and not fast.focus and fast.terminal_x > 0)
  local slow = checkSafe(world(), { focus = true, target_x = 100, target_y = 320, focus_mismatch_cost = 8 })
  assert(slow.name == "slow-right" and slow.focus and slow.terminal_x > 0)
  near(fast.terminal_x, 48); near(slow.terminal_x, 24)
end

-- A small non-tied soft-risk difference is permitted for useful positioning.
-- This is deliberately not an exact-equality tie-break-only fixture.
do
  local w = world(nil, {
    bullet(-36.75, 284.5, -2.6, 1.6), bullet(-2.75, 326.75, 0.4, 3.2),
    bullet(-21, 325.25, -1.5, -0.3),
  })
  local chosen, baseline = checkSafe(w, { focus = false, target_x = 100, target_y = 320, position_weight = 0.01 })
  assert(baseline.name == "fast-up" and chosen.name == "fast-up-right")
  assert(chosen.danger > baseline.danger + 1, "fixture no longer exercises a non-tied risk band")
  assert(chosen.terminal_x > baseline.terminal_x, "resource intent failed to change positioning")
end

-- Enormous caller preferences cannot buy sustained near misses or collision;
-- the diagonal route approaches the target without hugging this obstacle.
do
  local chosen = checkSafe(world(nil, { bullet(16, 328) }), {
    focus = false, target_x = 100, target_y = 320,
    position_weight = 1e30, focus_mismatch_cost = 1e30,
  })
  assert(chosen.danger == 0 and chosen.name ~= "fast-right")
  assert(chosen.intent_cost >= -12 and chosen.intent_cost <= 20, "unbounded intent cost")
  checkSafe(world(player(125, 320)), { focus = true, target_x = 1e30, position_weight = 1e30 })
end

-- Focus is a preference. An approaching full-width line leaves only a fast
-- escape; selecting Shift after planning a fast trajectory would fail here.
do
  local chosen = checkSafe(world(nil, { bullet(0, 306, 0, 4, 400, 4) }), {
    focus = true, focus_mismatch_cost = 1e30,
  })
  assert(chosen.name == "fast-down" and not chosen.focus and chosen.vy == 4)
end

-- Conversely, default high-speed intent must still allow a safer slow route.
do
  local w = world(nil, {
    bullet(5, 327, -3, 1), bullet(17, 334, -1, 3), bullet(17, 308, 3, 2),
    bullet(-14, 347, -1, 0), bullet(12, 332, -2, 1), bullet(-9, 294, -2, 1),
    bullet(-6, 291, 3, 4),
  })
  local chosen = checkSafe(w, { focus = false, focus_mismatch_cost = 8 })
  assert(chosen.name == "slow-up-left" and chosen.focus)
end

-- No safe route: resources must not change the original escape ordering.
do
  local w = world(nil, { bullet(0, 320, 0, 0, 500, 500) })
  local baseline = dodge.choose(w, {}, config())
  local chosen = dodge.choose(w, {}, config(), { focus = true, target_x = 100, position_weight = 1e30 })
  assert(baseline.collides and chosen.collides and chosen.key == baseline.key)
  near(chosen.cost, baseline.cost); assert(chosen.intent_cost == 0)
end

-- A completed capture window must release Shift even with residual danger.
-- Previously the 8-point direction penalty for key4 -> key0 tied the 8-point
-- focus mismatch, keeping slow-stay forever despite a safe identical path.
do
  local w = world(nil, {
    bullet(-73, 303, 0, 3), bullet(71, 368, -2, 6), bullet(-62, 304, 0, 3),
    bullet(-3, 328, 5, 3), bullet(56, 330, -4, 2),
  })
  local state = { last_move_key = 4 }
  for _ = 1, 100 do
    local chosen = dodge.choose(w, state, config(), { focus = false, focus_mismatch_cost = 8 })
    assert(chosen.name == "stay" and not chosen.focus and chosen.key == 0,
      "direction hysteresis kept Shift after the capture window ended")
    assert(not chosen.collides)
    near(chosen.danger, 14, "focus release changed the stationary hazard trajectory")
  end
end

-- Resource scores use the real poisoned endpoint, including expiry and wall
-- clipping, rather than silently adding Shift or using nominal speed * time.
do
  local sensor = { valid = true, state = 1, protectionFrames = 0,
    baseScaleX = 1, baseScaleY = 1, moveScaleX = 0.4, moveScaleY = 0.4,
    poisonClouds = { { x = 0, y = 320, radius = 64, age = 100, framesLeft = 200, active = true } } }
  local chosen = checkSafe(world(player(0, 320, sensor)), { focus = false, target_x = 100 })
  assert(chosen.name == "fast-right" and not chosen.focus)
  near(chosen.terminal_x, 19.2)
  near(chosen.intent_cost, ((19.2 - 100)^2 - 100^2) * 0.002)
  local tail = chosen.segments[#chosen.segments]
  near(chosen.terminal_x, tail.x + tail.vx * tail.duration)
end

-- Invalid optional preferences never infect the finite movement score.
do
  local chosen = dodge.choose(world(), {}, config(), {
    focus = false, target_x = 0/0, target_y = math.huge,
    position_weight = math.huge, focus_mismatch_cost = 0/0,
  })
  assert(chosen.name == "stay" and chosen.cost == chosen.cost)
end

-- Optional baseline audit, following the existing laser regression pattern.
-- The snapshot is not required in the public source package. Where available,
-- compare nil-intent decisions and diagnostics against the unedited v0.1.9.
local old_path = "../../work/before-bloom-movement/dodge.lua"
local old_file = io.open(old_path, "r")
if old_file then
  old_file:close()
  local old, previous, current = dofile(old_path), {}, {}
  -- The unedited v0.1.9 baseline has no human-like movement cap, so this audit
  -- disables 3.0's cap explicitly. The capped behaviour is asserted separately
  -- below; keeping the cap here would only re-test the new rule.
  local audit = config()
  audit.move_change_budget, audit.move_change_min_frames = math.huge, 0
  local uncapped_changes, uncapped_rolling = 0, 0
  math.randomseed(90210)
  for frame = 1, 300 do
    local p, objects = player(math.random(-120, 120), math.random(80, 400)), {}
    for i = 1, 12 do
      objects[i] = bullet(math.random(-136, 136), math.random(16, 432), math.random(-4, 4), math.random(-2, 5))
    end
    previous.frame, current.frame = frame, frame
    local a, b = old.choose(world(p, objects), previous, audit), dodge.choose(world(p, objects), current, audit, nil)
    if (b.move_changes or 0) > uncapped_rolling then
      uncapped_changes = uncapped_changes + ((b.move_changes or 0) - uncapped_rolling)
    end
    uncapped_rolling = b.move_changes or 0
    for _, key in ipairs({ "name", "key", "cost", "danger", "collides", "vx", "vy", "position_cost",
        "movement_segments", "objects_relevant", "trajectory_tests", "warning_lasers", "laser_history_resets" }) do
      assert(a[key] == b[key], "nil-intent changed baseline field " .. key .. " on frame " .. frame)
    end
  end
  print(string.format("PASS nil-intent vs unedited baseline: 300 scenes; uncapped direction changes %d",
    uncapped_changes))
end
-- 3.0 human-like movement cap: over the same 300 scenes the default cap must
-- keep real direction changes inside its rolling budget, and the forced state
-- must be reported whenever the cap overrides the uncapped escape.
do
  local cfg = config()
  local state, total_changes, rolling, forced = {}, 0, 0, 0
  math.randomseed(90210)
  for frame = 1, 300 do
    local p, objects = player(math.random(-120, 120), math.random(80, 400)), {}
    for i = 1, 12 do
      objects[i] = bullet(math.random(-136, 136), math.random(16, 432), math.random(-4, 4), math.random(-2, 5))
    end
    state.frame = frame
    local chosen = dodge.choose(world(p, objects), state, cfg, nil)
    if chosen.move_changes and chosen.move_changes > rolling then
      total_changes = total_changes + (chosen.move_changes - rolling)
    end
    rolling = chosen.move_changes or 0
    if chosen.move_cap_forced then forced = forced + 1 end
    assert(rolling <= cfg.move_change_budget, "rolling direction changes exceeded the budget")
  end
  local windows = math.ceil(300 / cfg.move_change_window)
  assert(total_changes <= windows * cfg.move_change_budget + cfg.move_change_budget,
    "movement cap did not bound total direction changes: " .. total_changes)
  assert(total_changes >= 1, "movement cap never saw a direction change")
  assert(forced >= 1, "movement cap never reported a forced decision")
  print(string.format("PASS movement cap: %d direction changes over 300 scenes, %d forced frames",
    total_changes, forced))
end
print("bloom_movement_test: PASS")
