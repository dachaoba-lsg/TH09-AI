-- 3.1 human attention limit (speed-weighted tracking budget). No game process.
HitType = { Rect = 0, Circle = 1, RotatableRect = 2 }
ExAttackType = { Medicine = 16 }
local dodge = dofile("dodge.lua")
local checks = 0
local function check(value, message)
  checks = checks + 1
  assert(value, message)
end
local function mechConfig()
  local cfg = dofile("config.lua").dodge
  cfg.attention = { enabled = false }
  return cfg
end
local function attentionConfig(overrides)
  local cfg = dofile("config.lua").dodge
  for key, value in pairs(overrides or {}) do cfg.attention[key] = value end
  return cfg
end
local function player(x, y)
  x, y = x or 0, y or 320
  return { x = x, y = y, speedFast = 4, speedSlow = 2,
    hitBodyRect = { type = HitType.Rect, x = x, y = y, width = 4, height = 4 },
    hitBodyCircle = { type = HitType.Circle, x = x, y = y, radius = 2 } }
end
-- Every fixture bullet aims at the player, so "will hit me soon" is unambiguous.
local function aiming(x, y, speed)
  local dx, dy = -x, 320 - y
  local length = math.sqrt(dx * dx + dy * dy)
  return dx / length * speed, dy / length * speed
end
local function circle(x, y, vx, vy)
  return { vx = vx or 0, vy = vy or 0,
    hitBody = { type = HitType.Circle, x = x, y = y, radius = 2 } }
end
local function aimedCircle(x, y, speed)
  local vx, vy = aiming(x, y, speed)
  return circle(x, y, vx, vy)
end
local function rect(x, y, vx, vy, width, height)
  return { vx = vx or 0, vy = vy or 0,
    hitBody = { type = HitType.Rect, x = x, y = y, width = width or 4, height = height or 4 } }
end
local function laser(x, y)
  return { id = 900, vx = 0, vy = 0,
    hitBody = { type = HitType.RotatableRect, x = x, y = y, width = 300, height = 4, angle = math.pi / 2 } }
end
local function stick(x, y, speed, length)
  local vx, vy = aiming(x, y, speed)
  return { id = 901, hittable = true, vx = vx, vy = vy,
    hitBody = { type = HitType.RotatableRect, x = x, y = y, width = length or 64, height = 4, angle = 0 } }
end
local function world(p, bullets, exAttacks)
  return { player = p or player(), bullets = bullets or {}, enemies = {}, exAttacks = exAttacks or {} }
end
local function incoming(count, speed, spacing)
  local list = {}
  for i = 1, count do
    list[i] = aimedCircle((i - (count + 1) / 2) * (spacing or 4), 310, speed)
  end
  return list
end

-- 1. Cost is speed weighted: the same budget admits fewer fast bullets.
do
  local function trackedFor(speed)
    local cfg = attentionConfig()
    cfg.attention.reflex_radius, cfg.attention.threat_per_second = 0, 0
    cfg.attention.tracked_threat = 3
    return dodge.choose(world(player(), incoming(6, speed)), { frame = 1 }, cfg)
  end
  local slow, standard, fast = trackedFor(1.0), trackedFor(1.5), trackedFor(4.5)
  check(slow.attention_tracked == 4, "slow bullets (0.67 units) must fit four in a three-unit budget")
  check(standard.attention_tracked == 3, "standard bullets (1.0 unit) must fill the budget exactly")
  check(fast.attention_tracked == 1, "fast bullets (3.0 units) must admit only one")
  check(fast.attention_blind_urgent > slow.attention_blind_urgent,
    "fast bullets must leave more imminent objects unseen than slow ones")
  check(fast.attention_blind_urgent >= 3 and slow.attention_blind_urgent < 3,
    "a fast wave must cross the imminent-blindness limit that a slow wave stays under")
  check(slow.attention_overloaded == false and fast.attention_overloaded == false,
    "one call must not be enough to declare an overload")
end

-- 2. Long objects cost more than point bullets at the same speed, and EX
-- objects are billed while lasers, Medicine terrain and non-hittable EX stay
-- visible.
do
  local cfg = attentionConfig()
  cfg.attention.threat_per_second, cfg.attention.reflex_radius = 0, 0
  cfg.attention.tracked_threat, cfg.attention.urgent_frames = 9, 60
  local wide = { rect(-30, 300, 0, 4.5, 64, 8), rect(0, 300, 0, 4.5, 64, 8), rect(30, 300, 0, 4.5, 64, 8) }
  local points = { aimedCircle(-30, 300, 4.5), aimedCircle(0, 300, 4.5), aimedCircle(30, 300, 4.5) }
  local wide_result = dodge.choose(world(player(), wide), { frame = 1 }, cfg)
  local point_result = dodge.choose(world(player(), points), { frame = 1 }, cfg)
  check(point_result.attention_tracked == 3, "three fast point bullets must fit a nine-unit budget")
  check(wide_result.attention_tracked == 2 and wide_result.attention_blind_urgent == 1,
    "long objects must consume more of the same budget")
  local sticks = { stick(-30, 300, 4.5), stick(0, 300, 4.5), stick(30, 300, 4.5) }
  -- The host gives distinct live entities distinct IDs; three copies of 901
  -- cannot represent three independently budgeted, persistent targets.
  for index, object in ipairs(sticks) do object.id = 900 + index end
  local stick_result = dodge.choose(world(player(), {}, sticks), { frame = 1 }, cfg)
  check(stick_result.attention_tracked == 2, "EX sticks are billed like long bullets")
  local beam = dodge.choose(world(player(), { laser(0, 200), aimedCircle(0, 310, 4.5) }), { frame = 1 },
    (function()
      local c = attentionConfig()
      c.attention.threat_per_second, c.attention.reflex_radius, c.attention.tracked_threat = 0, 0, 1
      return c
    end)())
  check(beam.laser_count == 1, "lasers are never hidden by the attention budget")
  local terrain = { { id = 1, hittable = true, type = ExAttackType.Medicine, vx = 0, vy = 0,
    hitBody = { type = HitType.Circle, x = 0, y = 300, radius = 64 } } }
  local harmless = { { id = 2, hittable = false, vx = 0, vy = 0,
    hitBody = { type = HitType.Circle, x = 0, y = 300, radius = 16 } } }
  local terrain_result = dodge.choose(world(player(), {}, terrain), { frame = 1 }, cfg)
  local harmless_result = dodge.choose(world(player(), {}, harmless), { frame = 1 }, cfg)
  check(terrain_result.attention_tracked == 0 and harmless_result.attention_tracked == 0,
    "Medicine terrain and non-hittable EX must never be billed")
end

-- 2b. The reflex ring is bounded: noticing what already touches you must not
-- become a second unlimited sight that threads a tight pack.
do
  local cfg = attentionConfig()
  cfg.attention.threat_per_second, cfg.attention.tracked_threat = 0, 1
  cfg.attention.reflex_radius, cfg.attention.sight_radius = 20, 0
  local ring = {}
  for i = 1, 6 do ring[i] = circle((i - 3.5) * 4, 310, 0, 0) end
  local state = { frame = 1 }
  local first = dodge.choose(world(player(), ring), state, cfg)
  -- capacity 1 admits at most two 0.5-unit objects plus one bounded reflex slot.
  local budget_objects = math.ceil(cfg.attention.tracked_threat / (cfg.attention.min_cost or 0.5))
  check(first.attention_tracked <= budget_objects + math.ceil(cfg.attention.tracked_threat),
    "reflex admissions must stay bounded: " .. tostring(first.attention_tracked))
  check(first.attention_tracked >= 1 and first.attention_tracked < #ring,
    "the nearest objects must still be noticed without seeing the whole pack")
end

-- 3. A readable field is untouched: with attention on and off, the same sparse
-- scene must produce the identical decision.
do
  local bullets = { aimedCircle(-40, 300, 3), aimedCircle(40, 300, 3) }
  local human = dodge.choose(world(player(), bullets), { frame = 1 }, attentionConfig())
  local mech = dodge.choose(world(player(), bullets), {}, mechConfig())
  for _, key in ipairs({ "name", "key", "cost", "danger", "collides", "vx", "vy",
      "objects_seen", "objects_relevant", "trajectory_tests" }) do
    check(human[key] == mech[key], "a readable field changed " .. key)
  end
  check(human.attention_tracked == 2 and human.attention_blind_urgent == 0,
    "both threats must be tracked without overload")
end

-- 3a. Relevance must follow the route search, not "would hit a standing
-- player": a bullet that only threatens because the player may move into it is
-- still in front of me and must be admitted (3.2.0/3.2.1 blinded the AI here).
do
  local cfg = attentionConfig()
  cfg.attention.threat_per_second, cfg.attention.reflex_radius = 0, 0
  cfg.attention.tracked_threat, cfg.attention.sight_radius = 40, 0
  cfg.attention.urgent_frames = 24
  -- Off to the side, moving across the player, never aimed at it.
  local passing = { { vx = 3, vy = 0, hitBody = { type = HitType.Circle, x = -34, y = 322, radius = 2 } } }
  local human = dodge.choose(world(player(), passing), { frame = 1 }, cfg)
  local mech = dodge.choose(world(player(), passing), {}, mechConfig())
  check(mech.objects_relevant == 1, "the fixture must be relevant to the route search")
  check(human.attention_tracked == 1 and human.attention_load > 0,
    "a side-on bullet inside the route reach must be admitted: " .. tostring(human.attention_tracked))
  check(human.attention_blind_urgent == 0, "a pass-by is not an imminent hit")
end

-- 3b. "In front of me" is wider than "would hit me": a bullet that passes close
-- by is billed, and only objects that would actually hit count as blindness.
do
  local cfg = attentionConfig()
  cfg.attention.threat_per_second, cfg.attention.reflex_radius = 0, 0
  cfg.attention.tracked_threat = 5
  local near_pass = { { vx = 0, vy = 0, hitBody = { type = HitType.Circle, x = 8, y = 320, radius = 2 } } }
  local far_pass = { { vx = 0, vy = 0, hitBody = { type = HitType.Circle, x = 90, y = 320, radius = 2 } } }
  local near_result = dodge.choose(world(player(), near_pass), { frame = 1 }, cfg)
  local far_result = dodge.choose(world(player(), far_pass), { frame = 1 }, cfg)
  check(near_result.attention_tracked == 1 and near_result.attention_blind_urgent == 0,
    "a bullet passing inside the sight radius must be tracked, not called imminent")
  check(far_result.attention_tracked == 0 and far_result.attention_blind_urgent == 0,
    "a distant static bullet is background, not a threat")
  local graser = attentionConfig()
  graser.attention.threat_per_second, graser.attention.reflex_radius = 0, 0
  graser.attention.sight_radius, graser.attention.tracked_threat = 0, 5
  local blind_pass = dodge.choose(world(player(), near_pass), { frame = 1 }, graser)
  check(blind_pass.attention_blind_urgent == 0,
    "a static passer-by is seen through the route reach but is never called imminent")
end

-- 4. Objects whose velocity cannot be read are never hidden, because the
-- planner must not treat an unknown as harmless.
do
  local unknown = { vx = nil, vy = nil, hitBody = { type = HitType.Rect, x = 0, y = 300, width = 4, height = 4 } }
  local human = dodge.choose(world(player(), { unknown }), { frame = 1 }, attentionConfig())
  check(human.objects_seen == 1 and human.objects_relevant == 1,
    "an unreadable velocity must stay visible instead of being billed")
end

-- 5. Acquisition credit and the look interval: a bullet appearing right after a
-- look stays invisible until the next one, and spent credit delays the next
-- acquisition.
do
  local cfg = attentionConfig()
  cfg.attention.threat_per_second, cfg.attention.reflex_radius = 0, 0
  cfg.attention.tracked_threat, cfg.attention.plan_interval = 3, 6
  cfg.attention.blind_urgent_limit, cfg.attention.overload_frames = 99, 6
  local state = { frame = 1 }
  local bullets = incoming(2, 1.5)
  local first = dodge.choose(world(player(), bullets), state, cfg)
  check(first.attention_tracked == 2, "the first look admits the visible pair")
  bullets[#bullets + 1] = aimedCircle(20, 300, 1.5)
  for frame = 2, 6 do
    state.frame = frame
    local hidden = dodge.choose(world(player(), bullets), state, cfg)
    check(hidden.attention_tracked == 2, "between looks the tracked set must be kept")
    check(hidden.objects_seen < 3, "a new bullet must stay unseen until the next look")
  end
  state.frame = 7
  local seen_again = dodge.choose(world(player(), bullets), state, cfg)
  check(seen_again.attention_tracked == 3, "the next look must admit the new bullet within credit")
  bullets[#bullets + 1] = aimedCircle(-20, 300, 1.5)
  state.frame = 13
  local poor = dodge.choose(world(player(), bullets), state, cfg)
  check(poor.attention_tracked == 3 and poor.attention_blind_urgent == 1,
    "spent credit must delay the next acquisition")
end

-- 6. Overload answers: panic restricts the movement pool, escape asks the
-- policy for a charge attack, and 'hold' does neither.
do
  local function run(action, frames)
    local cfg = attentionConfig({ overload_action = action })
    cfg.attention.threat_per_second, cfg.attention.reflex_radius = 0.5, 0
    cfg.attention.tracked_threat, cfg.attention.blind_urgent_limit = 3, 3
    cfg.attention.overload_frames = 6
    local state, chosen = {}, nil
    for frame = 1, frames do
      state.frame = frame
      chosen = dodge.choose(world(player(), incoming(10, 4.5)), state, cfg)
    end
    return chosen, cfg
  end
  local calm = run("c_then_panic", 1)
  check(calm.attention_overloaded == false, "a single overloaded frame must not panic yet")
  local alarmed = run("c_then_panic", 10)
  check(alarmed.attention_overloaded == true, "sustained blindness must be reported as an overload")
  check(alarmed.attention_escape == true, "the overload must ask for a charge attack")
  check(alarmed.attention_panic == true, "the overload must degrade the movement pool")
  check(alarmed.name == "stay" or alarmed.name == "slow-stay" or alarmed.name == "fast-left"
    or alarmed.name == "fast-right" or alarmed.name == "fast-up" or alarmed.name == "fast-down",
    "panic moved with a fine diagonal route: " .. tostring(alarmed.name))
  local held = run("hold", 10)
  check(held.attention_overloaded == true and held.attention_escape == false and held.attention_panic == false,
    "hold must observe the overload without answering it")
  local only_c = run("c", 10)
  check(only_c.attention_escape == true and only_c.attention_panic == false,
    "the c-only action must not degrade movement")
  local panic_only = run("panic", 10)
  check(panic_only.attention_escape == false and panic_only.attention_panic == true,
    "the panic-only action must not request a charge attack")
end

-- 7. An unseen object can be walked into: a static wall that the intent would
-- happily approach is invisible, while the unlimited planner refuses it.
do
  local wall = rect(40, 320, 0, 0, 60, 8)
  local decoy = aimedCircle(0, 300, 1.0)   -- urgent, harmless, eats the budget
  local cfg = attentionConfig()
  cfg.attention.threat_per_second, cfg.attention.reflex_radius = 0, 0
  cfg.attention.tracked_threat = 1
  local intent = { focus = false, target_x = 100, position_weight = 1e30, focus_mismatch_cost = 1e30 }
  local human = dodge.choose(world(player(), { decoy, wall }), { frame = 1 }, cfg, intent)
  local mech = dodge.choose(world(player(), { decoy, wall }), {}, mechConfig(), intent)
  check(human.attention_tracked == 1 and human.attention_blind_urgent == 0,
    "a distant static wall is beyond the sight horizon, not an imminent threat")
  check(mech.terminal_x <= 10, "the unlimited planner must refuse the wall: " .. tostring(mech.terminal_x))
  check(human.terminal_x > 10, "the limited planner must walk into the unseen wall: " .. tostring(human.terminal_x))
end

-- 8. launcher-settings.json values reach the planner through runtime-settings.
do
  local actual_dofile, actual_open, actual_loadfile = dofile, io.open, loadfile
  local function withSettings(settings)
    local cfg = actual_dofile("config.lua")
    dofile = function(path)
      if path == "config.lua" then return cfg end
      return actual_dofile(path)
    end
    io.open = function(path)
      if path == "runtime-settings.lua" then return { close = function() end } end
      return nil
    end
    loadfile = function(path)
      if path == "runtime-settings.lua" then return function() return settings end end
      return actual_loadfile(path)
    end
    local snapshot = { x = 0, y = 320, life = 10, spellPoint = 0, combo = 0, currentCharge = 0,
      currentChargeMax = 0, chargeSpeed = 10, speedFast = 4, speedSlow = 2,
      hitBodyRect = { type = HitType.Rect, width = 4, height = 4 }, hitBodyCircle = { radius = 2 },
      sensor = { apiVersion = 1, valid = true, state = 0, protectionFrames = 0, canCharge = true,
        chargeBlockFrames = 0, baseScaleX = 1, baseScaleY = 1, moveScaleX = 1, moveScaleY = 1,
        poisonClouds = {} } }
    player_side = 2
    game_sides = { [2] = { player = snapshot, bullets = {}, enemies = {}, exAttacks = {} } }
    sendKeys = function() end
    actual_dofile("main.lua")
    main()
    return cfg
  end
  local mech = withSettings({ seconds = 300, ai = { difficulty = "mech" } })
  check(mech.dodge.attention.enabled == false, "difficulty mech must disable the limit")
  check(mech.debug_log == false, "debug_log must stay off unless requested")
  check(mech.attention_difficulty == "mech", "the csv tier name must follow the difficulty")
  local t120 = withSettings({ seconds = 300, ai = { difficulty = "human120" } })
  check(t120.dodge.attention.threat_per_second == 9 and t120.dodge.attention.tracked_threat == 12,
    "survival-time preset must be applied")
  check(t120.attention_difficulty == "human120", "the csv tier name must be recorded")
  local alias = withSettings({ seconds = 300, ai = { difficulty = "veteran" } })
  check(alias.dodge.attention.tracked_threat == 40 and alias.attention_difficulty == "human300",
    "3.1 preset names must resolve to their survival-time tier")
  local big = withSettings({ seconds = 300, ai = { difficulty = "human480" } })
  check(big.dodge.attention.tracked_threat == 55 and big.dodge.attention.threat_per_second == 40,
    "every tier must reach its own budget")
  local unlimited = withSettings({ seconds = 300, ai = { difficulty = "unlimited" } })
  check(unlimited.dodge.attention.tracked_threat == 120, "the unlimited tier must reach its own budget")
  -- A stale capacity left in the settings file must not pin the tier.
  local pinned = withSettings({ seconds = 300,
    ai = { difficulty = "human480", threat_per_second = 13, tracked_threat = 18 } })
  check(pinned.dodge.attention.tracked_threat == 55 and pinned.dodge.attention.threat_per_second == 40,
    "a named tier must own its capacity and rate")
  local custom = withSettings({ seconds = 300,
    ai = { difficulty = "custom", threat_per_second = 9, tracked_threat = 12 } })
  check(custom.dodge.attention.tracked_threat == 12 and custom.dodge.attention.threat_per_second == 9,
    "difficulty custom must honour explicit numbers")
  local overridden = withSettings({ seconds = 300,
    ai = { difficulty = "human200", plan_interval = 9, debug_log = true } })
  check(overridden.dodge.attention.plan_interval == 9, "a non-tier knob must stay overridable")
  check(overridden.dodge.attention.threat_per_second == 19, "the named tier keeps its own rate")
  check(overridden.debug_log == true, "debug_log must reach the csv switch")
  local bogus = withSettings({ seconds = 300,
    ai = { difficulty = "not-a-preset", threat_per_second = 1e9, tracked_threat = -4 } })
  check(bogus.dodge.attention.threat_per_second == 19.0 and bogus.dodge.attention.tracked_threat == 26,
    "unknown presets and out-of-range numbers must fall back to the default tier")
  local absent = withSettings({ seconds = 300 })
  check(absent.dodge.attention.enabled == true and absent.dodge.attention.threat_per_second == 19.0,
    "a settings file without an ai block must keep the default tier")
  dofile, io.open, loadfile = actual_dofile, actual_open, actual_loadfile
end


-- 9. A host may rebuild its exported object list between accesses (the real
-- ka_ai_duka host hands out freshly built tables). The attention path must
-- score exactly the objects it collected, never a second lookup of that list.
do
  local function freshBullets()
    local list = {}
    for i = 1, 12 do
      list[i] = { vx = 0, vy = 2,
        hitBody = { type = HitType.Circle, x = (i - 6.5) * 8, y = 300, radius = 2 } }
    end
    return list
  end
  local function rebuildingSide()
    local side = { player = player(), enemies = {}, exAttacks = {} }
    setmetatable(side, { __index = function(_, key)
      if key == "bullets" then return freshBullets() end
      return nil
    end })
    return side
  end
  local cfg = attentionConfig()
  local chosen = dodge.choose(rebuildingSide(), { frame = 1 }, cfg)
  check(chosen.attention_tracked > 0, "a rebuilding host must still admit the objects in front")
  check(chosen.objects_seen >= chosen.attention_tracked,
    "every admitted object must be scored exactly once: seen " .. tostring(chosen.objects_seen))
  check(chosen.objects_relevant > 0,
    "a rebuilding host must still produce relevant objects: " .. tostring(chosen.objects_relevant))
  check(chosen.attention_reach > 0 and chosen.attention_entries > 0,
    "attention diagnostics must report the reach and the entry count")
  local mech = dodge.choose(rebuildingSide(), {}, mechConfig())
  check(mech.objects_seen > 0 and mech.objects_relevant > 0, "the unlimited path must keep working")
end

-- 10. Repeated callbacks must not re-score the previous frames objects: the
-- scored set is rebuilt on every look (3.2.2 appended to the held table, so
-- objects_seen grew every frame and thousands of stale objects were dodged).
do
  local cfg = attentionConfig()
  local state = { frame = 0 }
  local bullets = {}
  for i = 1, 30 do
    bullets[i] = { id = 500 + i, vx = 0, vy = 2,
      hitBody = { type = HitType.Circle, x = (i - 15) * 4, y = 300, radius = 2 } }
  end
  local world = { player = player(), bullets = bullets, enemies = {}, exAttacks = {} }
  local first
  for frame = 1, 8 do
    state.frame = frame
    local chosen = dodge.choose(world, state, cfg)
    if not first then first = chosen.objects_seen end
    check(chosen.objects_seen == first,
      "objects_seen must stay constant across callbacks: " .. tostring(chosen.objects_seen) .. " vs " .. tostring(first))
    check(chosen.attention_tracked == first - 0 or chosen.attention_tracked > 0,
      "the tracked set must stay populated")
  end
end
print(string.format("attention_test: PASS (%d checks)", checks))
