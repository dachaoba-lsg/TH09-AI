-- Regression coverage for host slot reuse and the attention geometry cull.
-- Run in native Lua 5.1 through tests/run_native_lua.py; no game process.
HitType = { Rect = 0, Circle = 1, RotatableRect = 2 }
ExAttackType = { Medicine = 16 }
local dodge = dofile("dodge.lua")
local checks, cases, failures = 0, 0, 0
local function check(value, message)
  checks = checks + 1
  assert(value, message)
end
local function test(name, run)
  cases = cases + 1
  local ok, message = pcall(run)
  if not ok then
    failures = failures + 1
    print("FAIL " .. name .. ": " .. tostring(message))
  end
end
local function player()
  return { x = 0, y = 320, speedFast = 4, speedSlow = 2,
    hitBodyRect = { type = HitType.Rect, x = 0, y = 320, width = 4, height = 4 },
    hitBodyCircle = { type = HitType.Circle, x = 0, y = 320, radius = 2 } }
end
local function world(bullets, ex, p)
  return { player = p or player(), bullets = bullets or {}, exAttacks = ex or {}, enemies = {} }
end
local function config(capacity, rate)
  local cfg = dofile("config.lua").dodge
  cfg.move_change_budget = 1000
  cfg.move_change_min_frames = 0
  cfg.attention.enabled = true
  cfg.attention.tracked_threat = capacity or 1
  cfg.attention.threat_per_second = rate or 0
  cfg.attention.plan_interval = 6
  cfg.attention.reflex_radius = 0
  cfg.attention.sight_radius = 0
  cfg.attention.blind_urgent_limit = 99
  cfg.attention.overload_action = "hold"
  return cfg
end
local function circle(id, x, y, vx, vy)
  return { id = id, vx = vx or 0, vy = vy or 1.5,
    hitBody = { type = HitType.Circle, x = x, y = y, radius = 2 } }
end
local function stick(id, x, y, width, angle, vx, vy)
  return { id = id, hittable = true, vx = vx or 0, vy = vy or 0,
    hitBody = { type = HitType.RotatableRect, x = x, y = y,
      width = width, height = 4, angle = angle } }
end
local function exportSlot(slot, fresh)
  -- The native exporter keeps Lua tables by array index, not by object ID.
  slot.id, slot.vx, slot.vy = fresh.id, fresh.vx, fresh.vy
  for key, value in pairs(fresh.hitBody) do slot.hitBody[key] = value end
end
local function chosen(side, state, cfg, frame)
  state.frame = frame
  return dodge.choose(side, state, cfg)
end
local function onlyScored(state, object, tag)
  local scored = state.attention_scored or {}
  check(#scored == 1, "exactly one current object must be held")
  check(scored[1].object == object and scored[1].tag == (tag or "bullet"),
    "the tracked identity must bind to the current object's table and category")
end
local function sameDecision(human, mech, message)
  for _, key in ipairs({ "name", "key", "cost", "danger", "collides", "vx", "vy",
      "terminal_x", "terminal_y", "objects_relevant", "trajectory_tests" }) do
    check(human[key] == mech[key], message .. ": changed " .. key)
  end
end

test("array slot reuse follows ID 202 and current geometry", function()
  local cfg, state = config(), {}
  local slots = { circle(101, 1000, 300), circle(202, 0, 300), circle(303, 50, 300) }
  local side = world(slots)
  local first = chosen(side, state, cfg, 1)
  check(first.attention_tracked == 1, "fixture must admit the urgent ID 202 only")
  onlyScored(state, slots[2])
  -- Delete 101: 202 moves into slot 1, while slot 2 is overwritten by 303.
  exportSlot(slots[1], circle(202, -15, 305, 1.5, 0))
  exportSlot(slots[2], circle(303, 50, 300))
  slots[3] = nil
  local second = chosen(side, state, cfg, 2)
  onlyScored(state, slots[1])
  check(second.attention_tracked == 1 and second.objects_seen == 1,
    "rebinding must neither lose 202 nor score 303")
  local mech_cfg = config()
  mech_cfg.attention.enabled = false
  sameDecision(second, dodge.choose(world({ slots[1] }), {}, mech_cfg),
    "the planner must read 202's updated position and velocity")
end)

test("vanished IDs drop immediately and replacement waits for scan and credit", function()
  local cfg, state = config(1, 10), {}
  local side = world({ circle(202, 0, 300) })
  chosen(side, state, cfg, 1)
  exportSlot(side.bullets[1], circle(303, 0, 310))
  for frame = 2, 6 do
    local result = chosen(side, state, cfg, frame)
    check(result.objects_seen == 0 and result.attention_tracked == 0,
      "the reused slot is a new identity until the next observation")
    check(#(state.attention_scored or {}) == 0, "vanished identities must not remain held")
  end
  local next_look = chosen(side, state, cfg, 7)
  check(next_look.attention_tracked == 1 and next_look.objects_seen == 1,
    "the next observation must admit the replacement after credit refills")
  onlyScored(state, side.bullets[1])
  local poor_cfg, poor_state = config(1, 0), {}
  local poor_side = world({ circle(202, 0, 300) })
  chosen(poor_side, poor_state, poor_cfg, 1)
  poor_side.bullets = { circle(303, 0, 310) }
  local poor = chosen(poor_side, poor_state, poor_cfg, 7)
  check(poor.objects_seen == 0 and poor.attention_tracked == 0,
    "a new ID cannot inherit spent acquisition credit")
end)

test("fresh tables with the same stable ID remain continuously tracked", function()
  local cfg, state = config(), {}
  local side = world({ circle(202, 0, 300) })
  chosen(side, state, cfg, 1)
  for frame = 2, 8 do
    side.bullets = { circle(202, frame, 300 + frame) }
    local result = chosen(side, state, cfg, frame)
    check(result.objects_seen == 1 and result.attention_tracked == 1,
      "fresh tables with a continuing ID must not disappear between observations")
    onlyScored(state, side.bullets[1])
    check(result.attention_credit == 0, "continuing IDs do not reacquire credit")
  end
end)

test("bullet and EX namespaces do not share a numeric ID", function()
  local cfg, state = config(2), {}
  local side = world({ circle(202, -2, 300) }, { circle(202, 2, 300) })
  side.exAttacks[1].hittable = true
  local first = chosen(side, state, cfg, 1)
  check(first.attention_tracked == 2 and first.objects_seen == 2,
    "both categories must be independently acquired")
  side.bullets = { circle(202, -4, 302) }
  side.exAttacks = { circle(202, 4, 302) }
  side.exAttacks[1].hittable = true
  local second = chosen(side, state, cfg, 2)
  check(second.attention_tracked == 2 and second.objects_seen == 2,
    "rebuilt tables must preserve both independently tracked categories")
  local found = {}
  for _, item in ipairs(state.attention_scored or {}) do found[item.tag] = item.object end
  check(found.bullet == side.bullets[1] and found.ex == side.exAttacks[1],
    "matching numeric IDs must not bind across categories")
  local single_cfg, single_state = config(1), {}
  local single = world({ circle(202, 0, 300) })
  chosen(single, single_state, single_cfg, 1)
  single.bullets, single.exAttacks = {}, { circle(202, 0, 300) }
  single.exAttacks[1].hittable = true
  for _, frame in ipairs({ 2, 7 }) do
    local result = chosen(single, single_state, single_cfg, frame)
    check(result.objects_seen == 0 and result.attention_tracked == 0,
      "an EX cannot inherit a vanished bullet's identity or acquisition credit")
  end
end)

test("objects without stable IDs retain only table identity", function()
  local cfg, state = config(), {}
  local original = circle(nil, 0, 300)
  local side = world({ original })
  chosen(side, state, cfg, 1)
  original.hitBody.y = 302
  local same = chosen(side, state, cfg, 2)
  check(same.objects_seen == 1 and same.attention_tracked == 1,
    "a continuing anonymous table remains tracked")
  onlyScored(state, original)
  side.bullets = { circle(nil, 0, 304) }
  for _, frame in ipairs({ 3, 7 }) do
    local replaced = chosen(side, state, cfg, frame)
    check(replaced.objects_seen == 0 and replaced.attention_tracked == 0,
      "a replacement anonymous table cannot inherit identity from its array index")
  end
end)

local fixtures = {
  { "horizontal long EX", stick(401, -100, 320, 128, 0), "ex" },
  { "vertical long EX", stick(402, 0, 220, 128, math.pi / 2), "ex" },
  { "diagonal long EX", stick(403, -80, 240, 128, math.pi / 4), "ex" },
  { "opposite diagonal long EX", stick(404, -80, 400, 128, -math.pi / 4), "ex" },
  { "circle safety boundary", circle(405, 55, 320, 0, 0), "bullet" },
  { "rectangle safety boundary", { id = 406, vx = 0, vy = 0,
      hitBody = { type = HitType.Rect, x = 55, y = 320, width = 4, height = 4 } }, "bullet" },
  { "rectangle tall player boundary", { id = 407, vx = 0, vy = 0,
      hitBody = { type = HitType.Rect, x = 0, y = 379, width = 4, height = 4 } }, "bullet", "tall" },
  { "circle player radius boundary", circle(408, 61, 320, 0, 0), "bullet", "large_circle" },
}
for _, fixture in ipairs(fixtures) do
  test(fixture[1] .. " stays in the attention candidate set", function()
    local cfg, p = config(120), player()
    if fixture[4] == "tall" then p.hitBodyRect.height = 12 end
    if fixture[4] == "large_circle" then p.hitBodyCircle.radius = 8 end
    local bullets, ex = {}, {}
    if fixture[3] == "ex" then ex[1] = fixture[2] else bullets[1] = fixture[2] end
    local side, state = world(bullets, ex, p), {}
    local human = chosen(side, state, cfg, 1)
    local mech_cfg = config(120)
    mech_cfg.attention.enabled = false
    local mech = dodge.choose(side, {}, mech_cfg)
    check(mech.objects_relevant == 1, "fixture must intersect the route-search swept bound")
    check(human.attention_entries == 1 and human.attention_tracked == 1,
      "any billed object relevant to mech must be considered and fit a sufficient budget")
    check(human.attention_free == 0 and human.attention_seen_cost > 0,
      "geometry coverage cannot make these threats free")
    sameDecision(human, mech, fixture[1])
  end)
end

test("a pack of long EX objects still respects the attention budget", function()
  local cfg, ex = config(2), {}
  for i = 1, 8 do ex[i] = stick(500 + i, -100, 310 + i * 2, 128, 0, 0, 1.5) end
  local result = chosen(world({}, ex), {}, cfg, 1)
  check(result.attention_entries == #ex, "all crossing long EX must enter the candidate set")
  check(result.attention_free == 0, "long EX cannot become free laser objects")
  check(result.attention_tracked == 1 and result.objects_seen == 1,
    "a two-unit budget admits one two-unit long EX")
  check(result.attention_skipped == #ex - 1, "the remaining EX must still be budget limited")
  check(result.attention_seen_cost <= result.attention_budget,
    "geometry correction cannot overdraw the ordinary tracking budget")
end)

assert(failures == 0, string.format("attention_identity_geometry_test: FAIL (%d/%d cases; %d checks)",
  failures, cases, checks))
print(string.format("attention_identity_geometry_test: PASS (%d cases, %d checks)", cases, checks))
