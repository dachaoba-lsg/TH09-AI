-- Run from the project root with:
-- python tests/run_native_lua.py tests/bloom_perf_test.lua
-- Fixed synthetic snapshots, NOT a game/charge/energy simulator. No game process
-- is opened. This measures the real observer + policy + dodge + feedback path.
-- Native 64-bit non-JIT Lua timing excludes the 32-bit injected runtime, native
-- memory export, input hooks, CSV/disk I/O and game/rendering costs.

HitType = { Rect = 0, Circle = 1, RotatableRect = 2 }
ExAttackType = { Medicine = 16 }
-- Confirm the geometry enum against the checked-in upstream definition.
do
  local file = assert(io.open("../../vendor/ka_ai_duka-src/inject/hitTest.h", "r"))
  local text = file:read("*a"); file:close()
  assert(text:match("Hit_Rect%s*=%s*0%s*,%s*Hit_Circle%s*,%s*Hit_RotatableRect"),
    "upstream HitType values changed; update the fixture explicitly")
end
hitTest = dofile("../../tests/upstream_hit_test.lua")
local observer = dofile("bloom_observer.lua")
local bloom = dofile("bloom.lua")
local dodge = dofile("dodge.lua")
local keys = dofile("keyutils.lua")
local cfg = dofile("config.lua")
local now = perf_now or os.clock
local iterations = math.max(1, math.floor(BENCH_NEW_ITERATIONS or 50))

local function body(kind, x, y)
  if kind == HitType.Circle then return { type = kind, x = x, y = y, radius = 3 } end
  return { type = kind, x = x, y = y, width = 6, height = 6 }
end
local function world(enemy_count, bullet_count, dense, mixed)
  local p = { x = 0, y = 320, character = 13, life = 10,
    currentCharge = 0, currentChargeMax = 400, chargeSpeed = 10,
    speedFast = 4, speedSlow = 2, spellPoint = 750000, combo = 30,
    hitBodyRect = { type = HitType.Rect, x = 0, y = 320, width = 4, height = 4 },
    hitBodyCircle = { type = HitType.Circle, x = 0, y = 320, radius = 2 },
    sensor = { apiVersion = 1, valid = true, state = 0,
      baseScaleX = 1, baseScaleY = 1, moveScaleX = 1, moveScaleY = 1,
      movementEnabled = true, cutIn = false, timeScale = 1,
      canCharge = true, chargeWarmupFrames = 0, chargeBlockFrames = 0,
      protectionFrames = 0, poisonClouds = {} } }
  local w = { player = p, enemies = {}, bullets = {}, exAttacks = {} }
  for i = 1, enemy_count do
    local x = dense and ((i * 17) % 96 - 48) or ((i * 31) % 240 - 120)
    local y = dense and (258 + (i * 13) % 64) or (90 + (i * 23) % 210)
    local spirit = i % 5 == 0
    w.enemies[i] = { id = i, enabled = true, x = x, y = y,
      vx = math.sin(i * 0.3) * 0.15, vy = 0.4,
      isSpirit = spirit, isActivatedSpirit = spirit and i % 10 == 0,
      isBoss = false, isLily = false, isPseudoEnemy = false,
      hitBody = body(HitType.Circle, x, y) }
  end
  for i = 1, bullet_count do
    local x = dense and ((i * 37) % 88 - 44) or ((i * 37) % 272 - 136)
    local y = dense and (276 + (i * 53) % 84) or (16 + (i * 53) % 416)
    w.bullets[i] = { id = 1000 + i, enabled = true, x = x, y = y,
      vx = math.sin(i * 0.5) * 1.5, vy = 0.5 + i % 7 / 3,
      isErasable = i % 4 ~= 0,
      hitBody = body(i % 3 == 0 and HitType.Circle or HitType.Rect, x, y) }
  end
  if mixed then
    local cloud = { x = -62, y = 320, radius = 64,
      age = 100, framesLeft = 200, active = true }
    p.sensor.poisonClouds = { cloud }
    p.sensor.moveScaleX, p.sensor.moveScaleY = 0.4000000059604645, 0.4000000059604645
    w.exAttacks[1] = { id = 5000, type = ExAttackType.Medicine,
      x = cloud.x, y = cloud.y, vx = 0, vy = 0, hittable = true,
      hitBody = { type = HitType.Circle, x = cloud.x, y = cloud.y, radius = 64 } }
    -- Replace four entries, preserving the advertised total bullet count.
    -- The snapshot and angles stay fixed: this is not a rotating-laser replay.
    for i = 1, 4 do
      local x, y = -100 + i * 42, 110
      w.bullets[bullet_count - 4 + i] = { id = 4000 + i, enabled = true,
        x = x, y = y, vx = 0, vy = 0, isErasable = false,
        hitBody = { type = HitType.RotatableRect, x = x, y = y,
          width = 250, height = i == 1 and 0 or 4,
          angle = math.pi / 2 + (i - 2) * 0.06 } }
    end
  end
  return w
end

local function pipeline(w, state, active)
  active = active or cfg
  -- Match main.lua: both resource decisions and dodge use the same current
  -- circular view. In particular observer timing must include this boundary.
  local perceived_started = now()
  w = dodge.perceive(w, active.dodge)
  state.frame = state.frame + 1
  state.observer.lock_ids = state.bloom.target_level and state.bloom.attack_ids or nil
  local observer_cfg = {}
  for k, v in pairs(active.bloom.observer) do observer_cfg[k] = v end
  local remaining = math.max(0, (state.bloom.target_level or 2) * 100 - w.player.currentCharge)
  observer_cfg.prediction_frames = math.max(12, math.min(60,
    remaining / w.player.chargeSpeed + w.player.sensor.chargeWarmupFrames))
  local started = perceived_started
  local obs = observer.observe(w, state.observer, observer_cfg)
  local observed = now()
  local before_frame = state.bloom.frame or 0
  local before_index = state.bloom.focus_index or 0
  local plan = bloom.update(w, state.bloom, active.bloom, obs)
  local planned = now()
  local movement = dodge.choose(w, state, active.dodge, plan.intent)
  local moved = now()
  bloom.feedback(state.bloom, movement, active.bloom)
  local finished = now()

  -- Inspect real work and state effects, outside the timed algorithm interval.
  assert(obs.valid and obs.stats.invalid_objects == 0 and not obs.stats.truncated,
    "malformed or truncated observer benchmark fixture")
  assert(obs.stats.enemies_seen == #w.enemies and obs.stats.bullets_seen == #w.bullets,
    "observer did not inspect the complete scene")
  assert(obs.stats.enemy_pair_tests > 0 and obs.stats.enemy_pair_tests <= #w.enemies * (#w.enemies - 1),
    "two-snapshot enemy-pair work exceeded the bounded quadratic scan")
  -- 3.1: the attention limit deliberately leaves objects unscored, so the
  -- complete-scene check becomes a bound: every object is either scored or
  -- reported as an unseen imminent threat; nothing may be invented.
  assert(movement.sensor_valid == 1 and movement.objects_seen >= #w.enemies
    and movement.objects_seen + movement.attention_blind_urgent <= #w.enemies + #w.bullets + #w.exAttacks,
    string.format("dodge bypassed valid sensing or invented scene entries: sensor %s seen %s blind %s free %s tracked %s entries %s total %d enemies %d bullets %d",
      tostring(movement.sensor_valid), tostring(movement.objects_seen), tostring(movement.attention_blind_urgent),
      tostring(movement.attention_free), tostring(movement.attention_tracked), tostring(movement.attention_entries),
      #w.enemies + #w.bullets + #w.exAttacks, #w.enemies, #w.bullets))
  assert(movement.trajectory_tests > 0 and movement.movement_segments >= 18,
    "intent-aware dodge did not run real candidate geometry")
  assert(movement.movement_segments <= 18 * 14, "candidate terrain segmentation became unbounded")
  assert(state.bloom.frame == before_frame + 1, "policy returned without processing the active snapshot")
  assert(state.bloom.focus_index == before_index % cfg.bloom.focus_budget_window + 1,
    "feedback did not update the actual Shift-history budget")
  assert(plan.target_level >= 0 and plan.target_level <= 2, "policy selected C3/C4")
  assert(math.floor(movement.key / 2) % 2 == 0, "dodge produced X before the defensive key filter")
  assert(math.floor(keys.withShot(movement.key, plan.press_z) / 2) % 2 == 0, "integrated output contains X")
  if #w.exAttacks > 0 then
    assert(movement.poison_clouds == 1 and movement.laser_count == 4,
      "mixed fixture did not exercise both poison and laser perception")
  end
  if active ~= cfg then
    assert(movement.attention_tracked == 0 and movement.attention_blind_urgent == 0,
      "the comparison scenario must run with the attention limit disabled")
  end
  return { observed - started, planned - observed, moved - planned, finished - moved,
    finished - started }, obs, plan, movement
end

local function benchmark(name, w, active)
  local state = { frame = 0, bloom = {}, observer = {} }
  for _ = 1, 3 do pipeline(w, state, active) end
  collectgarbage("collect")
  local totals, calls, peak = { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0 }, 0
  local obs, plan, movement, elapsed
  for _ = 1, iterations do
    -- The fixed scene/charge snapshot does not advance the real game. State is
    -- retained for actual observer locking, policy memory and laser history.
    elapsed, obs, plan, movement = pipeline(w, state, active)
    for i = 1, 5 do totals[i] = totals[i] + elapsed[i] end
    for i = 1, 4 do calls[i] = calls[i] + 1 end
    peak = math.max(peak, elapsed[5] * 1000)
  end
  for i = 1, 5 do totals[i] = totals[i] * 1000 / iterations end
  for i = 1, 4 do assert(calls[i] == iterations, "pipeline stage was skipped") end
  -- Deliberately loose runaway guard, not a 16.67 ms target or FPS promise.
  assert(totals[5] < 1000, "pipeline exceeded the 1000 ms mean catastrophic-regression guard")
  print(string.format("%s,%d,%d,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d/%d/%d/%d,%d,%d,%d,%d,%d,%d,%d,%s",
    name, #w.enemies, #w.bullets, iterations,
    totals[1], totals[2], totals[3], totals[4], totals[5], peak,
    calls[1], calls[2], calls[3], calls[4], obs.stats.enemy_pair_tests,
    movement.objects_seen, movement.objects_relevant, movement.trajectory_tests,
    movement.movement_segments, movement.attention_tracked, movement.attention_blind_urgent, plan.phase))
end

print("Integrated synthetic microbenchmark: native 64-bit Lua 5.1; no JIT, no 32-bit injection/engine/render/CSV cost.")
print("Fixed snapshots do not simulate charge, damage, recharge or gameplay. Run serially; means are not a 60 FPS guarantee.")
print("scenario,enemies,bullets,iterations,observe_ms,policy_ms,dodge_ms,feedback_ms,total_ms,peak_ms,stage_calls_o_p_d_f,enemy_pairs,seen,relevant,trajectories,segments,attention_tracked,attention_blind,last_phase")
for _, counts in ipairs({ {16, 200}, {64, 1000}, {128, 2000} }) do
  benchmark("distributed", world(counts[1], counts[2], false, false))
  benchmark("dense_near", world(counts[1], counts[2], true, false))
end
benchmark("poison_lasers", world(64, 1000, false, true))
-- 3.1 comparison row: the same dense fixture with the attention limit
-- disabled, so the 2.0.x-3.0.1 numbers stay comparable.
local no_attention = dofile("config.lua")
no_attention.dodge.attention = { enabled = false }
benchmark("dense_near_attention_off", world(128, 2000, true, false), no_attention)
print("bloom_perf_test: PASS (8 synthetic scenes; real observer/policy/dodge/feedback on every iteration; no X or C3/C4 plan)")
