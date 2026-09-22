-- Synthetic terrain/protection tests. No game process, input or native memory.
HitType = { Rect = 0, Circle = 1, RotatableRect = 2 }
ExAttackType = { Medicine = 16, Eiki = 19, Reimu = 0 }
local dodge = dofile("dodge.lua")
local function config()
  local cfg = dofile("config.lua").dodge
  cfg.wall_cost, cfg.wall_margin, cfg.boundary_cost, cfg.movement_cost = 0, 0, 0, 0
  cfg.safety_margin, cfg.near_miss_cost = 0, 140
  cfg.position_cost, cfg.preferred_x, cfg.preferred_y = 1, 1000, 320
  return cfg
end
local function sensor(sx, sy, clouds)
  return { apiVersion = 1, valid = true, state = 1, protectionFrames = 0,
    baseScaleX = 1, baseScaleY = 1, moveScaleX = sx or 1, moveScaleY = sy or sx or 1,
    poisonClouds = clouds or {} }
end
local function player(s, x, y)
  x, y = x or 0, y or 320
  return { x = x, y = y, speedFast = 4, speedSlow = 2, sensor = s,
    hitBodyRect = { type = HitType.Rect, x = x, y = y, width = 4, height = 4 },
    hitBodyCircle = { type = HitType.Circle, x = x, y = y, radius = 2 } }
end
local function world(p, bullets, ex)
  return { player = p, bullets = bullets or {}, enemies = {}, exAttacks = ex or {} }
end
local function cloud(x, y, age)
  age = age or 100
  return { x = x, y = y or 320, radius = 64, age = age,
    framesLeft = 300 - age, active = age > 20 and age < 300 }
end
local function rect(x, y, vx, vy, width, height)
  return { vx = vx or 0, vy = vy or 0,
    hitBody = { type = HitType.Rect, x = x, y = y, width = width or 4, height = height or 4 } }
end
local function endpoint(choice)
  local segment = choice.segments[#choice.segments]
  return segment.x + segment.vx * segment.duration, segment.y + segment.vy * segment.duration
end
local function near(actual, expected, message)
  assert(actual and math.abs(actual - expected) < 1e-6,
    (message or "value") .. ": " .. tostring(actual) .. " != " .. tostring(expected))
end
local function right(s, expected, message, p, cfg)
  local r = dodge.choose(world(p or player(s)), {}, cfg or config())
  assert(r.name == "fast-right", message .. ": preferred clear direction changed to " .. r.name)
  near(endpoint(r), expected, message)
  assert(not r.collides, message .. ": terrain became a hit")
  return r
end

-- No sensor remains the historical analytical path; valid non-poison sensor
-- does not split trajectories or double-multiply the character's base speed.
right(nil, 48, "legacy fallback")
local normal = right(sensor(), 48, "unpoisoned")
assert(#normal.segments == 1 and normal.movement_segments == 17)
local r = right(sensor(0.4, 0.4, { cloud(0) }), 19.2, "single cloud")
near(r.vx, 1.6, "current effective X speed")
assert(#r.segments == 1, "constant poison unnecessarily split every bullet test")
right(sensor(0.16, 0.16, { cloud(0), cloud(0) }), 7.68, "stacked clouds")

-- Centre-only strict radius, discrete position updates and finite lifetime.
right(sensor(1, 1, { cloud(70) }), 24, "enter cloud after crossing radius")
right(sensor(0.4, 0.4, { cloud(-62) }), 43.2, "leave cloud and regain base speed")
right(sensor(0.4, 0.4, { cloud(0, 320, 299) }), 45.6, "cloud expires after first update")
right(sensor(1, 1, { cloud(0, 320, 20) }), 21.6, "cloud activates after age20")
right(sensor(1, 1, { cloud(0, 320, 0) }), 48, "young cloud not active within horizon")
right(sensor(1, 1, { cloud(-64) }), 48, "exact radius is outside")

-- The current snapshot is authoritative even when its poison state differs
-- from the future geometric count. Non-poison axis factors remain separate.
right(sensor(0.2, 0.2, {}), 44.8, "do not infer current multiplier from cloud count")
local anisotropic = sensor(0.8, 0.2, { cloud(0) })
anisotropic.baseScaleX, anisotropic.baseScaleY = 2, 0.5
right(anisotropic, 38.4, "preserve independent base X factor")
local invalid = sensor(0.01); invalid.valid = false
right(invalid, 48, "invalid sensor cannot invent slowdown")

-- Never turn Medicine's compatibility hitBody into a solid damaging wall.
local ex = { type = ExAttackType.Medicine, enabled = true, hittable = true,
  hitBody = { type = HitType.Circle, x = 0, y = 320, radius = 64 } }
local p = player(sensor(0.4, 0.4, { cloud(0) }))
local w = world(p, {}, { ex })
r = dodge.choose(w, {}, config())
assert(not r.collides and r.objects_relevant == 0 and r.objects_seen == 1)
assert(r.name == "fast-right", "harmless cloud prevented travelling through it")
ex.type = ExAttackType.Eiki
r = dodge.choose(w, {}, config())
assert(r.collides, "other EX damaging circles were accidentally made harmless")
ex.type = ExAttackType.Reimu
assert(dodge.choose(w, {}, config()).collides)
local saved_types = ExAttackType
ExAttackType, ex.type = {}, nil
assert(dodge.choose(w, {}, config()).collides, "missing Medicine enum matched missing EX type")
ExAttackType = saved_types

-- Regression fixture: the old planner claimed a slow sidestep could clear a
-- falling bullet, although poison reduced that sidestep to 40% of its speed.
do
  local cfg = dofile("config.lua").dodge
  cfg.safety_margin, cfg.near_miss_cost, cfg.position_cost = 0, 0, 0
  local poisoned = player(sensor(0.4, 0.4, { cloud(0) }))
  local falling = rect(0, 300, 0, 4)
  local chosen = dodge.choose(world(poisoned, { falling }), {}, cfg)
  assert(not chosen.collides, "poison-aware route has no safe candidate")
  for _, segment in ipairs(chosen.segments) do
    local first = dodge.rectInterval(segment.x, segment.y - 300 - 4 * segment.start,
      segment.vx, segment.vy - 4, -4, 4, -4, 4, segment.duration)
    assert(not first, "chosen poisoned path still hits falling bullet")
  end
  local old_path = "../../work/before-019-poison-20260920/src/ai/dodge.lua"
  local old_file = io.open(old_path, "r")
  if old_file then
    old_file:close()
    local old = dofile(old_path).choose(world(poisoned, { falling }), {}, cfg)
    assert(not old.collides, "old fixture no longer claims an escape")
    assert(dodge.rectInterval(0, 20, old.vx * 0.4, old.vy * 0.4 - 4,
      -4, 4, -4, 4, 12), "old escape did not fail after actual poison slowdown")
  end
end

-- Poison-aware candidate sweep remains inside walls, with bounded work.
local edge_cfg = config(); edge_cfg.preferred_y = 1000
p = player(sensor(0.4, 0.4, { cloud(134, 430) }), 134, 430)
r = dodge.choose(world(p), {}, edge_cfg)
for _, part in ipairs(r.segments) do
  assert(part.x >= -136 and part.y <= 432 and part.x + part.vx * part.duration <= 136 + 1e-7
    and part.y + part.vy * part.duration <= 432 + 1e-7, "poison path crossed wall")
end
assert(r.movement_segments <= 17 * 14, "poison generated unbounded trajectory segments")

-- Remaining state3 protection is sensed, never inferred from C level or
-- animation. A bullet crossing wholly before expiry does not cause a hard hit.
local function protected(state, frames, valid, bullet)
  local s = sensor(); s.state, s.protectionFrames, s.valid = state, frames, valid ~= false
  local immobile = player(s); immobile.speedFast, immobile.speedSlow = 0, 0
  return dodge.choose(world(immobile, { bullet or rect(-20, 320, 10) }), {}, config())
end
r = protected(3, 4)
assert(not r.collides and r.danger == 0, "protected crossing remained hard damage")
assert(protected(3, 2).collides, "overlap after expiry was ignored")
assert(protected(3, 2.6).collides, "contact exactly on conservative expiry was ignored")
assert(protected(3, 1).collides, "last raw timer update granted extra protection")
assert(protected(3, 1.5, true, rect(-10, 320, 40)).collides,
  "fractional raw timer granted protection beyond its integer expiry")
assert(protected(4, 100).collides, "unknown hurt transition assumed C protection")
assert(protected(3, 100, false).collides, "invalid sensor granted protection")
r = protected(3, 20, true, rect(0, 320))
assert(not r.collides and r.danger > 0, "protected unsafe endpoint was not scored softly")
assert(protected(3, 13, true, rect(0, 320)).collides, "expiry at horizon was ignored")

-- A moving/growing laser takes the same protection clipping path. Zero-width
-- warnings stay soft independently of timer validity.
local function laser(x, height)
  return { id = 77, enabled = true, vx = 0, vy = 0,
    hitBody = { type = HitType.RotatableRect, x = x, y = 320, width = 4, height = height, angle = 0 } }
end
local s = sensor(); s.state, s.protectionFrames = 3, 6
p = player(s); p.speedFast, p.speedSlow = 0, 0
local history = { frame = 1 }
dodge.choose(world(p, { laser(-40, 8) }), history, config())
history.frame = 2
r = dodge.choose(world(p, { laser(-30, 8) }), history, config())
assert(r.dynamic_lasers == 1 and not r.collides, "protected moving laser remained hard")
s.state = 4
history.frame = 3
assert(dodge.choose(world(p, { laser(-20, 8) }), history, config()).collides,
  "moving laser ignored unknown hurt state")
history.frame = 4
assert(not dodge.choose(world(p, { laser(-10, 0) }), history, config()).collides,
  "zero-thickness laser became hard")

-- If the laser vanishes exactly at conservative protection expiry, clipping
-- must not resurrect its zero-thickness endpoint as a damaging tangent.
s.state, s.protectionFrames = 3, 3
history = { frame = 1 }
dodge.choose(world(p, { laser(-2, 12) }), history, config())
history.frame = 2
assert(not dodge.choose(world(p, { laser(-2, 8) }), history, config()).collides,
  "vanishing laser's open endpoint became hard after protection clipping")

print("poison_prediction_test: PASS")
