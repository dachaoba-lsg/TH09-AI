-- v0.1.9 -> v0.1.9.2 bounded synthetic timing/work comparison.
-- Run: python tests/run_native_lua.py tests/poison_navigation_perf_test.lua
-- This is native 64-bit Lua 5.1, NOT the 32-bit game or measured game FPS.
-- Counts include 256 clouds plus 2000 dense bullets; no object truncation.
HitType = { Rect = 0, Circle = 1, RotatableRect = 2 }
ExAttackType = { Medicine = 16 }
local current = dofile("dodge.lua")
local baseline_path = "../../work/before-0192-20260928-100137/src/ai/"
local file = io.open(baseline_path .. "dodge.lua", "r")
local baseline, oldcfg
if file then
  file:close()
  baseline, oldcfg = dofile(baseline_path .. "dodge.lua"), dofile(baseline_path .. "config.lua").dodge
end
local cfg, now = dofile("config.lua").dodge, perf_now or os.clock
assert(cfg.poison_navigation and cfg.poison_navigation.enabled, "new navigation not enabled")
local function world(cloud_count, bullet_count, distribution)
  local w = { player = { x = 0, y = 320, speedFast = 4, speedSlow = 2,
      hitBodyRect = { type = HitType.Rect, x = 0, y = 320, width = 4, height = 4 },
      hitBodyCircle = { type = HitType.Circle, x = 0, y = 320, radius = 2 },
      sensor = { apiVersion = 1, valid = true, state = 0, protectionFrames = 0,
        baseScaleX = 1, baseScaleY = 1, moveScaleX = 1, moveScaleY = 1, poisonClouds = {} } },
    bullets = {}, enemies = {}, exAttacks = {} }
  local overlaps, expected_clouds = 0, 0
  for i = 1, cloud_count do
    local x, y = 0, 320
    if distribution == "mixed" then x, y = (i * 47) % 272 - 136, 184 + (i * 71) % 240
    elseif distribution == "edge" then x, y = -62 + (i % 5) * 0.3, 318 + i % 5
    elseif distribution == "remote" then x, y = 0, 16 end
    local age = distribution == "mixed" and (21 + i * 17 % 279) or 100
    w.player.sensor.poisonClouds[i] = { x = x, y = y, radius = 64,
      age = age, ageInt = age, active = true, framesLeft = 300 - age }
    if x * x + (y - 320)^2 < 64^2 then overlaps = overlaps + 1 end
    if math.abs(x) <= 112 and math.abs(y - 320) <= 112 then expected_clouds = expected_clouds + 1 end
  end
  -- The real native snapshot uses binary32 and can underflow at sufficiently
  -- many perfectly concentric layers; zero is a legitimate immobile fixture.
  local factor = overlaps > 120 and 0 or 0.4 ^ overlaps
  w.player.sensor.moveScaleX, w.player.sensor.moveScaleY = factor, factor
  w.expected_clouds = expected_clouds
  for i = 1, bullet_count do
    w.bullets[i] = { vx = math.sin(i * 0.5) * 1.5, vy = 0.5 + i % 7 / 3,
      hitBody = { type = HitType.Rect, x = (i * 37) % 80 - 40,
        y = 280 + (i * 53) % 80, width = 5 + i % 4, height = 5 + i % 4 } }
  end
  return w
end
local function summarize(samples)
  local sum = 0; for _, value in ipairs(samples) do sum = sum + value end
  table.sort(samples)
  return sum / #samples, samples[math.max(1, math.ceil(#samples * 0.95))]
end
local function verify(result, clouds, bullets, is_current)
  assert(result.objects_seen == bullets, "bullet array was truncated")
  assert(result.poison_clouds == clouds, "movement-relevant cloud list changed or was truncated")
  assert(result.movement_segments <= 17 * 14, "unbounded movement segmentation")
  assert(result.trajectory_tests <= bullets * result.movement_segments,
    "ordinary bullet collision acquired a per-frame nested test")
  assert(result.cost == result.cost and math.abs(result.cost) < math.huge, "non-finite result cost")
  if is_current then
    assert(result.poison_probe_count <= 128, "terrain target search exceeded 16 x 8 points")
    assert(result.poison_nav_samples <= 172, "terrain risk sampling exceeded fixed replan budget")
    if clouds == 0 then
      assert(result.poison_probe_count == 0 and result.poison_nav_samples == 0,
        "zero-poison fast path performed terrain sampling")
    end
  end
end
local function bench(module, options, w, iterations, clouds, bullets, is_current, cached)
  local state = { frame = 1 }
  module.choose(w, state, options)
  collectgarbage("collect")
  local samples, result, max_probes, max_samples = {}, nil, 0, 0
  for i = 1, iterations do
    -- Cold calls force a full target replan; cached calls reuse frame 2's
    -- target deliberately so the two workloads are measured separately.
    local active_state = cached and state or {}
    active_state.frame = cached and 2 or 1
    local start = now()
    result = module.choose(w, active_state, options)
    samples[i] = (now() - start) * 1000
    verify(result, w.expected_clouds, bullets, is_current)
    max_probes = math.max(max_probes, result.poison_probe_count or 0)
    max_samples = math.max(max_samples, result.poison_nav_samples or 0)
  end
  local mean, p95 = summarize(samples)
  if is_current and cached then
    assert(max_probes == 0 and max_samples <= 36, "cached target unexpectedly repeated ray search")
  end
  return mean, p95, result, max_probes, max_samples
end
local scenarios = {
  { "clear_empty", 0, 0, "center" },
  { "clear_dense", 0, 2000, "center" },
  { "one_cloud", 1, 0, "center" },
  { "three_clouds_dense", 3, 2000, "center" },
  { "five_clouds_dense", 5, 2000, "center" },
  { "boundary_clouds", 3, 2000, "edge" },
  { "mixed_32_dense", 32, 2000, "mixed" },
  { "mixed_256_empty", 256, 0, "mixed" },
  { "mixed_256_dense", 256, 2000, "mixed" },
  { "concentric_256_dense", 256, 2000, "center" },
  { "remote_256_dense", 256, 2000, "remote" },
}
print("Synthetic native 64-bit Lua 5.1; excludes native snapshots, injection, rendering and game scheduling.")
print("Timing is diagnostic, not a real-time/FPS guarantee; p95 from small fixed microbenchmark samples.")
print("scenario,clouds,bullets,old_n,new_n,v019_mean_ms,v019_p95_ms,v0192_cold_mean_ms,v0192_cold_p95_ms,v0192_cached_mean_ms,v0192_cached_p95_ms,probes,samples,segments,trajectory_tests")
for _, item in ipairs(scenarios) do
  local name, clouds, bullets, distribution = unpack(item)
  local w = world(clouds, bullets, distribution)
  local old_n = math.max(1, math.min(10, BENCH_OLD_ITERATIONS or 3))
  local new_n = math.max(1, math.min(bullets > 0 and 10 or 30, BENCH_NEW_ITERATIONS or 30))
  local old_mean, old_p95 = 0, 0
  if baseline then old_mean, old_p95 = bench(baseline, oldcfg, w, old_n, clouds, bullets, false, false) end
  local cold_mean, cold_p95, r, probes, samples = bench(current, cfg, w, new_n, clouds, bullets, true, false)
  local warm_mean, warm_p95 = bench(current, cfg, w, new_n, clouds, bullets, true, true)
  print(string.format("%s,%d,%d,%d,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%d,%d,%d", name, clouds, bullets,
    baseline and old_n or 0, new_n, old_mean, old_p95, cold_mean, cold_p95, warm_mean, warm_p95,
    probes, samples, r.movement_segments, r.trajectory_tests))
end
if not baseline then print("NOTE: optional development v0.1.9 snapshot absent; old timing columns are not measured.") end
print("poison_navigation_perf_test: PASS (bounded synthetic work, not live-game acceptance)")
