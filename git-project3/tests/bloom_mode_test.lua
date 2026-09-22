-- 3.0 bloom (energy) mode: pressure hysteresis, prompt C2 rhythm, relaxed
-- chain gate, opponent-gauge entry relaxation and fail-safe behavior.
-- This is a decision-level fixture, not a game or energy simulator: it supplies
-- pressure and charge snapshots explicitly and never claims net energy.
local bloom = dofile("bloom.lua")
local checks = 0
local function check(value, message)
  checks = checks + 1
  assert(value, message)
end
local function copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = type(v) == "table" and copy(v) or v end
  return out
end
local function config(overrides)
  local out = copy(bloom.defaults)
  for k, v in pairs(overrides or {}) do out[k] = v end
  return out
end

local function fixture(options)
  options = options or {}
  local warmup = options.warmup or 11
  local sensor = { valid = true, apiVersion = 1, state = options.state or 0, canCharge = options.canCharge ~= false,
    cutIn = false, timeScale = options.scale or 1, chargeWarmupFrames = warmup, chargeBlockFrames = 0 }
  if options.opponent ~= nil then
    sensor.opponentApiVersion = 1
    sensor.opponent = copy(options.opponent)
  end
  return { state = {}, cfg = config(options.cfg), time = 0, calls = 0,
    warmup = warmup, remaining_warmup = warmup, releases = {}, reason = nil,
    world = { player = { character = 0, x = 0, y = 320, life = 10,
      currentCharge = 0, currentChargeMax = options.energy or 200,
      chargeSpeed = options.speed or 10, sensor = sensor },
      enemies = {}, bullets = {}, exAttacks = {} } }
end

local function observation(pressure, c2)
  local obs = { valid = true, counts = { fairies = 0, spirits = 0, activated = 0,
    erasable = 0, field_erasable = pressure }, c2 = c2 or {} }
  return obs
end

local function tick(f, obs, movement)
  local p, s = f.world.player, f.world.player.sensor
  s.chargeWarmupFrames = f.remaining_warmup
  local before = p.currentCharge
  local old_c1, old_c2 = f.state.release_c1 or 0, f.state.release_c2 or 0
  local r = bloom.update(f.world, f.state, f.cfg, obs)
  bloom.feedback(f.state,
    movement or { focus = r.intent.focus, key = r.intent.focus and 4 or 0 }, f.cfg)
  local elapsed = s.cutIn and 0 or math.max(0, math.min(1, s.timeScale))
  f.time, f.calls = f.time + elapsed, f.calls + 1
  local level = r.release_c2 > old_c2 and 2 or (r.release_c1 > old_c1 and 1 or nil)
  if level then f.releases[#f.releases + 1] = { level = level, time = f.time, call = f.calls } end
  local active = elapsed > 0 and (s.state == 0 or s.state == 3) and s.canCharge
  if r.press_z then
    if active then
      if f.remaining_warmup > 0 then
        f.remaining_warmup = math.max(0, f.remaining_warmup - elapsed)
      else
        p.currentCharge = math.min(p.currentChargeMax, p.currentCharge + p.chargeSpeed * elapsed)
      end
    end
  elseif active then
    p.currentCharge, f.remaining_warmup = 0, f.warmup
  end
  return r
end

local function firstC2(f, obs, limit)
  for _ = 1, limit do
    tick(f, obs)
    if f.releases[1] then return f.releases[1] end
  end
end

-- A chain that fails every 2.0 gate (score/enemies/bullets/net fraction) but
-- clears the bloom gates: it still needs a real ignition point.
local mediocre = { has_ignition = true, chain_score = 2.6, chain_enemies = 2, chain_bullets = 5,
  direct_bullets = 12, contested_bullets = 0, target_x = 0, target_y = 320, chain_ids = { 1 } }

-- 1. Entry and exit hysteresis on whole-field erasable pressure.
do
  local f = fixture({ energy = 200 })
  tick(f, observation(200))
  check(f.state.bloom_mode == true, "dense field must enter bloom mode")
  check((f.state.bloom_enters or 0) == 1, "bloom entry counted")
  tick(f, observation(0))
  check(f.state.bloom_mode == nil and f.state.bloom_exit_reason == "pressure_dropped",
    "calm field must leave bloom mode")
  local f2 = fixture({ energy = 200 })
  tick(f2, observation(120))
  check(f2.state.bloom_mode == nil, "pressure below the entry threshold must not enter bloom")
  local f3 = fixture({ energy = 100 })
  tick(f3, observation(200))
  check(f3.state.bloom_mode == nil, "bloom needs enough energy for a C2")
  local f4 = fixture({ energy = 200 })
  tick(f4, observation(nil))
  check(f4.state.bloom_mode == nil, "missing pressure reading must not invent bloom")
end

-- 2. The relaxed gate releases the C2 rhythm early; the same observation keeps
-- waiting for the 8-second deadline without bloom pressure.
do
  local bloomed = fixture({ energy = 200 })
  tick(bloomed, observation(200))
  local early = firstC2(bloomed, observation(200, mediocre), 200)
  check(early ~= nil, "bloom mode must be able to start the C2 charge")
  check(early.call <= 60, "bloom C2 charge should start promptly, not after a long wait")
  local plain = fixture({ energy = 200 })
  local late = firstC2(plain, observation(0, mediocre), 200)
  check(late == nil, "without bloom the poor chain must not start an early C2")
end

-- 3. Bloom shortens the same independent deadline (no bypass): with an empty
-- chain the release still happens, but on the bloom rhythm.
do
  local f = fixture({ energy = 200 })
  tick(f, observation(200))
  local event = firstC2(f, observation(200, {}), 600)
  check(event ~= nil, "bloom cadence must still release a C2")
  check(event.time <= 275, "bloom deadline must be shorter than the 480-unit default")
  check(event.time >= 200, "bloom release must still allow warm-up and charging")
end

-- 4. Bloom exits when completed C2 cycles stop returning energy.
do
  local f = fixture({ energy = 200 })
  tick(f, observation(200))
  local event = firstC2(f, observation(200, {}), 600)
  check(event ~= nil and f.state.bloom_mode == true, "bloom active before the dry cycles")
  local p = f.world.player
  p.currentChargeMax = 50
  for _ = 1, 170 do tick(f, observation(200, {})) end
  check((f.state.bloom_low_cycles or 0) == 1, "first dry C2 cycle counted")
  local before = #f.releases
  p.currentChargeMax = 200
  for _ = 1, 500 do
    tick(f, observation(200, {}))
    if #f.releases > before then break end
  end
  check(#f.releases > before, "bloom kept the C2 rhythm after a dry cycle")
  p.currentChargeMax = 50
  for _ = 1, 170 do tick(f, observation(200, {})) end
  check(f.state.bloom_mode == nil and f.state.bloom_exit_reason == "energy_not_recovering",
    "two non-recovering cycles must leave bloom mode")
end

-- 5. The opponent gauge only relaxes the entry threshold; it never attacks.
do
  local ahead = fixture({ energy = 300, opponent = { valid = true, chargeCurrent = 0,
    chargeMax = 150, chargeSpeed = 10, state = 0, protectionFrames = 0, life = 5,
    spellPoint = 0, combo = 0 } })
  tick(ahead, observation(120))
  check(ahead.state.bloom_mode == true, "clearly higher gauge may enter bloom earlier")
  local behind = fixture({ energy = 300, opponent = { valid = true, chargeCurrent = 0,
    chargeMax = 250, chargeSpeed = 10, state = 0, protectionFrames = 0, life = 5,
    spellPoint = 0, combo = 0 } })
  tick(behind, observation(120))
  check(behind.state.bloom_mode == nil, "gauge that is not ahead keeps the normal threshold")
  local missing = fixture({ energy = 300, opponent = { valid = false, chargeCurrent = 0,
    chargeMax = 0, chargeSpeed = 0, state = 0, protectionFrames = 0, life = 0,
    spellPoint = 0, combo = 0 } })
  tick(missing, observation(120))
  check(missing.state.bloom_mode == nil, "invalid opponent snapshot must not relax the threshold")
  local malformed = fixture({ energy = 300, opponent = { valid = true } })
  tick(malformed, observation(120))
  check(malformed.state.bloom_mode == nil, "malformed opponent fields are ignored, not trusted")
  local calm = fixture({ energy = 300, opponent = { valid = true, chargeCurrent = 0,
    chargeMax = 100, chargeSpeed = 10, state = 0, protectionFrames = 0, life = 5,
    spellPoint = 0, combo = 0 } })
  local late = firstC2(calm, observation(0, mediocre), 200)
  check(late == nil, "opponent gauge alone must never trigger an attack")
end

-- 6. Bloom never bypasses engine gates.
do
  local f = fixture({ energy = 200, canCharge = false })
  tick(f, observation(200))
  for _ = 1, 30 do tick(f, observation(200, mediocre)) end
  check(#f.releases == 0, "bloom must not release while the action gate blocks charging")
end

-- 7. Battle-time rule: after bloom_late_seconds the entry/exit thresholds
-- drop, so a medium field keeps the loop without a rank signal.
do
  local f = fixture({ energy = 200 })
  tick(f, observation(120))
  check(f.state.bloom_mode == nil, "medium field before the late window must not enter bloom")
  for _ = 1, 179 do tick(f, observation(120)) end
  check(f.state.bloom_mode == nil, "180 Timer units are only three seconds, not the late window")
  f.state.battle_time = 180 * 60 - 1
  tick(f, observation(120))
  check((f.state.battle_time or 0) == 180 * 60, "battle clock reaches 180 seconds in Timer units")
  check(f.state.bloom_mode == true, "after the late window a medium field enters bloom")
  tick(f, observation(50))
  check(f.state.bloom_mode == true, "late exit threshold tolerates a dip")
  tick(f, observation(30))
  check(f.state.bloom_mode == nil and f.state.bloom_exit_reason == "pressure_dropped",
    "late exit threshold still ends bloom when the field empties")
end

-- 8. Rank proxy: a self-calibrated rise in the mean erasable-bullet speed
-- lowers the threshold before the late window. Nothing reads the game rank.
do
  local f = fixture({ energy = 200 })
  local function moving(pressure, speed)
    local obs = observation(pressure)
    obs.counts.field_erasable_speed = speed
    return obs
  end
  for _ = 1, 40 do tick(f, moving(100, 2.0)) end
  check(f.state.bloom_mode == nil, "slow bullets below the base threshold must not bloom")
  check(f.state.bullet_speed_ref and f.state.bullet_speed_ref < 2.5, "speed reference tracked")
  for _ = 1, 60 do tick(f, moving(100, 4.0)) end
  check(f.state.bloom_mode == true, "clearly faster bullets lower the entry threshold")
  local g = fixture({ energy = 200 })
  for _ = 1, 120 do tick(g, moving(100, 3.0)) end
  check(g.state.bloom_mode == nil, "a steady speed must not be mistaken for a rank rise")
end

-- 9. Movement-cap pressure: when the dodge planner reports that the human-like
-- direction-change cap overrode a better escape, the policy must answer with a
-- charge attack instead of more movement, even though the field itself is calm.
do
  local forced = { focus = false, key = 0, move_cap_forced = true }
  local f = fixture({ energy = 200 })
  for _ = 1, f.cfg.move_cap_escape_frames + 1 do
    tick(f, observation(40, mediocre), forced)
  end
  check((f.state.move_cap_pressure or 0) >= f.cfg.move_cap_escape_frames,
    "cap pressure from the dodge planner must be tracked")
  check(f.state.cap_escape == true, "cap pressure must arm the movement-cap escape")
  local started = f.state.target_level ~= nil or #f.releases > 0
  for _ = 1, 40 do
    if not started then tick(f, observation(40, mediocre), forced) end
    started = started or f.state.target_level ~= nil or #f.releases > 0
  end
  check(started, "cap-blocked dodge must start a charge attack")
  local plain = fixture({ energy = 200 })
  local late = firstC2(plain, observation(40, mediocre), 200)
  check(late == nil, "the same calm field without cap pressure keeps waiting")
  local poor = fixture({ energy = 100 })
  for _ = 1, 20 do tick(poor, observation(40, mediocre), forced) end
  for _ = 1, 20 do tick(poor, observation(40, mediocre), forced) end
  check((poor.state.release_c2 or 0) == 0, "cap escape must not release C2 without C2 energy")
end

-- 10. Attention overload: when the dodge planner cannot see what is about to
-- hit it, the same escape path must answer with a charge attack.
do
  local overloaded = { focus = false, key = 0, attention_escape = true }
  local f = fixture({ energy = 200 })
  for _ = 1, f.cfg.attention_escape_frames + 1 do
    tick(f, observation(40, mediocre), overloaded)
  end
  check((f.state.attention_pressure or 0) >= f.cfg.attention_escape_frames,
    "attention overload from the dodge planner must be tracked")
  check(f.state.attention_escape == true, "attention pressure must arm its own escape flag")
  check(f.state.cap_escape == true, "attention pressure must reuse the charge-attack escape")
  local started = f.state.target_level ~= nil or #f.releases > 0
  for _ = 1, 40 do
    if not started then tick(f, observation(40, mediocre), overloaded) end
    started = started or f.state.target_level ~= nil or #f.releases > 0
  end
  check(started, "attention overload must start a charge attack")
  local calm = fixture({ energy = 200 })
  for _ = 1, 20 do tick(calm, observation(40, mediocre), { focus = false, key = 0 }) end
  check((calm.state.attention_pressure or 0) == 0 and calm.state.attention_escape ~= true,
    "a readable field must not arm the attention escape")
end

print(string.format("PASS: bloom mode entry/exit, late-window and rank-proxy entry, prompt C2 rhythm, relaxed chain gate, opponent gauge, movement-cap and attention-overload escapes, gate safety (%d checks)", checks))
