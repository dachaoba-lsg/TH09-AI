-- Synthetic C2 cadence and post-release route checks. No game/damage simulator.
local bloom = dofile('bloom.lua')
local checks = 0
local function check(value, message) checks = checks + 1; assert(value, message) end

local function world()
  return { player = {
    x = 0, y = 320, life = 10, currentCharge = 0, currentChargeMax = 200,
    chargeSpeed = 10, character = 0,
    sensor = { apiVersion = 1, valid = true, state = 0, timeScale = 1,
      canCharge = true, canPressZ = true, cutIn = false, protectionFrames = 0,
      chargeWarmupFrames = 0, chargeBlockFrames = 0, followupApiVersion = 1,
      c1ActionActive = false, c1ActionAge = 0, commonWavesValid = true,
      commonWaves = {} }
  }}
end

local function observation(overrides)
  local out = { valid = true, has_target = true, has_ignition = true,
    ignition_aligned = true, ignition_id = 1, target_x = 0, target_y = 320,
    chain_ids = { 1, 2, 3 }, chain_score = 6, chain_enemies = 3,
    chain_bullets = 20, future_score = 6, future_enemies = 3,
    future_bullets = 20, focus_value = 0, counts = { erasable = 0 },
    timing = { valid = true, improving = false, urgency = false },
    c2 = { has_ignition = true, future_has_ignition = true, seed_id = 1,
      target_x = 0, target_y = 320, chain_ids = { 1, 2, 3 }, chain_score = 6,
      chain_enemies = 3, chain_bullets = 20, future_score = 6,
      future_enemies = 3, future_bullets = 20, direct_bullets = 0,
      contested_bullets = 0 },
    c1 = { valid = true, has_ignition = true, chain_score = 3,
      chain_enemies = 2, chain_bullets = 4, hit_count = 1 },
    capture = { valid = true, has_target = false } }
  for k, v in pairs(overrides or {}) do out[k] = v end
  return out
end

local function step(w, state, obs)
  local result = bloom.update(w, state, bloom.defaults, obs)
  bloom.feedback(state, { focus = result.intent.focus }, bloom.defaults)
  return result
end

-- A rich chain shortens only the independent C2 deadline. C1 retains the
-- normal clock, so an ordinary C1 cannot manufacture a faster C2 loop.
do
  local w, state = world(), { since_c2 = 239, since_c = 0 }
  local r = step(w, state, observation())
  check(r.cadence_limit == 200, 'hot chain did not select the bounded hot C2 interval')
  check(r.bloom_cadence == true, 'hot chain did not enter cadence mode')
  check(r.press_z and r.target_level == 2 and r.cadence_charge,
    'hot chain did not start the independent C2 cadence charge')
  local w2, state2 = world(), { since_c2 = 239, since_c = 0 }
  local o2 = observation()
  o2.c2.chain_bullets = 8; o2.chain_bullets = 8
  r = step(w2, state2, o2)
  check(r.cadence_limit == 260 and r.bloom_cadence == true,
    'normal rich chain did not select the 260-frame C2 interval')
  check(r.press_z and r.target_level == 2, 'normal rich chain missed C2 cadence')
  local w3, state3 = world(), { since_c2 = 479, since_c = 0 }
  local poor = observation({ c2 = { has_ignition = false }, has_ignition = false })
  r = step(w3, state3, poor)
  check(r.cadence_limit == 480 and not r.bloom_cadence,
    'poor field shortened the C2 deadline without a real ignition')
end

-- Release C2, confirm real state3 protection, then let it expire. The route
-- preference goes low during confirmation/protection and can return to mid
-- only when lower-field pressure is observed.
do
  local w, state, o = world(), {}, observation()
  w.player.currentCharge, w.player.currentChargeMax = 200, 300
  state.target_level, state.fresh_charge = 2, true
  local r = step(w, state, o)
  check(r.phase == 'release' and r.release_c2 == 1, 'C2 fixture did not release')
  check(state.post_c2_phase == 'confirm', 'C2 release did not start confirmation phase')
  w.player.currentCharge, w.player.currentChargeMax = 0, 100
  local sensor = w.player.sensor
  sensor.state, sensor.protectionFrames = 3, 48
  sensor.canCharge, sensor.canPressZ = false, true
  sensor.c1ActionActive, sensor.c1ActionAge = true, 0
  sensor.commonWaves = {{slotId = 7, type = 1, x = 0, y = 320, radius = 4,
    growth = 4, life = 47, delay = 0, enabled = true, listed = true}}
  r = step(w, state, o)
  check(r.followup_confirmed and r.post_c2_phase == 'protected',
    'real C2 protection did not enter protected phase')
  check(r.intent.post_c2_target_y == bloom.defaults.post_c2_low_y,
    'protected C2 route did not prefer the low landing band')
  sensor.state, sensor.protectionFrames = 0, 0
  sensor.canCharge, sensor.canPressZ = true, true
  sensor.c1ActionActive = false
  o.counts.erasable = bloom.defaults.post_c2_pressure_bullets + 1
  r = step(w, state, o)
  check(not r.followup_confirmed and r.post_c2_phase == 'rearm',
    'expired C2 protection did not enter rearm phase')
  check(r.intent.post_c2_target_y == bloom.defaults.post_c2_mid_y,
    'lower-field pressure did not pull the route back to mid field')
  for _ = 1, bloom.defaults.post_c2_phase_frames do r = step(w, state, o) end
  check(r.post_c2_phase == '' and (r.intent.post_c2_target_y == nil or r.intent.post_c2_target_y == 0),
    'post-C2 route preference was not bounded: phase=' .. tostring(r.post_c2_phase)
      .. ' target=' .. tostring(r.intent.post_c2_target_y) .. ' age=' .. tostring(r.post_c2_age))
end

print('bloom_c2_cycle_test: PASS (' .. checks .. ' assertions; cadence/phase only, no live-game claim)')
