-- Policy state tests use explicit snapshots, not a fabricated game simulator.
-- They verify decisions only; none establish character-specific live efficacy.
local bloom = dofile("bloom.lua")
local function copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = type(v) == "table" and copy(v) or v end
  return out
end
local function config(overrides)
  local out = copy(bloom.defaults)
  out.c1_score, out.c2_score, out.shot_score = 3, 4.5, 2.2
  out.focus_value, out.focus_mismatch_cost = 0.7, 8
  for k, v in pairs(overrides or {}) do out[k] = v end
  return out
end
local function world(character)
  -- Legacy geometry-only fixtures use Marisa; audited Reimu proof paths have
  -- their own suite and an explicit verified snapshot in the 16-role case.
  return { player = { character = character or 1, x = 0, y = 320, life = 10,
    currentCharge = 0, currentChargeMax = 400, chargeSpeed = 10,
    spellPoint = 0, combo = 0,
    sensor = { valid = true, apiVersion = 1, state = 0, canCharge = true,
      cutIn = false, timeScale = 1, protectionFrames = 0,
      chargeBlockFrames = 0, chargeWarmupFrames = 0 } },
    enemies = {}, bullets = {}, exAttacks = {} }
end
local function observation(overrides)
  local out = { valid = true, has_target = true, has_ignition = true,
    ignition_aligned = true, chain_score = 8, chain_enemies = 4, chain_bullets = 12,
    future_score = 8, future_enemies = 4, future_bullets = 12,
    ignition_id = 1, chain_ids = { 1, 2, 3, 4 },
    focus_value = 0, target_x = 0, target_y = 320 }
  for k, v in pairs(overrides or {}) do out[k] = v end
  -- Most historical policy fixtures intentionally give both attack modes
  -- equivalent resources; tests below explicitly separate them.
  if out.c2 == nil then
    out.c2 = { has_ignition = out.has_ignition, future_has_ignition = out.has_ignition,
      chain_score = out.chain_score, chain_enemies = out.chain_enemies,
      chain_bullets = out.chain_bullets, chain_ids = out.chain_ids,
      future_score = out.future_score, future_enemies = out.future_enemies,
      future_bullets = out.future_bullets, seed_id = out.ignition_id,
      target_x = out.target_x, target_y = out.target_y }
  end
  return out
end
local poor = observation({ has_target = false, has_ignition = false,
  chain_score = 0, chain_enemies = 0, chain_bullets = 0, future_score = 0 })
local function step(w, state, cfg, obs, actual_focus)
  local r = bloom.update(w, state, cfg, obs)
  if actual_focus == nil then actual_focus = r.intent.focus end
  bloom.feedback(state, { focus = actual_focus, key = actual_focus and 4 or 0 }, cfg)
  return r
end
local function noCharge(r, message)
  assert(not r.press_z and r.target_level == 0 and r.phase ~= "release", message)
end

-- Read the actual vendor enum instead of assuming 14 or excluding unlockable
-- prismriver characters. th09types.h has Reimu=0 through Lunasa=15.
do
  local file = assert(io.open("../../vendor/ka_ai_duka-src/inject/th09types.h", "r"))
  local body = assert(file:read("*a"):match("enum%s+PlayerCharacter%s*(%b{})")); file:close()
  body = body:gsub("[{}]", "")
  local names = {}
  for entry in body:gmatch("[^,]+") do
    names[#names + 1] = assert(entry:match("^%s*([%w_]+)"))
  end
  assert(#names == 16 and names[1] == "Reimu" and names[16] == "Lunasa")
  for index, name in ipairs(names) do
    local w, state, cfg = world(index - 1), {}, config()
    local r = step(w, state, cfg, observation())
    assert(r.press_z and r.target_level == 2, name .. " excluded from C2 bloom")
    -- A separate poorer scene still uses active C1, with a full energy meter.
    local weaker = observation({ chain_score = 3.5, chain_enemies = 2, chain_bullets = 2, future_score = 3.5 })
    if index == 1 then
      weaker.c1 = { valid = true, has_ignition = true, damage_model_valid = true, kill_count = 1,
        chain_ids = {1,2}, chain_score = 3.5, chain_enemies = 2, chain_bullets = 2 }
    end
    r = step(w, {}, cfg, weaker)
    assert(r.press_z and r.target_level == 1, name .. " lost active C1 bloom")
  end
end

-- Neither HP danger nor score can turn scarce resources into emergency C2.
do
  local w, state, cfg = world(), {}, config()
  w.player.life, w.player.spellPoint = 1, 2000000
  w.bullets = { { x = 0, y = 320, vx = 0, vy = 5, danger = 1e30 } }
  for _ = 1, 240 do noCharge(step(w, state, cfg, poor), "scarce resources caused emergency attack") end
  local r = step(w, state, cfg, observation())
  assert(r.press_z and r.target_level == 2, "high Spell Point reintroduced the old firing lock")
end

-- C2 is preferred when every resource condition holds; enemy/bullet minima
-- remain independent requirements rather than a single inflated total score.
do
  local w, cfg = world(), config()
  assert(step(w, {}, cfg, observation()).target_level == 2)
  assert(step(w, {}, cfg, observation({ chain_enemies = 2 })).target_level == 1)
  assert(step(w, {}, cfg, observation({ chain_bullets = 7 })).target_level == 1)
  local dispersed = step(w, {}, cfg, observation({ future_enemies = 1, future_bullets = 2, future_score = 2 }))
  assert(dispersed.target_level ~= 2, "current resources hid a chain that disperses before C2")
  local r = step(w, {}, cfg, observation({ has_ignition = false }))
  noCharge(r, "a non-ignitable positioning target started an attack")
end

-- While resources remain viable, the choice stays deterministic as the meter
-- increases. A sampled C2 crossing releases, including fractional progress.
do
  local w, state, cfg = world(), {}, config()
  assert(step(w, state, cfg, observation()).target_level == 2)
  for _, amount in ipairs({ 35, 99, 105, 160, 199.5, 199.9995 }) do
    w.player.currentCharge = amount
    local r = step(w, state, cfg, observation())
    assert(r.press_z and r.target_level == 2 and r.phase == "charge", "commitment was rerolled or abandoned")
  end
  w.player.currentCharge = 205
  local r = step(w, state, cfg, poor)
  assert(not r.press_z and r.phase == "release" and r.release_c2 == 1 and r.release_c1 == 0)
  assert(state.target_level == nil, "released C2 retained a target that could continue to C3/C4")
  -- An old full value after release does not start a new charge or new C2.
  w.player.currentCharge = 400
  for _ = 1, 30 do
    r = step(w, state, cfg, observation())
    assert(not r.press_z and r.release_c2 == 1 and r.target_level == 0, "stale full charge replayed a release")
  end
  w.player.currentCharge = 0
  r = step(w, state, cfg, observation())
  assert(r.press_z and r.target_level == 2, "fresh reset snapshot did not permit the next planned C2")
end

-- Resource loss is rechecked during C2 preparation. Below C1 it cancels;
-- between C1 and C2 it ends at C1. Once 200 is actually observed, the input
-- must release C2 immediately even if the useful chain has just disappeared.
do
  for _, amount in ipairs({ 35, 99.9995, 100, 150, 199.9995, 200, 205 }) do
    local w, state, cfg = world(), {}, config()
    assert(step(w, state, cfg, observation()).target_level == 2)
    w.player.currentCharge = amount
    local r = step(w, state, cfg, poor)
    assert(not r.press_z and r.target_level == 0, "lost chain kept charging at " .. amount)
    if amount < 100 then
      assert(r.release_c1 == 0 and r.release_c2 == 0 and r.reason == "chain_lost_cancel")
    elseif amount < 200 then
      assert(r.release_c1 == 1 and r.release_c2 == 0 and r.reason == "chain_lost_end_c1")
    else
      assert(r.phase == "release" and r.release_c2 == 1 and r.release_c1 == 0)
    end
  end
  local w, state, cfg = world(), {}, config()
  step(w, state, cfg, observation())
  w.player.currentCharge = 140
  local r = step(w, state, cfg, observation({ future_score = 0, future_enemies = 0, future_bullets = 0 }))
  assert(r.release_c1 == 1 and r.release_c2 == 0, "future chain loss did not stop committed C2")
end

-- C1 is an intentional full-energy attack, and releases at its own threshold
-- rather than waiting for C2 just because 400 energy happens to be available.
do
  local w, state, cfg = world(), {}, config()
  local c1 = observation({ chain_score = 3.5, chain_enemies = 2, chain_bullets = 2, future_score = 3.5 })
  assert(step(w, state, cfg, c1).target_level == 1)
  w.player.currentCharge = 99.9995
  assert(step(w, state, cfg, observation()).target_level == 1, "C1 target silently upgraded to C2")
  w.player.currentCharge = 103
  local r = step(w, state, cfg, observation())
  assert(not r.press_z and r.phase == "release" and r.release_c1 == 1 and r.release_c2 == 0)
end

-- Gate closed at rest: do not pre-hold a stale charge. Gate closure mid-plan
-- must not falsely report an attack release; reopen then uses fresh progress.
do
  local w, cfg, state = world(), config(), {}
  w.player.currentCharge, w.player.sensor.canCharge = 400, false
  for _ = 1, 20 do noCharge(step(w, state, cfg, observation()), "gate closure accepted stale full charge") end
  w.player.currentCharge, w.player.sensor.canCharge = 0, true
  assert(step(w, state, cfg, observation()).target_level == 2)
  w.player.currentCharge, w.player.sensor.canCharge = 80, false
  for _ = 1, 20 do
    local r = step(w, state, cfg, observation())
    assert(r.press_z and r.target_level == 2 and r.release_c2 == 0)
  end
  w.player.sensor.canCharge, w.player.currentCharge = true, 205
  local r = step(w, state, cfg, observation())
  assert(r.phase == "release" and not r.press_z and r.release_c2 == 1)
end

-- A useful current C2 chain starts charging before a better predicted overlap;
-- an insufficient current chain can wait, and unaligned/invalid targets cannot
-- start fresh attacks.
do
  local w, cfg = world(), config()
  local r = step(w, {}, cfg, observation({ future_score = 20 }))
  assert(r.press_z and r.target_level == 2, "waiting until future overlap would delay starting C2")
  r = step(w, {}, cfg, observation({ chain_score = 3.5, chain_enemies = 2, chain_bullets = 2, future_score = 20 }))
  noCharge(r, "weak current overlap was not allowed to mature")
  assert(r.reason == "wait_for_overlap")
  r = step(w, {}, cfg, observation({ ignition_aligned = false, c2 = {} }))
  noCharge(r, "unaligned ignition fired")
  r = step(w, {}, cfg, { valid = false })
  noCharge(r, "invalid observation started a charge")
end

-- The complete post-release feedback window adjusts future resource demand,
-- without granting energy or switching any character to another playstyle.
do
  local w, state, cfg = world(), {}, config({ release_settle_frames = 2, recharge_observe_frames = 6 })
  step(w, state, cfg, observation())
  w.player.currentCharge = 205; step(w, state, cfg, observation())
  w.player.currentCharge, w.player.currentChargeMax = 0, 90
  for _ = 1, 6 do step(w, state, cfg, poor) end
  assert(state.last_cycle_ready == false and state.refill_pressure > 0, "failed C2 refill did not affect planning")
  local pressure = state.refill_pressure
  w.player.currentChargeMax = 400; step(w, state, cfg, observation())
  w.player.currentCharge = 205; step(w, state, cfg, observation())
  w.player.currentCharge, w.player.currentChargeMax = 0, 150; step(w, state, cfg, poor)
  w.player.currentChargeMax = 220; step(w, state, cfg, poor)
  assert(state.last_cycle_ready and state.last_cycle_gain == 70 and state.refill_pressure < pressure)
end

-- Count actual defensive Shift, not just the bloom intent, and require a
-- sustained high-speed interval before opening a bounded capture window.
do
  local w, state = world(), {}
  local cfg = config({ fast_min_frames = 4, focus_min_frames = 2,
    focus_max_frames = 3, focus_budget_frames = 3, focus_budget_window = 12 })
  local focus = observation({ has_ignition = false, ignition_aligned = false,
    chain_score = 0, chain_enemies = 0, chain_bullets = 0, future_score = 0,
    focus_value = 1, focus_x = 0, focus_y = 260 })
  for _ = 1, 4 do assert(not step(w, state, cfg, focus, false).intent.focus) end
  assert(step(w, state, cfg, focus, true).intent.focus, "capture window did not open after fast dwell")
  for _ = 1, 2 do assert(step(w, state, cfg, focus, true).intent.focus) end
  assert(not step(w, state, cfg, focus, false).intent.focus, "capture did not stop at its maximum/budget")
  assert(state.focus_used == 3)
  for _ = 1, 4 do assert(not step(w, state, cfg, focus, false).intent.focus) end
  local defensive = {}
  for _ = 1, 6 do step(w, defensive, cfg, poor, true) end
  assert(defensive.fast_frames == 0 and defensive.focus_used == 6, "defensive Shift absent from budget")
  for _ = 1, 4 do assert(not step(w, defensive, cfg, focus, false).intent.focus) end
  local mask_feedback = {}
  bloom.feedback(mask_feedback, { key = 4 }, cfg)
  assert(mask_feedback.focus_used == 1 and mask_feedback.fast_frames == 0)
  for _ = 1, 12 do bloom.feedback(mask_feedback, { key = 0 }, cfg) end
  assert(mask_feedback.focus_used == 0 and mask_feedback.fast_frames == 12, "expired Shift budget was not retired")
end

-- Losing the spirit opportunity respects the minimum dwell then ends focus;
-- it cannot cause endless low-speed idling once the window is no longer useful.
do
  local w, state, cfg = world(), {}, config({ fast_min_frames = 1, focus_min_frames = 2, focus_max_frames = 5 })
  local focus = observation({ has_ignition = false, ignition_aligned = false,
    focus_value = 1, focus_x = 0, focus_y = 260 })
  step(w, state, cfg, focus, false)
  assert(step(w, state, cfg, focus, true).intent.focus)
  assert(step(w, state, cfg, poor, true).intent.focus)
  assert(not step(w, state, cfg, poor, false).intent.focus)
end

-- Burst 1/0 and zero settle must still contain a release edge; otherwise a
-- normal-shot request silently turns into held-Z charge on every update.
do
  local shot = observation({ chain_score = 2.5, chain_enemies = 2, chain_bullets = 1, future_score = 2.5 })
  for _, length in ipairs({ 0, 1, 2, 3, 8 }) do
    local w, state, cfg = world(), {}, config({ shot_burst_frames = length, shot_settle_frames = 0 })
    w.player.currentChargeMax = 0
    local previous = false
    for _ = 1, 40 do
      local r = step(w, state, cfg, shot)
      assert(not (previous and r.press_z), "normal shot burst continuously held Z at configured length " .. length)
      assert(r.target_level == 0)
      previous = r.press_z
    end
  end
  local w, state, cfg = world(), {}, config()
  w.player.currentChargeMax = 0
  assert(step(w, state, cfg, shot).press_z)
  local r = step(w, state, cfg, observation({ has_target = false, has_ignition = false }))
  assert(not r.press_z and state.shot_remaining == 0, "burst ignored a lost target")
  state = {}
  assert(step(w, state, cfg, shot).press_z)
  r = step(w, state, cfg, observation({ has_ignition = false }))
  assert(not r.press_z and state.shot_remaining == 0, "burst kept firing at a non-ignitable positioning target")
end

-- Pauses freeze policy timers and focus accounting. HP loss cancels a charge
-- plan; recovering from hit state cannot replay its pending attack release.
do
  local w, state, cfg = world(), {}, config({ release_settle_frames = 2 })
  step(w, state, cfg, observation())
  local frame, used = state.frame, state.focus_used
  w.player.sensor.cutIn = true
  for _ = 1, 10 do
    local r = step(w, state, cfg, observation(), true)
    assert(r.phase == "paused" and r.press_z)
    assert(state.frame == frame and state.focus_used == used)
  end
  w.player.sensor.cutIn, w.player.sensor.timeScale = false, 0
  assert(step(w, state, cfg, observation()).phase == "paused")
  w.player.life, w.player.sensor.state, w.player.sensor.timeScale = 9, 4, 1
  local r = step(w, state, cfg, observation())
  assert(r.phase == "paused" and not r.press_z and r.target_level == 0)
  w.player.sensor.state, w.player.currentCharge = 0, 0
  for _ = 1, 2 do assert(not step(w, state, cfg, observation()).press_z) end
  r = step(w, state, cfg, observation())
  assert(r.press_z and r.target_level == 2 and r.release_c2 == 0)
end

-- Identical explicit observation/player/feedback sequences are deterministic;
-- no random selection, wall clock, or cross-match state affects the outcome.
do
  local first, second, w, cfg = {}, {}, world(), config({ fast_min_frames = 3 })
  for tick = 1, 300 do
    local obs = tick % 7 < 3 and poor or observation()
    w.player.currentCharge = tick % 31 == 0 and 205 or 0
    w.player.spellPoint = tick * 12345
    w.player.sensor.timeScale = tick % 11 == 0 and 0 or 1
    local a, b = step(w, first, cfg, obs, tick % 5 == 0), step(w, second, cfg, obs, tick % 5 == 0)
    for _, key in ipairs({ "press_z", "phase", "reason", "target_level", "focus", "focus_used", "release_c1", "release_c2", "refill_pressure" }) do
      assert(a[key] == b[key], "nondeterministic " .. key .. " at tick " .. tick)
    end
    assert(a.target_level <= 2 and b.target_level <= 2)
  end
  bloom.reset(first)
  assert(next(first) == nil)
end

-- A C2 seed is independent of ordinary-shot ignition/alignment. Its original
-- node lock and movement intent must follow C2, not a remote shot target.
do
  local w, cfg = world(), config()
  local obs = observation({ has_target = false, has_ignition = false, ignition_aligned = false,
    chain_score = 0, chain_enemies = 0, chain_bullets = 0,
    c2 = { has_ignition = true, future_has_ignition = true,
      chain_score = 8, chain_enemies = 4, chain_bullets = 12, chain_ids = {71,72,73,74},
      future_score = 8, future_enemies = 4, future_bullets = 12,
      seed_id = 71, target_x = 40, target_y = 320 } })
  for character = 0,15 do
    w.player.character = character
    local state = {}
    local r = step(w, state, cfg, obs)
    assert(r.target_level == 2 and r.press_z, 'C2 could not ignite unactivated/off-axis chain')
    assert(state.attack_ids[71] and state.attack_ids[74] and not state.attack_ids[1], 'C2 locked the shot chain')
    assert(r.intent.target_x == 40 and r.intent.target_y == 320, 'C2 inherited shot positioning')
    w.player.currentCharge = 150
    assert(step(w, state, cfg, obs).target_level == 2, 'C2 recheck used ordinary ignition')
    w.player.currentCharge = 0
  end
  w.player.currentChargeMax = 100
  noCharge(step(w, {}, cfg, obs), 'unactivated C2 seed incorrectly started C1/ordinary shot')
  w.player.currentChargeMax = 400
  obs.c2.chain_bullets, obs.c2.future_bullets = 0, 0
  obs.c2.direct_bullets, obs.c2.contested_bullets = 9999, 9999
  noCharge(step(w, {}, cfg, obs), 'swallowed/contested bullets funded C2')
  obs.chain_score, obs.chain_enemies, obs.chain_bullets = 9999, 128, 9999
  noCharge(step(w, {}, cfg, obs), 'ordinary-shot total leaked into C2 budget')
  obs.c2 = nil
  noCharge(step(w, {}, cfg, obs), 'missing C2 estimate reused ordinary-shot totals')
end

print("bloom_policy_test: PASS (16 character enum entries, separate C2 ignition/net resources)")
