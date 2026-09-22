-- Run with working directory src/ai, using tests/run_native_lua.py or Lua 5.1.
-- All game state here is synthetic. No game process or input is accessed.
HitType = { Rect = 0, Circle = 1, RotatableRect = 2 }
local actual_hit_test = dofile("../../tests/upstream_hit_test.lua")
local hit_calls = 0
function hitTest(a, b)
  hit_calls = hit_calls + 1
  return actual_hit_test(a, b)
end
local old = dofile("../../tests/fixtures/dodge_0_1_2.lua")
local current = dofile("dodge.lua")
local now = perf_now or os.clock

local function copy(source)
  local result = {}
  for k, v in pairs(source) do result[k] = type(v) == "table" and copy(v) or v end
  return result
end
local function config()
  local cfg = dofile("config.lua").dodge
  -- This suite audits full-field collision geometry, including intentionally
  -- distant fast shots. Hard circular perception has its own vision_test.
  cfg.vision_radius = 0
  cfg.attention = { enabled = false }
  return cfg
end
local function player(x, y)
  x, y = x or 0, y or 320
  return { x = x, y = y, speedFast = 4, speedSlow = 2,
    hitBodyRect = { type = HitType.Rect, x = x, y = y, width = 4, height = 4 },
    hitBodyCircle = { type = HitType.Circle, x = x, y = y, radius = 2 } }
end
local function world(p)
  return { player = p or player(), enemies = {}, bullets = {}, exAttacks = {} }
end
local function rect(x, y, width, height, vx, vy)
  return { x = x, y = y, vx = vx or 0, vy = vy or 0,
    hitBody = { type = HitType.Rect, x = x, y = y, width = width or 4, height = height or 4 } }
end
local function near(actual, expected, message)
  assert(actual ~= nil and math.abs(actual - expected) < 1e-8,
    message .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function staticCost(p, object, kind)
  p.speedFast, p.speedSlow = 0, 0
  local w, cfg = world(p), config()
  cfg.safety_margin, cfg.position_cost, cfg.wall_cost, cfg.boundary_cost = 0, 0, 0, 0
  cfg.warning_laser_min_length = 1000000000
  w[kind or "bullets"] = { object }
  return current.choose(w, {}, cfg).danger
end

-- Analytic sweeps must catch crossings between integer frame samples.
do
  local a, b = current.rectInterval(-200, 0, 400, 0, -3, 3, -3, 3, 12)
  near(a, 197 / 400, "rectangle sweep entry")
  near(b, 203 / 400, "rectangle sweep exit")
  a, b = current.circleInterval(-200, 0, 400, 0, 3, 12)
  near(a, 197 / 400, "circle sweep entry")
  near(b, 203 / 400, "circle sweep exit")
  assert(current.rectInterval(0, 4, 0, 0, -3, 3, -3, 3, 12) == nil)
  assert(current.circleInterval(0, 4, 0, 0, 3, 12) == nil)
  a, b = current.circleInterval(0, 3, 0, 0, 3, 12)
  near(a, 0, "stationary circle tangency entry")
  near(b, 12, "stationary circle tangency exit")
  assert(staticCost(player(), rect(-200, 320, 2, 2, 400, 0)) > 0,
    "fast bullet crossing between frames was missed")
end

-- Compare simple geometry against the independently transcribed upstream API.
do
  assert(staticCost(player(), rect(7, 320, 10, 2)) > 0, "rect boundary missed")
  near(staticCost(player(), rect(7.01, 320, 10, 2)), 0, "rect full width was doubled")
  local laser = { vx = 0, vy = 0, hitBody = {
    type = HitType.RotatableRect, x = 0, y = 320, width = 100, height = 2, angle = 0 } }
  assert(actual_hit_test(player(80).hitBodyRect, laser.hitBody), "upstream laser origin fixture")
  assert(staticCost(player(80), laser) > 0, "laser treated as centered rather than origin-based")
  near(staticCost(player(-10), laser), 0, "hazard incorrectly extends behind laser origin")
  assert(staticCost(player(80, 323), laser) > 0, "laser thickness boundary missed")
  near(staticCost(player(80, 323.01), laser), 0, "laser height was treated as half-size")
  laser.hitBody.angle = math.pi / 2
  assert(staticCost(player(0, 400), laser) > 0, "vertical laser origin transform failed")
  near(staticCost(player(0, 310), laser), 0, "vertical laser extends behind origin")
  local circle = { hittable = true, hitBody = {
    type = HitType.Circle, x = 6.9, y = 320, radius = 5 } }
  assert(staticCost(player(), circle, "exAttacks") > 0, "EX circle radius collision missed")
  circle.hitBody.x = 7.1
  near(staticCost(player(), circle, "exAttacks"), 0, "EX circle radius enlarged incorrectly")
  circle.hitBody.x, circle.hittable = 0, false
  near(staticCost(player(), circle, "exAttacks"), 0, "non-hittable EX was scored")
end

-- Thousands of irrelevant entries must never truncate a dangerous late entry.
do
  local hazard = rect(-240, 320, 4, 4, 40, 0)
  local one = world()
  one.bullets = { hazard }
  local expected = current.choose(one, {}, config())
  assert(expected.key ~= 0 and expected.objects_relevant == 1,
    "fast approaching bullet outside old broad-phase radius was missed")
  local padded = world()
  for i = 1, 2000 do padded.bullets[i] = rect(1000 + i, 1000, 4, 4) end
  padded.bullets[2001] = hazard
  local result = current.choose(padded, {}, config())
  assert(result.objects_seen == 2001, "objects were truncated")
  assert(result.objects_relevant == 1, "swept broad phase did not isolate late threat")
  assert(result.key == expected.key, "late dangerous bullet changed after irrelevant padding")
  assert(result.trajectory_tests == 17, "single threat should test 17 unsplit trajectories")
end

-- Piecewise paths stop each coordinate at its wall instead of escaping outside.
do
  local cfg = config()
  cfg.preferred_x, cfg.preferred_y = 1000, 1000
  cfg.position_cost, cfg.movement_cost, cfg.wall_cost, cfg.boundary_cost = 1, 0, 0, 0
  local result = current.choose(world(player(134, 431)), {}, cfg)
  assert(#result.segments == 3, "corner-clamped diagonal must have three path segments")
  local duration = 0
  for _, segment in ipairs(result.segments) do
    duration = duration + segment.duration
    local end_x = segment.x + segment.vx * segment.duration
    local end_y = segment.y + segment.vy * segment.duration
    assert(end_x <= cfg.field.max_x + 1e-9 and end_y <= cfg.field.max_y + 1e-9,
      "candidate trajectory escaped the playfield")
  end
  near(duration, cfg.prediction_frames, "wall-clamped trajectory duration")
  local last = result.segments[#result.segments]
  near(last.vx, 0, "x movement after reaching wall")
  near(last.vy, 0, "y movement after reaching wall")
end

-- Even a collision exactly at the horizon must lose to a safe route. Its
-- integrated urgency is zero, so a plain scalar cost could otherwise prefer
-- staying still over any movement/position penalty.
do
  local w, cfg = world(), config()
  w.bullets = { rect(0, 280, 4, 4, 0, 3) }
  cfg.movement_cost = 1000000000
  local result = current.choose(w, {}, cfg)
  assert(result.key ~= 0 and result.collides == false,
    "position/movement preference outranked a collision at the horizon")
end

-- Rest is stable in an empty preferred position, even after earlier movement.
-- A fixed threat snapshot also must not alternate equal-cost left/right choices.
do
  local w, cfg, state = world(), config(), { last_move_key = 16 }
  for _ = 1, 60 do assert(current.choose(w, state, cfg).key == 0, "empty-screen jitter") end
  w.bullets = { rect(0, 290, 6, 6, 0, 3) }
  local first = current.choose(w, state, cfg).key
  assert(first ~= 0, "test threat should require a dodge")
  for _ = 1, 60 do
    assert(current.choose(w, state, cfg).key == first, "fixed threat direction oscillation")
  end
end

-- Zero-thickness warning lasers are still perceived.
do
  local w = world()
  w.bullets = { { hitBody = { type = HitType.RotatableRect,
    x = 0, y = 16, width = 420, height = 0, angle = math.pi / 2 } } }
  local result = current.choose(w, {}, config())
  assert(result.warning_lasers == 1 and result.key ~= 0, "zero-thickness warning ignored")
  w.bullets[1].hitBody.height = 0.5
  w.player.speedFast, w.player.speedSlow = 0, 0
  result = current.choose(w, {}, config())
  assert(result.warning_lasers == 0 and result.collides,
    "positive-thickness laser incorrectly treated as a harmless warning")
end

local function benchmarkWorld(count, dense)
  local w = world()
  for i = 1, count do
    local x = dense and ((i * 37) % 80 - 40) or ((i * 37) % 272 - 136)
    local y = dense and (280 + (i * 53) % 80) or (16 + (i * 53) % 416)
    w.bullets[i] = rect(x, y, 5 + i % 4, 5 + i % 4,
      math.sin(i * 0.5) * 1.5, 0.5 + (i % 7) / 3)
  end
  return w
end
local function benchmark(algorithm, w, cfg, iterations)
  algorithm.choose(w, {}, cfg) -- warmup; exclude first module/runtime overhead
  collectgarbage("collect")
  local elapsed, calls, last = 0, 0, nil
  for _ = 1, iterations do
    hit_calls = 0
    local start = now()
    last = algorithm.choose(w, {}, cfg)
    elapsed = elapsed + now() - start
    calls = calls + hit_calls
  end
  return elapsed * 1000 / iterations, calls / iterations, last
end
local old_cfg, new_cfg = config(), config()
old_cfg.broad_phase_radius, old_cfg.direction_change_cost = 120, 0.04
old_cfg.movement_cost = 0
old_cfg.warning_laser_max_half_thickness = 0.75
print("dodge correctness: PASS")
print("Synthetic microbenchmark only; pure-Lua hitTest stand-in excludes injected C++ wrapper overhead.")
print("scenario,objects,old_ms,new_ms,old_hitTest_calls,new_hitTest_calls,new_seen,new_relevant,new_trajectory_tests")
for _, count in ipairs({ 0, 200, 1000, 2000 }) do
  local w = benchmarkWorld(count, false)
  local old_ms, old_calls = benchmark(old, w, old_cfg, BENCH_OLD_ITERATIONS or 3)
  local new_ms, new_calls, result = benchmark(current, w, new_cfg, BENCH_NEW_ITERATIONS or 50)
  assert(new_calls == 0, "optimized path called expensive native hitTest bridge")
  assert(result.objects_seen == count, "benchmark dropped objects")
  print(string.format("distributed,%d,%.3f,%.3f,%.0f,%.0f,%d,%d,%d", count,
    old_ms, new_ms, old_calls, new_calls, result.objects_seen, result.objects_relevant, result.trajectory_tests))
end
do
  local count, w = 2000, benchmarkWorld(2000, true)
  local old_ms, old_calls = benchmark(old, w, old_cfg, BENCH_OLD_ITERATIONS or 3)
  local new_ms, new_calls, result = benchmark(current, w, new_cfg, BENCH_NEW_ITERATIONS or 50)
  assert(new_calls == 0 and result.objects_seen == count)
  print(string.format("dense,%d,%.3f,%.3f,%.0f,%.0f,%d,%d,%d", count,
    old_ms, new_ms, old_calls, new_calls, result.objects_seen, result.objects_relevant, result.trajectory_tests))
end
print("dodge_perf_test: PASS")
