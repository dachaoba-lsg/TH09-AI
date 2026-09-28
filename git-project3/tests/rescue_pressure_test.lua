-- Rescue observations must reuse only existing, perceived route collisions.
-- Set TH09_RESCUE_DODGE_BASELINE to the unchanged 3.6.1 dodge.lua to also
-- compare every historical output and historical bloom.feedback result.
HitType = { Rect = 0, Circle = 1, RotatableRect = 2 }
ExAttackType = { Medicine = 16 }
local dodge = dofile("dodge.lua")
local checks, cases = 0, 0
local diagnostic = { rescue_observed = true, rescue_routes_total = true,
  rescue_routes_safe = true, rescue_known_ttc = true }

for _,name in ipairs({"poison_cost","poison_nav_active","poison_level","poison_risk","poison_target_x","poison_target_y","poison_probe_count","poison_nav_samples"}) do diagnostic[name]=true end
local function check(value, message)
  checks = checks + 1
  assert(value, message)
end
local function near(value, expected, message)
  check(type(value) == "number" and math.abs(value - expected) < 1e-7,
    message .. ": " .. tostring(value) .. " != " .. tostring(expected))
end
local function test(name, run)
  cases = cases + 1
  run()
  print("PASS " .. name)
end
local function config(attention)
  local cfg = dofile("config.lua").dodge
  -- Isolate the original geometry/admission contract; 3.8 style has its own suite.
  cfg.human_movement.enabled = false
  cfg.poison_navigation.enabled = false
  cfg.attention.enabled = attention == true
  cfg.attention.tracked_threat, cfg.attention.threat_per_second = 120, 90
  cfg.attention.plan_interval = 1
  return cfg
end
local function sensor(protection)
  return { apiVersion = 1, valid = true, state = protection and 3 or 1,
    protectionFrames = protection or 0, timeScale = 1, movementEnabled = true,
    moveScaleX = 1, moveScaleY = 1, baseScaleX = 1, baseScaleY = 1, poisonClouds = {} }
end
local function player(speed, sensed)
  speed = speed == nil and 4 or speed
  return { x = 0, y = 320, speedFast = speed, speedSlow = speed / 2, sensor = sensed,
    hitBodyRect = { type = 0, x = 0, y = 320, width = 4, height = 4 },
    hitBodyCircle = { type = 1, x = 0, y = 320, radius = 2 } }
end
local function circle(id, x, y, vx, vy, radius)
  return { id = id, vx = vx or 0, vy = vy or 0,
    hitBody = { type = 1, x = x, y = y, radius = radius or 2 } }
end
local function laser(y, height)
  return { id = 100, vx = 0, vy = 0,
    hitBody = { type = 2, x = -100, y = y, width = 200, height = height, angle = 0 } }
end
local function world(p, bullets, ex)
  return { player = p or player(), bullets = bullets or {}, enemies = {}, exAttacks = ex or {} }
end
local function contract(out)
  check(out.rescue_observed == true, "observation is explicit")
  check(out.rescue_routes_total > 0 and out.rescue_routes_safe >= 0
    and out.rescue_routes_safe <= out.rescue_routes_total, "route count bounds")
  check(out.collides == (out.rescue_known_ttc >= 0), "TTC follows selected actual hard collision")
  check(out.rescue_routes_safe == 0 or out.rescue_known_ttc == -1,
    "any safe eligible route wins, so narrow safe pools cannot have selected-route TTC")
  check(out.first_collision == nil, "internal candidate timing is not exposed")
end

test("empty routes are known safe, unknown collision time is minus one", function()
  local out = dodge.choose(world(), { frame = 1 }, config())
  contract(out)
  check(out.rescue_routes_total == 17 and out.rescue_routes_safe == 17, "all ordinary candidates")
  near(out.rescue_known_ttc, -1, "no invented collision")
  out = dodge.choose(world(), { frame = 1 }, config(), {})
  check(out.rescue_routes_total == 18 and out.rescue_routes_safe == 18, "intent adds slow-stay")
end)

test("known contact uses actual first entry and includes horizon endpoint", function()
  local p, cfg = player(0), config()
  local out = dodge.choose(world(p, { circle(1, 20, 320, -2, 0) }), {}, cfg)
  contract(out)
  near(out.rescue_known_ttc, 8, "moving circle first contact")
  check(out.rescue_routes_safe == 0, "all stationary routes blocked")
  out = dodge.choose(world(p, { circle(1, 28, 320, -2, 0) }), {}, cfg)
  near(out.rescue_known_ttc, 12, "inclusive forecast endpoint")
  out = dodge.choose(world(p, { circle(1, 20, 320, -2, 0), circle(2, 10, 320, -2, 0) }), {}, cfg)
  near(out.rescue_known_ttc, 3, "earliest contact across objects")
  p.sensor = sensor()
  p.sensor.timeScale = 0.5
  out = dodge.choose(world(p, { circle(1, 20, 320, -2, 0) }), {}, cfg)
  near(out.rescue_known_ttc, 8, "ordinary raw TTC is forecast game time, not slow-time callback count")
end)

test("circle vision removes a fast unseen incoming bullet before timing", function()
  local p, cfg = player(0), config()
  local out = dodge.choose(world(p, { circle(1, 0, 160, 0, 25) }), {}, cfg)
  contract(out)
  check(out.objects_seen == 0 and out.rescue_routes_safe == 17, "outside current circle hidden")
  near(out.rescue_known_ttc, -1, "no outside-circle TTC")
  cfg.vision_radius = 640
  out = dodge.choose(world(p, { circle(1, 0, 160, 0, 25) }), {}, cfg)
  check(out.rescue_known_ttc >= 0, "same visible geometry would intersect")
end)

test("untracked in-circle bullets never supply precise rescue timing", function()
  local p, cfg = player(0), config(true)
  cfg.attention.tracked_threat, cfg.attention.threat_per_second = 0.1, 0
  cfg.attention.reflex_radius = 0
  local out = dodge.choose(world(p, { circle(1, 40, 320, -4, 0) }),
    { frame = 1, attention_config = cfg.attention, attention_tokens = 0 }, cfg)
  contract(out)
  check(out.attention_skipped == 1 and out.attention_tracked == 0, "known attention refusal")
  near(out.rescue_known_ttc, -1, "untracked object has no route TTC")
  check(out.rescue_routes_safe == 17, "unknown hazard is not secretly scored")
  cfg.attention.enabled = false
  out = dodge.choose(world(p, { circle(1, 40, 320, -4, 0) }), { frame = 1 }, cfg)
  near(out.rescue_known_ttc, 9, "admitted geometry confirms hidden timing was omitted")
end)

test("warning lasers are soft; damaging free lasers can report contact", function()
  local cfg, p = config(true), player(0)
  cfg.attention.tracked_threat, cfg.attention.threat_per_second = 0.1, 0
  local out = dodge.choose(world(p, { laser(320, 0) }), {}, cfg)
  contract(out)
  check(out.warning_lasers == 1 and out.attention_free == 1, "visible free warning")
  near(out.rescue_known_ttc, -1, "warning is not a hard collision")
  out = dodge.choose(world(p, { laser(320, 4) }), {}, cfg)
  near(out.rescue_known_ttc, 0, "damaging free laser intersects immediately")
  check(out.rescue_routes_safe == 0, "all fixed routes hit actual beam")
end)

test("dynamic laser timing comes from its existing swept collision", function()
  local cfg, p, state = config(), player(0), { frame = 1 }
  dodge.choose(world(p, { laser(280, 4) }), state, cfg)
  state.frame = 2
  local out = dodge.choose(world(p, { laser(290, 4) }), state, cfg)
  contract(out)
  check(out.dynamic_lasers == 1 and out.rescue_known_ttc > 0 and out.rescue_known_ttc < 12,
    "known moving beam has finite future contact")
  near(out.rescue_known_ttc, 2.6, "swept beam first contact")
end)

test("real protection suppresses contact only until its conservative expiry", function()
  local cfg = config()
  local side = world(player(0, sensor(6)), { circle(1, 0, 320, 0, 0, 100) })
  local out = dodge.choose(side, {}, cfg)
  contract(out)
  near(out.rescue_known_ttc, 5, "raw timer six protects through five updates")
  side.player.sensor.protectionFrames = 20
  out = dodge.choose(side, {}, cfg, { protected_followup = true })
  contract(out)
  check(out.protected_route_checked == true and out.protected_route_collides == true,
    "separate hypothetical tail can collide")
  near(out.rescue_known_ttc, -1, "hypothetical tail does not leak into real short-route timing")
  check(out.rescue_routes_safe == 18, "short routes remain protected despite unusable tail")
  side.player.sensor.protectionFrames = 2
  out = dodge.choose(side, {}, cfg)
  near(out.rescue_known_ttc, 1, "last whole conservative protection update")
  side.player.sensor.protectionFrames = 1.5
  out = dodge.choose(side, {}, cfg)
  near(out.rescue_known_ttc, 0, "fractional raw timer cannot invent a protected half-update")
  side.player.sensor.valid = false
  out = dodge.choose(side, {}, cfg)
  near(out.rescue_known_ttc, 0, "invalid protection cannot delay collision")
end)

test("Medicine remains harmless terrain while its speed affects routes", function()
  local cfg, sensed = config(), sensor()
  cfg.wall_cost, cfg.wall_margin, cfg.boundary_cost, cfg.movement_cost = 0, 0, 0, 0
  cfg.position_cost, cfg.preferred_x, cfg.preferred_y = 1, 1000, 320
  local clear = dodge.choose(world(player(4, sensor())), {}, cfg)
  sensed.moveScaleX, sensed.moveScaleY = 0.4, 0.4
  sensed.poisonClouds = { { x = 0, y = 320, radius = 64, age = 100, framesLeft = 200, active = true } }
  local poison = circle(1, 0, 320, 0, 0, 64)
  poison.type, poison.hittable = 16, true
  local out = dodge.choose(world(player(4, sensed), {}, { poison }), {}, cfg)
  contract(out)
  check(out.name == "fast-right" and clear.name == out.name, "same selected direction through terrain")
  check(out.vx < clear.vx and out.poison_clouds == 1, "real slowdown retained")
  near(out.rescue_known_ttc, -1, "poison does not pretend to damage player")
  check(out.rescue_routes_safe == 17, "cloud does not close safe routes")
end)

test("movement cap counts only currently permitted routes", function()
  local cfg = config()
  local side = world(player(), { circle(1, 14, 320, -1, 0) })
  local unrestricted = dodge.choose(side, {}, cfg)
  check(unrestricted.rescue_routes_safe > 0, "uncapped escape exists")
  cfg.move_change_budget = 0
  local out = dodge.choose(side, { last_move_dir = 7, frame = 1 }, cfg)
  contract(out)
  check(out.rescue_routes_total == 2 and out.rescue_routes_safe == 0, "only slow/fast right are eligible")
  check(out.move_cap_forced and out.move_cap_risk, "cap forces a colliding route")
  check(out.rescue_known_ttc >= 0, "selected capped contact reported")
  out = dodge.choose(side, { last_move_dir = 4, frame = 1 }, cfg, {})
  check(out.rescue_routes_total == 2, "stationary cap keeps stay and slow-stay only")
end)

test("a genuinely narrow channel has safe selected route and unknown contact time", function()
  local cfg = config(true)
  local function wall(id, x, y, width, height, vx)
    return { id = id, vx = vx or 0, vy = 0,
      hitBody = { type = 0, x = x, y = y, width = width, height = height } }
  end
  local side = world(player(), { wall(1, 0, 310, 240, 2), wall(2, 0, 330, 240, 2),
    wall(3, -20, 320, 4, 40, 2) })
  local out = dodge.choose(side, { frame = 1 }, cfg, {})
  contract(out)
  check(out.rescue_routes_total == 18 and out.rescue_routes_safe == 2,
    "known walls close all except slow/fast right")
  check(out.attention_credit > 100 and out.attention_skipped == 0,
    "narrow channel is independent of exhausted attention")
  near(out.rescue_known_ttc, -1, "safe selected route never invents TTC for rejected routes")
  cfg.move_change_budget = 0
  out = dodge.choose(side, { frame = 1, last_move_dir = 7 }, cfg, {})
  check(out.rescue_routes_total == 2 and out.rescue_routes_safe == 2,
    "a cap-only two-route pool may be wholly safe, unlike two out of eighteen")
end)

test("height and panic restrictions remove prohibited directions from counts", function()
  local cfg = config()
  local out = dodge.choose(world(), {}, cfg, { min_y = 320 })
  contract(out)
  check(out.rescue_routes_total == 12 and out.rescue_routes_safe == 12, "six upward routes excluded")
  cfg = config(true)
  cfg.attention.tracked_threat, cfg.attention.threat_per_second = 0.1, 0
  cfg.attention.reflex_radius, cfg.attention.blind_urgent_limit, cfg.attention.overload_frames = 0, 1, 1
  out = dodge.choose(world(player(), { circle(1, 40, 320, -4, 0) }),
    { frame = 1, attention_config = cfg.attention, attention_tokens = 0 }, cfg, {})
  contract(out)
  check(out.attention_panic and out.rescue_routes_total == 6, "panic permits four cardinal and two stationary routes")
  near(out.rescue_known_ttc, -1, "panic does not reveal untracked bullet timing")
end)

local function copy(value, strip)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do
    if not strip or not diagnostic[key] then result[key] = copy(item, false) end
  end
  return result
end
local function same(actual, expected, path)
  check(type(actual) == type(expected), path .. " type")
  if type(expected) ~= "table" then
    check(actual == expected, path .. " value")
    return
  end
  for key, value in pairs(expected) do same(actual[key], value, path .. "." .. tostring(key)) end
  for key in pairs(actual) do check(expected[key] ~= nil, path .. " unexpected " .. tostring(key)) end
end
local baseline_path = os and os.getenv and os.getenv("TH09_RESCUE_DODGE_BASELINE")
if baseline_path and baseline_path ~= "" then
  local baseline = dofile(baseline_path)
  local baseline_bloom = dofile((baseline_path:gsub("dodge%.lua$", "bloom.lua")))
  test("original movement output, planner state and old policy feedback stay identical over 1200 updates", function()
    local bloom_cfg = dofile("config.lua").bloom
    for scenario = 1, 10 do
      local cfg, current_state, prior_state, current_feedback, prior_feedback = config(scenario ~= 10), {}, {}, {}, {}
      cfg.attention.tracked_threat = scenario % 3 == 0 and 8 or 120
      cfg.attention.threat_per_second = scenario % 4 == 0 and 0 or 90
      cfg.attention.plan_interval = scenario % 2 == 0 and 1 or 6
      local p = player()
      for frame = 1, 120 do
        current_state.frame, prior_state.frame = frame, frame
        local bullets, ex = {}, {}
        for index = 1, 44 do
          if (frame + index) % 11 ~= 0 then
            local generation = math.floor((frame + index * 3) / 37)
            local x = ((index * 29 + frame * (index % 5 - 2)) % 350) - 175
            local y = ((index * 31 + frame * (1 + index % 5)) % 448)
            local object = circle(index + generation * 100, x, y, index % 7 - 3, 0.75 + index % 8)
            if index % 4 == 0 then object.hitBody = { type = 0, x = x, y = y, width = 6 + index % 5, height = 8 } end
            bullets[#bullets + 1] = object
          end
        end
        local beam = laser(275, frame % 25 < 6 and 0 or 4)
        beam.hitBody.width, beam.hitBody.angle = 180 + frame % 31, frame * 0.003
        bullets[#bullets + 1] = beam
        for index = 1, 4 do
          ex[#ex + 1] = { id = 1000 + index, hittable = frame % 9 ~= 0,
            vx = index % 2 == 0 and 3 or -2, vy = 1 + index,
            hitBody = { type = 2, x = -170 + index * 23, y = 220 + (frame * 2 + index * 17) % 170,
              width = 96 + index * 21, height = 4, angle = index * 0.15 } }
        end
        if scenario % 3 == 0 then
          p.sensor = sensor(frame % 40 < 15 and (18 - frame % 15) or nil)
          p.sensor.moveScaleX, p.sensor.moveScaleY = 0.4, 0.4
          p.sensor.poisonClouds = { { x = 0, y = 315, radius = 64, framesLeft = 120, age = 50, active = true } }
          local poison = circle(1100, 0, 315, 0, 0, 64)
          poison.type, poison.hittable = 16, true
          ex[#ex + 1] = poison
        end
        local side = world(p, bullets, ex)
        local intent = { focus = frame % 40 < 12, min_y = 150,
          target_x = (scenario % 3 - 1) * 48, target_y = 280 + scenario * 8,
          protected_followup = scenario % 3 == 0 and frame % 40 < 15 }
        local current = dodge.choose(side, current_state, cfg, intent)
        local original = baseline.choose(side, prior_state, cfg, intent)
        contract(current)
        local stripped = copy(current, true)
        same(stripped, original, "output")
        same(current_state, prior_state, "planner state")
        current_feedback.paused, prior_feedback.paused = frame % 29 == 0, frame % 29 == 0
        baseline_bloom.feedback(current_feedback, stripped, bloom_cfg)
        baseline_bloom.feedback(prior_feedback, original, bloom_cfg)
        same(current_feedback, prior_feedback, "old policy feedback")
        p.x = math.max(-130, math.min(130, p.x + original.vx))
        p.y = math.max(160, math.min(425, p.y + original.vy))
        p.hitBodyRect.x, p.hitBodyRect.y = p.x, p.y
        p.hitBodyCircle.x, p.hitBodyCircle.y = p.x, p.y
      end
    end
  end)
else
  print("Baseline comparison not requested; set TH09_RESCUE_DODGE_BASELINE to unchanged 3.6.1 dodge.lua.")
end
print(string.format("Rescue pressure: %d cases / %d checks passed", cases, checks))
