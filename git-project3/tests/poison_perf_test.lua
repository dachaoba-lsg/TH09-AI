-- Native Lua 5.1 synthetic work/latency comparison, not an in-game FPS test.
HitType = { Rect = 0, Circle = 1, RotatableRect = 2 }
ExAttackType = { Medicine = 16 }
local current = dofile("dodge.lua")
local baseline_path = "../../work/before-019-poison-20260920/src/ai/dodge.lua"
local file = io.open(baseline_path, "r")
local baseline
if file then file:close(); baseline = dofile(baseline_path) end
local cfg = dofile("config.lua").dodge
-- Isolate terrain/collision work from deliberate sight/attention filtering.
-- vision_test covers the production perception boundary independently.
cfg.vision_radius, cfg.attention = 0, { enabled = false }
local now = perf_now or os.clock
local iterations = BENCH_NEW_ITERATIONS or 50
local function world(count, scenario)
  local w = { player = { x = 0, y = 320, speedFast = 4, speedSlow = 2,
    hitBodyRect = { width = 4, height = 4 }, hitBodyCircle = { radius = 2 } },
    bullets = {}, enemies = {}, exAttacks = {} }
  w.player.sensor = { apiVersion = 1, valid = true, state = 1,
    baseScaleX = 1, baseScaleY = 1, moveScaleX = 1, moveScaleY = 1, poisonClouds = {} }
  local sensor = w.player.sensor
  if scenario ~= "normal" and scenario ~= "dense_normal" then
    sensor.poisonClouds[1] = { x = scenario == "cloud_edge" and -62 or 0, y = 320,
      radius = 64, age = 100, framesLeft = 200, active = true }
    sensor.moveScaleX, sensor.moveScaleY = 0.4, 0.4
  end
  for i = 1, count do
    local dense = scenario == "dense_normal" or scenario == "dense_poison"
    w.bullets[i] = { vx = math.sin(i * 0.5) * 1.5, vy = 0.5 + i % 7 / 3,
      hitBody = { type = HitType.Rect, x = dense and ((i * 37) % 80 - 40) or ((i * 37) % 272 - 136),
        y = dense and (280 + (i * 53) % 80) or (16 + (i * 53) % 416), width = 5 + i % 4, height = 5 + i % 4 } }
  end
  return w
end
local function bench(module, w)
  module.choose(w, {}, cfg)
  collectgarbage("collect")
  local elapsed, result = 0
  for _ = 1, iterations do
    local start = now()
    result = module.choose(w, {}, cfg)
    elapsed = elapsed + now() - start
  end
  return elapsed * 1000 / iterations, result
end
print("Synthetic native 64-bit Lua microbenchmark; excludes injection/engine cost.")
print("scenario,objects,v018_ms,v019_ms,seen,relevant,movement_segments,trajectory_tests")
for _, scenario in ipairs({ "normal", "cloud_inside", "cloud_edge", "dense_normal", "dense_poison" }) do
  local counts = scenario:find("dense") and { 2000 } or { 0, 200, 1000, 2000 }
  for _, count in ipairs(counts) do
    local w = world(count, scenario)
    local old_ms = baseline and bench(baseline, w) or 0
    local new_ms, r = bench(current, w)
    assert(r.objects_seen == count, "objects were truncated")
    assert(r.movement_segments <= 17 * 14, "terrain work unbounded")
    if scenario ~= "cloud_edge" then assert(r.movement_segments == 17, "constant speed should merge") end
    assert(r.trajectory_tests <= count * r.movement_segments, "ordinary bullets took a per-frame inner loop")
    print(string.format("%s,%d,%.3f,%.3f,%d,%d,%d,%d", scenario, count,
      old_ms, new_ms, r.objects_seen, r.objects_relevant, r.movement_segments, r.trajectory_tests))
  end
end
print("poison_perf_test: PASS")
