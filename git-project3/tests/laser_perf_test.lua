-- Native Lua microbenchmark, not in-game FPS or the injected x86 runtime.
HitType = { Rect = 0, Circle = 1, RotatableRect = 2 }
local current, cfg = dofile("dodge.lua"), dofile("config.lua").dodge
local old_path = "../../work/marisa-audit/ai-0.1.7/dodge.lua"
local saved = io.open(old_path, "r")
local old
if saved then saved:close(); old = dofile(old_path) end
local now = perf_now or os.clock
local function world(count, laser_count, angular, frame)
  local p = { x = 0, y = 320, speedFast = 4, speedSlow = 2,
    hitBodyRect = { type = HitType.Rect, x = 0, y = 320, width = 4, height = 4 },
    hitBodyCircle = { type = HitType.Circle, x = 0, y = 320, radius = 2 } }
  local w = { player = p, bullets = {}, enemies = {}, exAttacks = {} }
  for i = 1, count do
    local x, y = (i * 37) % 272 - 136, 16 + (i * 53) % 416
    w.bullets[#w.bullets + 1] = { id = i, x = x, y = y,
      vx = math.sin(i * 0.5) * 1.5, vy = 0.5 + (i % 7) / 3,
      hitBody = { type = HitType.Rect, x = x, y = y, width = 5 + i % 4, height = 5 + i % 4 } }
  end
  for i = 1, laser_count do
    local x, y = (i * 13) % 80 - 40 + frame * 2, 230 + (i * 17) % 40 + frame
    w.bullets[#w.bullets + 1] = { id = count + i, x = -999, y = -999, vx = 0, vy = 0,
      hitBody = { type = HitType.RotatableRect, x = x, y = y, width = 100 + frame * 3,
        height = 4 + frame * 0.25, angle = math.pi / 2 + (angular and frame * 0.015 or 0) } }
  end
  return w
end
local function bench(algorithm, previous, next_world, iterations)
  local elapsed, result = 0, nil
  collectgarbage("collect")
  for _ = 1, iterations do
    local state = { frame = 1 }
    algorithm.choose(previous, state, cfg)
    state.frame = 2
    local start = now()
    result = algorithm.choose(next_world, state, cfg)
    elapsed = elapsed + now() - start
  end
  return elapsed * 1000 / iterations, result
end
print("scenario,normal,lasers,old017_ms,new_ms,dynamic_lasers,trajectory_tests,laser_sweep_tests")
for _, row in ipairs({
  { "empty", 0, 0, false }, { "ordinary", 536, 0, false }, { "stress", 2000, 0, false },
  { "linear", 536, 4, false }, { "linear-max", 536, 48, false },
  { "angular", 536, 4, true }, { "angular-max", 536, 48, true },
}) do
  local previous, next_world = world(row[2], row[3], row[4], 0), world(row[2], row[3], row[4], 1)
  local old_ms = old and bench(old, previous, next_world, BENCH_NEW_ITERATIONS or 50) or 0
  local ms, r = bench(current, previous, next_world, BENCH_NEW_ITERATIONS or 50)
  assert(r.dynamic_lasers == row[3] and r.laser_count == row[3])
  assert(r.laser_sweep_tests <= row[3] * 17 * (row[4] and 12 or 3))
  print(string.format("%s,%d,%d,%.3f,%.3f,%d,%d,%d", row[1], row[2], row[3], old_ms, ms,
    r.dynamic_lasers, r.trajectory_tests, r.laser_sweep_tests))
end
print("laser_perf_test: PASS")
