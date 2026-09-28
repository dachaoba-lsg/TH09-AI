-- Read-only admission diagnostics. Run with tests/run_native_lua.py.
-- Optional TH09_DODGE_BASELINE points to an unmodified 3.5 dodge.lua for
-- deterministic multi-frame equivalence, without shipping a duplicate module.
HitType = { Rect = 0, Circle = 1, RotatableRect = 2 }
ExAttackType = { Medicine = 16 }
local dodge = dofile("dodge.lua")
local bloom = dofile("bloom.lua")
local checks, cases = 0, 0
local diagnostic = {
  attention_scanned = true, attention_waiting_scan_count = true,
  attention_credit_blocked_count = true, attention_capacity_blocked_count = true,
  rescue_observed = true, rescue_routes_total = true,
  rescue_routes_safe = true, rescue_known_ttc = true,
}

for _,name in ipairs({"poison_cost","poison_nav_active","poison_level","poison_risk","poison_target_x","poison_target_y","poison_probe_count","poison_nav_samples"}) do diagnostic[name]=true end
local function check(value, message)
  checks = checks + 1
  assert(value, message)
end
local function test(name, run)
  cases = cases + 1
  run()
  print("PASS " .. name)
end
local function config(capacity, rate, interval)
  local cfg = dofile("config.lua").dodge
  -- Isolate the original geometry/admission contract; 3.8 style has its own suite.
  cfg.human_movement.enabled = false
  cfg.poison_navigation.enabled = false
  cfg.attention.tracked_threat = capacity or 120
  cfg.attention.threat_per_second = rate or 90
  cfg.attention.plan_interval = interval or 6
  return cfg
end
local function player()
  return { x = 0, y = 320, speedFast = 4, speedSlow = 2,
    hitBodyRect = { type = 0, x = 0, y = 320, width = 4, height = 4 },
    hitBodyCircle = { type = 1, x = 0, y = 320, radius = 2 } }
end
local function circle(id, x, y, speed)
  return { id = id, vx = 0, vy = speed or 1.5,
    hitBody = { type = 1, x = x or 0, y = y or 290, radius = 2 } }
end
local function world(bullets, ex, p)
  return { player = p or player(), bullets = bullets or {}, enemies = {}, exAttacks = ex or {} }
end
local function diagnosticEquals(out, scanned, waiting, credit, capacity)
  check(out.attention_scanned == scanned, "scan flag")
  check(out.attention_waiting_scan_count == waiting, "waiting snapshot count")
  check(out.attention_credit_blocked_count == credit, "credit predicate count")
  check(out.attention_capacity_blocked_count == capacity, "capacity predicate count")
end

test("new relevant entries wait only between acquisition scans", function()
  local cfg, state = config(), { frame = 1 }
  diagnosticEquals(dodge.choose(world(), state, cfg), true, 0, 0, 0)
  state.frame = 2
  local side = world({ circle(1) })
  local waiting = dodge.choose(side, state, cfg)
  diagnosticEquals(waiting, false, 1, 0, 0)
  check(waiting.attention_skipped == 1 and waiting.attention_credit == 120, "ample credit still waits")
  state.frame = 7
  local admitted = dodge.choose(side, state, cfg)
  diagnosticEquals(admitted, true, 0, 0, 0)
  check(admitted.attention_tracked == 1, "scan actually admits the object")
end)

test("credit rejection with capacity available, then old rejection waits", function()
  local cfg = config(120, 0, 6)
  local state = { frame = 1, attention_config = cfg.attention, attention_tokens = 0 }
  local side = world({ circle(1), circle(2, 0, 285) })
  local rejected = dodge.choose(side, state, cfg)
  diagnosticEquals(rejected, true, 0, 2, 0)
  check(rejected.attention_tracked == 0, "unfunded objects stay untracked")
  state.frame = 2
  diagnosticEquals(dodge.choose(side, state, cfg), false, 2, 0, 0)
end)

test("continuing identities can fail capacity without failing credit", function()
  local cfg = config(2, 0)
  local state = { frame = 1, attention_config = cfg.attention, attention_tokens = 2,
    attention_set = { ["bullet:1"] = "bullet", ["bullet:2"] = "bullet", ["bullet:3"] = "bullet" } }
  local out = dodge.choose(world({ circle(1), circle(2, 0, 285), circle(3, 0, 280) }), state, cfg)
  diagnosticEquals(out, true, 0, 0, 1)
  check(out.attention_tracked == 2 and out.attention_credit == 2, "retained objects do not repay acquisition")
end)

test("rejection predicates may overlap after earlier admissions", function()
  local out = dodge.choose(world({ circle(1), circle(2, 0, 285), circle(3, 0, 280) }),
    { frame = 1 }, config(2, 0))
  diagnosticEquals(out, true, 0, 1, 1)
  check(out.attention_skipped == 1, "two failed predicates still describe one skipped object")
end)

test("a successful reflex override is not reported as rejected", function()
  local cfg = config(1, 0)
  local state = { frame = 1, attention_config = cfg.attention, attention_tokens = 0 }
  local out = dodge.choose(world({ circle(1, 0, 312) }), state, cfg)
  diagnosticEquals(out, true, 0, 0, 0)
  check(out.attention_tracked == 1 and out.attention_credit == 0, "reflex is admitted without credit")
end)

test("exhausted reflex slots expose the final failed predicates", function()
  local cfg = config(1, 0)
  local state = { frame = 1, attention_config = cfg.attention, attention_tokens = 0 }
  local out = dodge.choose(world({ circle(1, 0, 312), circle(2, 0, 311) }), state, cfg)
  diagnosticEquals(out, true, 0, 1, 1)
  check(out.attention_tracked == 1, "reflex slot remains bounded")
end)

test("free shapes, out-of-circle entries and disabled attention do not count", function()
  local cfg = config(1, 0)
  local state = { frame = 1, attention_config = cfg.attention, attention_tokens = 0 }
  local laser = { id = 20, vx = 0, vy = 0,
    hitBody = { type = 2, x = -120, y = 250, width = 240, height = 0, angle = 0 } }
  local poison = { id = 21, type = 16, hittable = true, vx = 0, vy = 0,
    hitBody = { type = 1, x = 0, y = 300, radius = 32 } }
  local side = world({ circle(1, 0, 20), laser }, { poison })
  diagnosticEquals(dodge.choose(side, state, cfg), true, 0, 0, 0)
  cfg.attention.enabled = false
  diagnosticEquals(dodge.choose(world({ circle(1) }), { frame = 1 }, cfg), false, 0, 0, 0)
end)

test("frame rewind and configuration changes report the actual fresh scan", function()
  local cfg, state = config(), { frame = 20 }
  dodge.choose(world(), state, cfg)
  state.frame = 19
  diagnosticEquals(dodge.choose(world({ circle(1) }), state, cfg), true, 0, 0, 0)
  state.frame = 20
  diagnosticEquals(dodge.choose(world({ circle(1) }), state, config()), true, 0, 0, 0)
end)

-- Compare every original output recursively, including route segments, and
-- legacy bloom.feedback states with new rescue evidence removed. The rescue
-- policy is tested separately and intentionally consumes that new evidence.
local function same(actual, expected, path, allow_diagnostics)
  check(type(actual) == type(expected), path .. " type")
  if type(expected) ~= "table" then
    check(actual == expected, path .. " value")
    return
  end
  for key, value in pairs(expected) do
    same(actual[key], value, path .. "." .. tostring(key), false)
  end
  for key in pairs(actual) do
    check(expected[key] ~= nil or allow_diagnostics and diagnostic[key], path .. " unexpected " .. tostring(key))
  end
end
local baseline_path = os and os.getenv and os.getenv("TH09_DODGE_BASELINE")
if baseline_path and baseline_path ~= "" then
  local baseline = dofile(baseline_path)
  test("unmodified 3.5 decisions and bloom feedback remain identical across 1200 callbacks", function()
    local bloom_cfg = dofile("config.lua").bloom
    for scenario = 1, 10 do
      local cfg = config(scenario % 3 == 0 and 8 or 120, scenario % 4 == 0 and 0 or 90,
        scenario % 2 == 0 and 1 or 6)
      if scenario == 10 then cfg.attention.enabled = false end
      local new_state, old_state, new_feedback, old_feedback = {}, {}, {}, {}
      local p = player()
      for frame = 1, 120 do
        new_state.frame, old_state.frame = frame, frame
        local bullets, ex = {}, {}
        -- Recreated tables, stable IDs, births/deaths and reused array slots.
        for index = 1, 44 do
          if (frame + index) % 11 ~= 0 then
            local generation = math.floor((frame + index * 3) / 37)
            local x = ((index * 29 + frame * (index % 5 - 2)) % 350) - 175
            local y = ((index * 31 + frame * (1 + index % 5)) % 448)
            local object = circle(index + generation * 100, x, y, 0.75 + index % 8)
            object.vx = index % 7 - 3
            if index % 4 == 0 then
              object.hitBody = { type = 0, x = x, y = y, width = 6 + index % 5, height = 8 }
            end
            bullets[#bullets + 1] = object
          end
        end
        bullets[#bullets + 1] = { id = 900, vx = 0, vy = 0,
          hitBody = { type = 2, x = -100, y = 275, width = 180 + frame % 31,
            height = frame % 25 < 6 and 0 or 4, angle = frame * 0.003 } }
        for index = 1, 4 do
          ex[#ex + 1] = { id = 1000 + index, hittable = frame % 9 ~= 0,
            vx = index % 2 == 0 and 3 or -2, vy = 1 + index,
            hitBody = { type = 2, x = -170 + index * 23, y = 220 + (frame * 2 + index * 17) % 170,
              width = 96 + index * 21, height = 4, angle = index * 0.15 } }
        end
        if scenario % 3 == 0 then
          p.sensor = { valid = true, state = frame % 40 < 15 and 3 or 0,
            protectionFrames = 18 - frame % 15, moveScaleX = 0.7, moveScaleY = 0.7,
            baseScaleX = 1, baseScaleY = 1,
            poisonClouds = { { x = 0, y = 315, radius = 64, framesLeft = 120, age = 50, active = true } } }
          ex[#ex + 1] = { id = 1100, type = 16, hittable = true, vx = 0, vy = 0,
            hitBody = { type = 1, x = 0, y = 315, radius = 64 } }
        end
        local side = world(bullets, ex, p)
        local intent = { focus = frame % 40 < 12, min_y = 150,
          target_x = (scenario % 3 - 1) * 48, target_y = 280 + scenario * 8,
          protected_followup = scenario % 3 == 0 and frame % 40 < 15 }
        local current = dodge.choose(side, new_state, cfg, intent)
        local original = baseline.choose(side, old_state, cfg, intent)
        same(current, original, "scenario" .. scenario .. ".frame" .. frame, true)
        new_feedback.paused, old_feedback.paused = frame % 29 == 0, frame % 29 == 0
        local legacy_current = {}
        for key, value in pairs(current) do
          if not key:match('^rescue_') then legacy_current[key] = value end
        end
        bloom.feedback(new_feedback, legacy_current, bloom_cfg)
        bloom.feedback(old_feedback, original, bloom_cfg)
        same(new_feedback, old_feedback, "feedback", false)
        p.x = math.max(-130, math.min(130, p.x + original.vx))
        p.y = math.max(160, math.min(425, p.y + original.vy))
        p.hitBodyRect.x, p.hitBodyRect.y = p.x, p.y
        p.hitBodyCircle.x, p.hitBodyCircle.y = p.x, p.y
      end
    end
  end)
else
  print("Baseline comparison not requested; set TH09_DODGE_BASELINE to an unmodified 3.5 dodge.lua.")
end
print(string.format("Attention diagnostics: %d cases / %d checks passed", cases, checks))
