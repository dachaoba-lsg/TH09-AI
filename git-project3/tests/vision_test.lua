-- Hard circular perception shared by resource observation and dodge.
-- Native Lua 5.1 fixtures only; no game process or host data is modified.
HitType = { Rect = 0, Circle = 1, RotatableRect = 2 }
ExAttackType = { Medicine = 16 }
local dodge, observer = dofile('dodge.lua'), dofile('bloom_observer.lua')
local checks = 0
local function check(value, message) checks = checks + 1; assert(value, message) end
local function player()
  return { x = 0, y = 320, character = 0, life = 10, currentCharge = 0,
    currentChargeMax = 200, chargeSpeed = 10, speedFast = 4, speedSlow = 2,
    hitBodyRect = { type = 0, width = 4, height = 4 }, hitBodyCircle = { type = 1, radius = 2 },
    sensor = { apiVersion = 1, valid = true, state = 0, protectionFrames = 0, canCharge = true,
      cutIn = false, timeScale = 1, movementEnabled = true,
      baseScaleX = 1, baseScaleY = 1, moveScaleX = 1, moveScaleY = 1, poisonClouds = {},
      opponent = { valid = true, chargeMax = 300 }, commonWaves = { { slotId = 7 } } } }
end
local function world(bullets, enemies, ex)
  return { player = player(), bullets = bullets or {}, enemies = enemies or {}, exAttacks = ex or {},
    chargeType = 0, custom_metadata = 'preserved' }
end
local function config(radius, limited)
  local cfg = dofile('config.lua').dodge
  cfg.vision_radius = radius
  cfg.move_change_budget, cfg.move_change_min_frames = 1000, 0
  cfg.attention.enabled = limited == true
  cfg.attention.tracked_threat, cfg.attention.threat_per_second = 120, 90
  cfg.attention.plan_interval = 6
  return cfg
end
local function circle(id, x, y, radius, vx, vy)
  return { id = id, enabled = true, isErasable = true, hittable = true,
    x = x, y = y, vx = vx or 0, vy = vy or 0,
    hitBody = { type = 1, x = x, y = y, radius = radius or 2 } }
end
local function rectangle(id, x, y, width, height, angle)
  return { id = id, enabled = true, hittable = true, x = x, y = y, vx = 0, vy = 0,
    hitBody = { type = angle and 2 or 0, x = x, y = y,
      width = width, height = height, angle = angle } }
end
local function cloud(x, y, radius)
  return { x = x, y = y, radius = radius, age = 100, active = true, framesLeft = 200 }
end
local function sameDecision(a, b, message)
  for _, field in ipairs({ 'key', 'cost', 'danger', 'collides', 'vx', 'vy', 'terminal_x', 'terminal_y' }) do
    check(a[field] == b[field], message .. ': changed ' .. field)
  end
end

-- Exact current shape/circle intersections, including tangency, asymmetric
-- laser anchors and a diagonal whose AABB intersects but actual body does not.
local fixtures = {
  { circle(1, 102, 320, 2), true, 'circle tangent' },
  { circle(2, 102.01, 320, 2), false, 'circle beyond tangent' },
  { circle(3, 80, 400, 2), false, 'circle is not a square view' },
  { rectangle(4, 104, 320, 8, 8), true, 'rectangle tangent' },
  { rectangle(5, 104.01, 320, 8, 8), false, 'rectangle beyond tangent' },
  { rectangle(6, 104, 424, 8, 8), false, 'rectangle diagonal corner' },
  { rectangle(7, -300, 320, 600, 4, 0), true, 'long horizontal beam through circle' },
  { rectangle(8, 0, 0, 400, 4, math.pi / 2), true, 'long vertical beam through circle' },
  { rectangle(9, -200, 120, 400, 4, math.pi / 4), true, 'long diagonal beam through circle' },
  { rectangle(10, -200, 320, 280, 4, math.pi / 4), false, 'rotated AABB alone cannot grant sight' },
  { rectangle(11, 110, 320, 300, 4, 0), false, 'beam extends forward from its anchor' },
  { rectangle(12, -300, 320, 600, 0, 0), true, 'zero-thickness warning line crosses circle' },
  { rectangle(13, -300, 421, 600, 0, 0), false, 'warning virtual safety thickness cannot extend sight' },
}
for _, fixture in ipairs(fixtures) do
  for _, kind in ipairs({ 'bullets', 'enemies', 'exAttacks' }) do
    local w = world(); w[kind] = { fixture[1] }
    local visible, stats = dodge.perceive(w, config(100))
    check((#visible[kind] == 1) == fixture[2], fixture[3] .. ' (' .. kind .. ')')
    check(stats.visible_count + stats.hidden_count == 1, 'shape diagnostics must conserve the input count')
  end
end

do
  local inside, outside = circle(20, 0, 300), circle(21, 1000, 320)
  local w = world({ inside, outside }, { circle(22, 0, 280), circle(23, -1000, 320) },
    { rectangle(24, -300, 320, 600, 4, 0), circle(25, 0, -1000) })
  w.player.sensor.poisonClouds = { cloud(0, 320, 64), cloud(1000, 320, 64) }
  local native_player, native_sensor, native_clouds = w.player, w.player.sensor, w.player.sensor.poisonClouds
  local visible, stats = dodge.perceive(w, config(100))
  check(visible ~= w and visible.player ~= native_player and visible.player.sensor ~= native_sensor,
    'perception must create a private side/player/sensor snapshot')
  check(#w.bullets == 2 and #w.enemies == 2 and #w.exAttacks == 2 and #native_clouds == 2,
    'perception must not truncate native lists')
  check(visible.bullets[1] == inside and visible.player.sensor.poisonClouds[1] == native_clouds[1],
    'visible hazard references and stable IDs must be preserved')
  check(visible.player.sensor.opponent == native_sensor.opponent
      and visible.player.sensor.commonWaves == native_sensor.commonWaves
      and visible.chargeType == w.chargeType and visible.custom_metadata == w.custom_metadata,
    'opponent/self attack metadata and side settings must remain available')
  for _, kind in ipairs({ 'bullets', 'enemies', 'ex', 'poison' }) do
    check(stats['visible_' .. kind] == 1 and stats['hidden_' .. kind] == 1,
      'per-category diagnostics must use current real shapes: ' .. kind)
  end
  check(stats.visible_count == 4 and stats.hidden_count == 4 and stats.radius == 100,
    'total diagnostics must include object lists and native poison fields')
  local again = dodge.perceive(visible, config(100))
  check(again.bullets[1] == inside and #again.bullets == 1, 'double filtering must be idempotent')
end

do
  local w = world({ circle(30, 200, 320, 2, -100, 0) })
  for _, limited in ipairs({ false, true }) do
    local cfg = config(16, limited)
    cfg.attention.reflex_radius, cfg.attention.sight_radius = 1000, 1000
    local r = dodge.choose(w, { frame = 1 }, cfg)
    check(r.objects_seen == 0 and r.objects_relevant == 0,
      'a future swept intersection cannot see outside the current circle, including mech')
    sameDecision(r, dodge.choose(world(), {}, cfg), 'outside fast projectile')
  end
  local cfg = config(16, true)
  local unknown = circle(31, 40, 320); unknown.vx, unknown.vy = nil, nil
  check(dodge.choose(world({ unknown }), {}, cfg).objects_seen == 0,
    'unknown-velocity free objects outside the circle must remain hidden')
  unknown.x, unknown.hitBody.x = 0, 0
  local seen = dodge.choose(world({ unknown }), {}, cfg)
  check(seen.objects_seen == 1 and seen.attention_free == 1,
    'unknown velocity inside the circle remains conservatively visible')
end

do
  local cfg, state = config(30, true), { frame = 1 }
  cfg.attention.tracked_threat, cfg.attention.threat_per_second, cfg.attention.reflex_radius = 1, 0, 0
  local bullet = circle(40, 0, 300, 2, 0, 1.5)
  local w = world({ bullet })
  check(dodge.choose(w, state, cfg).attention_tracked == 1, 'fixture must track the inside bullet')
  bullet.x, bullet.hitBody.x, state.frame = 60, 60, 2
  local hidden = dodge.choose(w, state, cfg)
  check(hidden.objects_seen == 0 and hidden.attention_tracked == 0,
    'an already tracked object leaves sight immediately between observation scans')
  check(next(state.attention_set) == nil and #state.attention_scored == 0,
    'hard sight must remove attention caches, not merely skip the final score')
  bullet.x, bullet.hitBody.x, state.frame = 0, 0, 3
  check(dodge.choose(w, state, cfg).objects_seen == 0,
    'reentering sight cannot restore attention for free between scans')
  state.frame = 7
  check(dodge.choose(w, state, cfg).objects_seen == 0,
    'reentering sight must still pay new acquisition credit')
end

do
  local cfg, state = config(50, true), { frame = 1 }
  local beam = rectangle(50, 0, 0, 448, 4, math.pi / 2)
  local w = world({ beam })
  dodge.choose(w, state, cfg)
  check(state.laser_history[50] ~= nil, 'inside beam should acquire dynamic history')
  beam.x, beam.hitBody.x, state.frame = 80, 80, 2
  local hidden = dodge.choose(w, state, cfg)
  check(hidden.laser_count == 0 and hidden.objects_seen == 0 and next(state.laser_history) == nil,
    'outside laser cannot survive via free category or cached dynamic projection')
  beam.x, beam.hitBody.x, state.frame = 0, 0, 3
  local returned = dodge.choose(w, state, cfg)
  check(returned.laser_count == 1 and returned.tracked_lasers == 0 and returned.dynamic_lasers == 0,
    'reentering laser starts fresh history, without extrapolating unseen motion')
end

do
  local cfg = config(16)
  cfg.position_cost, cfg.preferred_x, cfg.preferred_y = 1, 1000, 320
  cfg.wall_cost, cfg.wall_margin, cfg.boundary_cost, cfg.movement_cost = 0, 0, 0, 0
  local w = world()
  w.player.sensor.poisonClouds = { cloud(40, 320, 10) }
  local hidden = dodge.choose(w, {}, cfg)
  check(hidden.poison_clouds == 0 and hidden.terminal_x == 48,
    'outside poison cannot influence future movement through the native sensor path')
  cfg.vision_radius = 50
  local seen = dodge.choose(w, {}, cfg)
  check(seen.poison_clouds == 1 and seen.terminal_x < 48,
    'visible native poison still affects predicted motion')
  local tangent = world()
  tangent.player.sensor.poisonClouds = { cloud(80, 320, 64), cloud(80.01, 320, 64) }
  local visible, stats = dodge.perceive(tangent, config(16))
  check(#visible.player.sensor.poisonClouds == 1 and stats.hidden_poison == 1,
    'native poison visibility uses full circular extent and inclusive tangency')
end

do
  local w = world({ circle(60, 48, 224, 2, 0, 2) })
  w.player.sensor.state, w.player.sensor.protectionFrames = 3, 48
  local intent = { protected_followup = true, min_y = 150, focus = false, target_x = 100,
    target_y = 320, position_weight = 0.002, focus_mismatch_cost = 8 }
  local cfg = config(16)
  local hidden = dodge.choose(w, {}, cfg, intent)
  check(hidden.protected_route_checked and hidden.protected_route_tests == 0
      and hidden.protected_route_rejected == 0 and hidden.name == 'fast-right',
    'post-protection endpoint search cannot reread outside hazards')
  cfg.vision_radius = 0
  local baseline = dodge.choose(w, {}, cfg, intent)
  check(baseline.protected_route_rejected > 0 and baseline.name ~= hidden.name,
    'the fixture must expose the full-list protected-route bypass without the circle')
end

do
  local enemy = circle(70, 0, 240, 4)
  enemy.isSpirit, enemy.isActivatedSpirit, enemy.isBoss = false, false, false
  local w = world({ circle(71, 0, 242, 2) }, { enemy })
  local cfg, history = config(100), {}
  local visible = dodge.perceive(w, cfg)
  local first = observer.observe(visible, history)
  check(first.has_ignition and first.counts.field_erasable == 1,
    'inside resources must reach the shared bloom observer')
  history.lock_ids = { [70] = true }
  enemy.y, enemy.hitBody.y = 100, 100
  w.bullets[1].y, w.bullets[1].hitBody.y = 102, 102
  visible = dodge.perceive(w, cfg)
  local hidden = observer.observe(visible, history)
  check(not hidden.has_ignition and not hidden.c2.has_ignition and hidden.counts.field_erasable == 0,
    'outside enemies/bullets cannot survive through observer locks or position-search caches')
  check(#w.enemies == 1 and #w.bullets == 1, 'shared observer path must not mutate the native world')
end

do
  local w = world({ circle(80, 1000, 320) })
  for _, radius in ipairs({ -1, math.huge, 0 / 0 }) do
    local visible, stats = dodge.perceive(w, { vision_radius = radius })
    check(#visible.bullets == 0 and math.abs(stats.radius - 448 / 3) < 1e-10,
      'invalid direct radius must fall back to the default circle, never unlimited sight')
  end
  local legacy, legacy_stats = dodge.perceive(w, {})
  local baseline, baseline_stats = dodge.perceive(w, { vision_radius = 0 })
  check(legacy == w and baseline == w and legacy_stats.radius == 0 and baseline_stats.radius == 0,
    'raw internal baselines may explicitly omit/zero the radius')
  local _, low = dodge.perceive(w, { vision_radius = 1 })
  local _, high = dodge.perceive(w, { vision_radius = 9999 })
  check(low.radius == 16 and high.radius == 640, 'finite positive direct radii remain bounded')
end
print(string.format('vision_test: PASS (%d checks)', checks))
