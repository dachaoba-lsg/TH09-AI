-- Synthetic laser regression, native Lua 5.1; never starts the game.
HitType = { Rect = 0, Circle = 1, RotatableRect = 2 }
local hit = dofile("../../tests/upstream_hit_test.lua")
local dodge = dofile("dodge.lua")
-- Optional audit snapshot: not required for regression execution/rebuild.
local old_path = "../../work/marisa-audit/ai-0.1.7/dodge.lua"
local old_file, old = io.open(old_path, "r"), nil
if old_file then old_file:close(); old = dofile(old_path) end
local function config() return dofile("config.lua").dodge end
local function player(x, y)
  x, y = x or 0, y or 320
  return { x = x, y = y, speedFast = 4, speedSlow = 2,
    hitBodyRect = { type = HitType.Rect, x = x, y = y, width = 4, height = 4 },
    hitBodyCircle = { type = HitType.Circle, x = x, y = y, radius = 2 } }
end
local function laser(x, y, width, height, angle, id)
  -- object.x/y deliberately differ: the native sensor fixes hitBody only.
  return { id = id or 37, x = -999, y = -999, vx = 0, vy = 0, enabled = true,
    hitBody = { type = HitType.RotatableRect, x = x, y = y,
      width = width, height = height, angle = angle or 0 } }
end
local function world(p, b)
  return { player = p, enemies = {}, bullets = b and { b } or {}, exAttacks = {} }
end
local function move(p, choice)
  p.x, p.y = p.x + choice.vx, p.y + choice.vy
  p.hitBodyRect.x, p.hitBodyRect.y = p.x, p.y
  p.hitBodyCircle.x, p.hitBodyCircle.y = p.x, p.y
end
local function near(a, b)
  assert(a and math.abs(a - b) < 1e-7, tostring(a) .. " differs from " .. tostring(b))
end

-- Exact moving-boundary inequalities: growth, thickening, and translation.
do
  local enter, leave = dodge.changingRectInterval(20, 0, 0, 0, 2, 4, 10, 3, 0, 12)
  near(enter, 8 / 3); near(leave, 12)
  enter, leave = dodge.changingRectInterval(10, 20, 0, 0, 2, 2, 100, 0, 2, 12)
  near(enter, 9); near(leave, 12)
  enter, leave = dodge.changingRectInterval(20, 0, -8, 0, 2, 4, 10, 0, 0, 12)
  near(enter, 1); near(leave, 2.75)
  assert(dodge.changingRectInterval(20, 30, 0, 0, 2, 4, 10, 3, 0, 12) == nil)
end

-- Each sequence left v0.1.7 standing still for all three earlier snapshots
-- and hit on frame1. New history must start moving before that collision.
local function changes(name, make, p)
  local state, moved = {}, false
  p = p or player()
  if old then
    local old_player, old_state = player(p.x, p.y), {}
    for frame = -2, 0 do
      local result = old.choose(world(old_player, make(frame)), old_state, config())
      assert(result.name == "stay" and not result.collides, name .. ": old failure fixture changed")
      move(old_player, result)
    end
    assert(hit(old_player.hitBodyRect, make(1).hitBody), name .. ": old fixture did not hit")
  end
  for frame = -2, 0 do
    state.frame = frame + 3
    local b = make(frame)
    assert(not hit(p.hitBodyRect, b.hitBody), name .. ": hit before decision")
    local choice = dodge.choose(world(p, b), state, config())
    if choice.key ~= 0 then moved = true end
    move(p, choice)
  end
  assert(moved, name .. ": did not react to measured motion")
  assert(not hit(p.hitBodyRect, make(1).hitBody), name .. ": did not avoid former next-frame hit")
  print("PASS " .. name)
end
changes("translated corrected anchor", function(t)
  return laser(-4, 308 + t * 8, 8, 8, 0)
end)
changes("growing endpoint", function(t)
  return laser(0, 20, 280 + t * 20, 8, math.pi / 2)
end)
changes("changing angle", function(t)
  return laser(0, 200, 120, 8, math.pi / 2 - 0.15 + t * 0.1)
end)
changes("expanding thickness", function(t)
  return laser(-4, 320, 8, 50 + t * 24, 0)
end, player(0, 358))

-- Stable ID history uses hitBody anchors, not raw object.x/y. A moving finite
-- beam previously exported a stationary origin; the native patch corrects it.
do
  local p, state = player(), { frame = 1 }
  dodge.choose(world(p, laser(-100, 320, 40, 8)), state, config())
  state.frame = 2
  local result = dodge.choose(world(p, laser(-80, 320, 40, 8)), state, config())
  assert(result.dynamic_lasers == 1 and result.key ~= 0 and not result.collides,
    "future moving segment was not avoided")
  near(state.laser_history[37].vx, 20)
  assert(result.objects_relevant == 1, "future sweep was removed by present-only broad phase")
end

-- Missing object / ID / frame, ID reset, and discontinuity cannot reuse stale
-- velocity. Reappearance is scored statically until a fresh pair is observed.
do
  local p, cfg, state = player(), config(), { frame = 1 }
  dodge.choose(world(p, laser(-100, 320, 40, 8)), state, cfg)
  state.frame = 3
  local r = dodge.choose(world(p, laser(-80, 320, 40, 8)), state, cfg)
  assert(r.dynamic_lasers == 0, "cross-frame gap extrapolated")
  state.frame = 4; dodge.choose(world(p), state, cfg)
  assert(next(state.laser_history) == nil, "dead laser history retained")
  state.frame = 5
  r = dodge.choose(world(p, laser(-60, 320, 40, 8)), state, cfg)
  assert(r.dynamic_lasers == 0, "reappearing ID inherited velocity")
  state.frame = 6
  r = dodge.choose(world(p, laser(500, 320, 40, 8)), state, cfg)
  assert(r.dynamic_lasers == 0 and r.laser_history_resets == 1, "teleport projected across the screen")
  local no_id = laser(0, 320, 40, 8); no_id.id = nil
  state.frame = 7; r = dodge.choose(world(p, no_id), state, cfg)
  assert(r.dynamic_lasers == 0 and next(state.laser_history) == nil, "missing ID created unstable history")
end

-- Warning -> active is not unbounded thickness growth. Moving warnings are
-- still soft costs: only positive-thickness laser hazards mark collides.
do
  local p, cfg, state = player(), config(), { frame = 1 }
  p.speedFast, p.speedSlow = 0, 0
  dodge.choose(world(p, laser(0, 20, 420, 0, math.pi / 2)), state, cfg)
  state.frame = 2
  local r = dodge.choose(world(p, laser(1, 20, 420, 0, math.pi / 2)), state, cfg)
  assert(r.dynamic_lasers == 1 and r.warning_lasers == 1 and not r.collides, "warning became hard collision")
  state.frame = 3
  r = dodge.choose(world(p, laser(2, 20, 420, 8, math.pi / 2)), state, cfg)
  near(state.laser_history[37].dh, 0)
  assert(r.warning_lasers == 0 and r.collides, "positive thickness remained a warning")
  state.frame = 4
  r = dodge.choose(world(p, laser(0, 320, 8, 0, 0, 38)), state, cfg)
  assert(r.warning_lasers == 1 and not r.collides, "short zero-thickness warning became hard collision")
end

-- Angle wrap chooses the short arc; rotation is bounded to twelve swept
-- sweeps per un-clamped candidate rather than all bullets taking this path.
do
  local p, cfg, state = player(), config(), { frame = 1 }
  dodge.choose(world(p, laser(80, 320, 160, 8, math.pi - 0.02)), state, cfg)
  state.frame = 2
  local r = dodge.choose(world(p, laser(80, 320, 160, 8, -math.pi + 0.02)), state, cfg)
  near(state.laser_history[37].da, 0.04)
  assert(r.dynamic_lasers == 1 and r.laser_sweep_tests <= 17 * 12, "angular sweep work unbounded")
end

-- A rotating beam can cross between integer frames while both endpoint
-- snapshots miss. The swept angular enclosure must see the middle contact.
do
  local p, cfg, state = player(80, 320), config(), { frame = 1 }
  p.speedFast, p.speedSlow = 0, 0
  dodge.choose(world(p, laser(0, 320, 100, 2, -0.9)), state, cfg)
  state.frame = 2
  local start = laser(0, 320, 100, 2, -0.3)
  local finish = laser(0, 320, 100, 2, 0.3)
  assert(not hit(p.hitBodyRect, start.hitBody) and not hit(p.hitBodyRect, finish.hitBody))
  assert(hit(p.hitBodyRect, laser(0, 320, 100, 2, 0).hitBody))
  local r = dodge.choose(world(p, start), state, cfg)
  assert(r.collides, "rotating beam crossed between sample endpoints undetected")
end

-- Differential geometry audit against fine samples of the independent
-- upstream hitTest convention. Samples are only a test oracle; production
-- uses exact linear intervals/conservative angular enclosures, not sampling.
do
  math.randomseed(9018)
  for case = 1, 240 do
    local p, cfg, state = player(), config(), { frame = 1 }
    p.speedFast, p.speedSlow = 0, 0
    local x, y = math.random(-80, 80), math.random(230, 390)
    local length, height, angle = math.random(12, 140), math.random(2, 14), math.random() * math.pi * 2
    local vx, vy, dl, dh = math.random(-8, 8), math.random(-8, 8), math.random(-5, 8), math.random() * 0.5
    local da = case % 2 == 0 and (math.random() - 0.5) * 0.3 or 0
    dodge.choose(world(p, laser(x - vx, y - vy, length - dl, height - dh, angle - da)), state, cfg)
    state.frame = 2
    local r = dodge.choose(world(p, laser(x, y, length, height, angle)), state, cfg)
    local sampled_hit = false
    for step = 0, 240 do
      local t = step / 20
      local b = laser(x + vx * t, y + vy * t, math.max(0, length + dl * t), height + dh * t, angle + da * t)
      if hit(p.hitBodyRect, b.hitBody) then sampled_hit = true; break end
    end
    assert(not sampled_hit or r.collides, "future geometric hit missed in differential case " .. case)
  end
end

-- Width/height shrinking through zero has finite, clamped geometry.
do
  local p, cfg, state = player(0, 360), config(), { frame = 1 }
  dodge.choose(world(p, laser(0, 20, 370, 20, math.pi / 2)), state, cfg)
  state.frame = 2
  local r = dodge.choose(world(p, laser(0, 20, 330, 14, math.pi / 2)), state, cfg)
  assert(r.cost == r.cost and r.cost < math.huge and r.laser_sweep_tests <= 17 * 3,
    "shrinking laser produced invalid geometry or excessive work")
end

-- A fading moving beam is not damaging forever after thickness reaches zero.
-- Here it reaches zero at t=1, while first geometric contact is only t=1.9.
do
  local p, cfg, state = player(), config(), { frame = 1 }
  p.speedFast, p.speedSlow = 0, 0
  dodge.choose(world(p, laser(-100, 320, 40, 8)), state, cfg)
  state.frame = 2
  local r = dodge.choose(world(p, laser(-80, 320, 40, 4)), state, cfg)
  assert(r.dynamic_lasers == 1 and not r.collides, "zero-thickness future left a hard ghost line")
  assert(r.danger < cfg.collision_cost, "faded beam kept active collision cost")

  -- First touch exactly when thickness becomes zero is not an active hit.
  state = { frame = 1 }
  dodge.choose(world(p, laser(-82, 320, 40, 8)), state, cfg)
  state.frame = 2
  r = dodge.choose(world(p, laser(-62, 320, 40, 4)), state, cfg)
  assert(not r.collides, "contact at the zero-thickness instant counted as damaging")

  -- Earlier contact, while thickness is positive, must still remain hard.
  state = { frame = 1 }
  dodge.choose(world(p, laser(-81, 320, 40, 8)), state, cfg)
  state.frame = 2
  r = dodge.choose(world(p, laser(-61, 320, 40, 4)), state, cfg)
  assert(r.collides, "positive-thickness contact before fade was dropped")
end
print("laser_prediction_test: PASS")
