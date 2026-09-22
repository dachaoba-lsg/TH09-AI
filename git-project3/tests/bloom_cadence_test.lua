-- Cadence decisions against a small explicit input/charge reference fixture.
-- This is NOT a game simulator: no movement, bullets, recharge attribution,
-- character C effects, damage or native callback timing is simulated. Energy
-- snapshots are supplied by each test; keeping energy at 200 does not prove
-- that a real C2 returns enough energy for another C2.
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
local poor = { valid = true, has_target = false, has_ignition = false,
  ignition_aligned = false, chain_score = 0, chain_enemies = 0,
  chain_bullets = 0, future_score = 0, focus_value = 0, c2 = {} }
local c1 = { valid = true, has_target = true, has_ignition = true,
  ignition_aligned = true, chain_score = 3.5, chain_enemies = 2,
  chain_bullets = 1, future_score = 3.5, focus_value = 0,
  ignition_id = 1, chain_ids = {1, 2}, target_x = 0, target_y = 320, c2 = {} }
local shot = copy(c1)
shot.chain_score, shot.future_score = 2.5, 2.5
local rich = copy(c1)
rich.c2 = { has_ignition = true, future_has_ignition = true,
  chain_score = 8, chain_enemies = 4, chain_bullets = 12,
  future_score = 8, future_enemies = 4, future_bullets = 12,
  seed_id = 10, chain_ids = {10, 11, 12, 13}, target_x = 0, target_y = 320 }

local function fixture(options)
  options = options or {}
  local warmup = options.warmup or 11
  return { state = {}, cfg = config(options.cfg), time = 0, calls = 0,
    warmup = warmup, remaining_warmup = warmup, held = false,
    releases = {}, shot_presses = 0,
    world = { player = { character = 0, x = 0, y = 320, life = 10,
      currentCharge = 0, currentChargeMax = options.energy or 200,
      chargeSpeed = options.speed or 10,
      sensor = { valid = true, apiVersion = 1, state = 0, canCharge = true,
        cutIn = false, timeScale = options.scale or 1,
        chargeWarmupFrames = warmup, chargeBlockFrames = 0 } },
      enemies = {}, bullets = {}, exAttacks = {} } }
end

-- The fixture observes inputs, then advances warmup/charge for one update.
-- A release edge clears charge. Warmup and accumulation use game-time units;
-- a gate closure stops both. These limited assumptions are explicit so the
-- deadline test is not merely a second copy of the policy's due expression.
local function tick(f, obs)
  local p, s = f.world.player, f.world.player.sensor
  s.chargeWarmupFrames = f.remaining_warmup
  local before = p.currentCharge
  local old_c1, old_c2 = f.state.release_c1 or 0, f.state.release_c2 or 0
  local r = bloom.update(f.world, f.state, f.cfg, obs or poor)
  bloom.feedback(f.state, { focus = r.intent.focus, key = r.intent.focus and 4 or 0 }, f.cfg)
  local elapsed = s.cutIn and 0 or math.max(0, math.min(1, s.timeScale))
  f.time, f.calls = f.time + elapsed, f.calls + 1
  check(r.target_level >= 0 and r.target_level <= 2, "target escaped C1/C2")
  local level = r.release_c2 > old_c2 and 2 or (r.release_c1 > old_c1 and 1 or nil)
  if level then
    check(not r.press_z and before >= level * 100 and before < (level + 1) * 100,
      "release request disagreed with the reference charge level")
    check(r.since_c == 0, "C release did not reset the any-C interval")
    if level == 2 then check(r.since_c2 == 0, "C2 release did not reset its own interval") end
    f.releases[#f.releases + 1] = { level = level, time = f.time, call = f.calls }
  end
  if r.phase == "shot" and r.press_z then f.shot_presses = f.shot_presses + 1 end
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
  f.held = r.press_z
  return r
end
local function advance(f, count, obs)
  local r
  for _ = 1, count do r = tick(f, obs) end
  return r
end
local function releases(f, level)
  local out = {}
  for _, event in ipairs(f.releases) do
    if event.level == level then out[#out + 1] = event end
  end
  return out
end
local function untilRelease(f, level, max_calls, obs)
  local before = #releases(f, level)
  for _ = 1, max_calls do
    local r = tick(f, obs)
    if #releases(f, level) > before then return r end
  end
  error("missing C" .. level .. " release within fixture bound")
end

-- Empty resources with enough externally supplied energy: actual RELEASE
-- requests (not just charging) reach the 480-game-unit goal on two cycles.
-- Include fractional speeds/time scales and warmup to catch off-by-one and
-- a mistaken callback-count clock. Each charge increment stays below 100.
do
  for _, speed in ipairs({ 1, 1.75, 4, 8.5, 19.7, 99 }) do
    for _, scale in ipairs({ 1, 0.5, 0.25 }) do
      for _, warmup in ipairs({ 0, 11 }) do
        local f = fixture({ speed = speed, scale = scale, warmup = warmup })
        untilRelease(f, 2, math.ceil(482 / scale))
        untilRelease(f, 2, math.ceil(482 / scale))
        local events = releases(f, 2)
        check(events[1].time <= 480 and events[2].time - events[1].time <= 480,
          "8-second release goal missed at speed=" .. speed .. " scale=" .. scale .. " warmup=" .. warmup)
        check(events[1].time >= 475 and events[2].time - events[1].time >= 475,
          "empty resources started an unrelated early C2")
        check(#releases(f, 1) == 0, "full C2 energy fell back to periodic C1")
      end
    end
  end
end

-- If charging itself needs more than 480 units, the release goal is physically
-- unattainable. Start immediately and wait for a real C2 threshold; do not
-- report an early attack or synthesize charge to satisfy the clock.
do
  local f = fixture({ speed = 0.4 })
  local r = tick(f)
  check(r.press_z and r.target_level == 2 and r.cadence_charge,
    "long charge time did not start preparation immediately")
  advance(f, 479)
  check(#f.releases == 0, "slow charge fabricated an on-time C2")
  untilRelease(f, 2, 40)
  check(releases(f, 2)[1].time > 480, "slow-charge fixture hid its physical deadline limitation")
end

-- Repeated profitable C1s reset only the any-C clock. Independent C2 remains
-- due even when a recent C1, shot settle or another C1 plan is in progress.
do
  local f = fixture({ energy = 400 })
  local last_c2_age = 0
  while #releases(f, 2) < 2 and f.calls < 1000 do
    local previous_c1 = f.state.release_c1 or 0
    local r = tick(f, c1)
    if r.release_c1 > previous_c1 then
      check(r.since_c2 > last_c2_age, "C1 reset or rewound the independent C2 clock")
      check(r.since_c == 0, "C1 failed to reset the any-C clock")
    end
    last_c2_age = r.since_c2
  end
  local c2events = releases(f, 2)
  check(#releases(f, 1) >= 4 and #c2events == 2, "C1 activity starved periodic C2")
  check(c2events[1].time <= 480 and c2events[2].time - c2events[1].time <= 480,
    "C1 postponed the C2 release goal: first=" .. c2events[1].time .. " second=" .. c2events[2].time)
end

-- No energy cannot be invented. An overdue interval stays overdue, C1 is
-- used with 100..199 energy, and new C2 energy resumes promptly instead of
-- starting a fresh 8-second grace period.
do
  local f = fixture({ energy = 99 })
  local r = advance(f, 700)
  check(#f.releases == 0 and not r.press_z and r.since_c2 == 700, "energy shortage reset or bypassed cadence")
  f.world.player.currentChargeMax = 150
  untilRelease(f, 1, 25)
  local first_c1 = releases(f, 1)[1].time
  untilRelease(f, 1, 482)
  local second_c1 = releases(f, 1)[2].time
  check(second_c1 - first_c1 <= 480 and #releases(f, 2) == 0, "low energy lost C1 cadence")
  local resumed = f.time
  f.world.player.currentChargeMax = 200
  untilRelease(f, 2, 35)
  check(releases(f, 2)[1].time - resumed <= 33, "recovered C2 energy waited another interval")
end

-- A closed engine gate can make the target impossible; count elapsed time,
-- issue no new charge at rest, and act promptly when the gate reopens.
do
  local f = fixture()
  f.world.player.sensor.canCharge = false
  local r = advance(f, 600)
  check(not r.press_z and #f.releases == 0 and r.since_c2 == 600, "closed gate fabricated a release")
  f.world.player.sensor.canCharge = true
  untilRelease(f, 2, 35)
  check(releases(f, 2)[1].time <= 633, "gate reopening restarted the deadline")

  f = fixture()
  advance(f, 455)
  check(f.state.target_level == 2 and f.state.cadence_charge, "deadline charge did not begin before the release goal")
  local charged = f.world.player.currentCharge
  f.world.player.sensor.canCharge = false
  r = advance(f, 50)
  check(r.press_z and r.release_c2 == 0 and f.world.player.currentCharge == charged,
    "mid-charge gate closure emitted an attack or progressed the reference charge")
  f.world.player.sensor.canCharge = true
  untilRelease(f, 2, 35)
  check(#releases(f, 2) == 1, "gate reopening replayed a release")
end

-- Hit recovery consumes battle time but cannot issue attack input. Preserve
-- the accumulated interval through both HP loss and state-only transitions.
do
  for _, lose_life in ipairs({ false, true }) do
    local f = fixture()
    advance(f, 455)
    if lose_life then f.world.player.life = 9 end
    f.world.player.sensor.state = 4
    f.world.player.currentCharge, f.remaining_warmup = 0, f.warmup
    for _ = 1, 80 do
      local r = tick(f)
      check(not r.press_z and r.release_c2 == 0, "hit recovery issued attack input")
    end
    check(f.state.since_c2 == 535, "hit recovery restarted or froze C2 cadence")
    f.world.player.sensor.state = 0
    untilRelease(f, 2, 35)
    check(releases(f, 2)[1].time <= 568, "hit recovery discarded the overdue interval")
  end
end

-- Cut-ins and zero timeScale freeze the same interval and do not finish a
-- charge. Resume an existing hold without creating an extra release event.
do
  for _, pause_kind in ipairs({ "cutIn", "timeScale" }) do
    local f = fixture()
    advance(f, 455)
    local age, charged, time = f.state.since_c2, f.world.player.currentCharge, f.time
    if pause_kind == "cutIn" then f.world.player.sensor.cutIn = true
    else f.world.player.sensor.timeScale = 0 end
    local r = advance(f, 90)
    check(r.phase == "paused" and r.press_z and r.since_c2 == age and f.time == time,
      "pause changed cadence or lost a held charge")
    check(f.world.player.currentCharge == charged and #f.releases == 0, "pause progressed charge")
    f.world.player.sensor.cutIn, f.world.player.sensor.timeScale = false, 1
    untilRelease(f, 2, 35)
    check(releases(f, 2)[1].time <= 480, "pause counted against battle-time cadence")
  end
end

-- Ordinary shots are never C events. An overdue C2 preempts an active shot
-- burst/settle as soon as enough energy becomes available.
do
  local f = fixture({ energy = 0 })
  local r = advance(f, 650, shot)
  check(f.shot_presses > 20 and #f.releases == 0, "ordinary-shot fixture did not exercise tap bursts")
  check(r.since_c == 650 and r.since_c2 == 650, "ordinary shots reset a C clock")
  f.world.player.currentChargeMax = 200
  r = tick(f, shot)
  check(r.cadence_charge and r.target_level == 2 and r.press_z, "shot burst delayed overdue C2")
  untilRelease(f, 2, 35, shot)
end

-- Resource-driven early attacks are unchanged. C1 keeps its original level
-- before the independent deadline, while deadline C2 survives resource loss
-- and a larger energy meter without charging on to C3 or C4.
do
  local f = fixture({ energy = 400, warmup = 0 })
  local r = tick(f, c1)
  check(r.target_level == 1 and not r.cadence_charge, "early C1 became a timed-only action")
  untilRelease(f, 1, 15, rich)
  check(#releases(f, 2) == 0, "richer resources upgraded a pre-deadline C1")
  f = fixture({ energy = 400 })
  r = tick(f, rich)
  check(r.target_level == 2 and not r.cadence_charge, "rich resources waited eight seconds for C2")
  untilRelease(f, 2, 35, rich)
  check(releases(f, 2)[1].time < 40, "existing resource-driven C2 cadence was removed")
  f = fixture({ energy = 400 })
  advance(f, 455)
  for _ = 1, 5 do
    r = tick(f, c1)
    check(r.target_level == 2 and r.cadence_charge, "poor C2 resources downgraded a deadline charge")
  end
  untilRelease(f, 2, 25)
  check(#releases(f, 1) == 0, "deadline C2 ended as C1 despite adequate energy")
end

-- A newly available C2 meter may promote an existing C1 only when the C2
-- interval is due. A falling meter cannot leave either kind of plan holding
-- forever at an unreachable target (which risks the engine's auto-release).
do
  local f = fixture({ energy = 150 })
  advance(f, 461)
  check(f.state.target_level == 1 and f.state.cadence_charge, "low-energy C1 deadline did not start")
  f.world.player.currentChargeMax = 200
  local r = tick(f)
  check(r.target_level == 2 and r.cadence_charge and r.release_c1 == 0,
    "pending C1 did not promote to an overdue C2")
  untilRelease(f, 2, 35)
  check(#releases(f, 1) == 0, "C1 unnecessarily released before overdue C2")

  for _, timed in ipairs({ false, true }) do
    for _, remaining_energy in ipairs({ 99, 150 }) do
      f = fixture({ energy = 200 })
      if timed then advance(f, 455) else tick(f, rich) end
      check(f.state.target_level == 2, "energy-loss fixture lacked a pending C2")
      f.world.player.currentChargeMax = remaining_energy
      r = tick(f, rich)
      if remaining_energy < 100 then
        check(not r.press_z and r.target_level == 0 and #f.releases == 0,
          "unfunded pending charge was not cancelled")
      else
        check(r.target_level == 1 and r.press_z, "reduced energy did not cap the target at C1")
        untilRelease(f, 1, 25, rich)
        check(#releases(f, 2) == 0, "reduced energy fabricated a C2")
      end
    end
  end

  -- A fresh already-observed charge level determines the release edge even
  -- if the available-energy snapshot fell meanwhile. Do not relabel a real
  -- C2 as C1, or count releasing >=100 charge as a below-C1 cancellation.
  f = fixture({ energy = 200 })
  tick(f, rich)
  f.world.player.currentCharge, f.world.player.currentChargeMax = 210, 180
  r = tick(f)
  check(not r.press_z and r.release_c2 == 1 and r.release_c1 == 0 and r.since_c2 == 0,
    "observed C2 charge was relabelled after an energy drop")
  f = fixture({ energy = 200 })
  tick(f, rich)
  f.world.player.currentCharge, f.world.player.currentChargeMax = 150, 90
  r = tick(f)
  check(not r.press_z and r.release_c1 == 1 and r.release_c2 == 0 and r.since_c2 == 2,
    "observed C1 charge was mistaken for a below-C1 cancellation")
end

-- Fail-closed main integration may clear command/observer state while
-- preserving cadence. Full reset still clears both clocks for a new match.
do
  local f = fixture()
  advance(f, 455)
  local age = f.state.since_c2
  bloom.reset(f.state, true)
  check(f.state.since_c == age and f.state.since_c2 == age,
    "fault reset discarded accumulated cadence")
  check(f.state.target_level == nil and f.state.cadence_charge == nil,
    "fault reset retained a charge command")
  f.world.player.currentCharge, f.remaining_warmup = 0, f.warmup
  untilRelease(f, 2, 35)
  bloom.reset(f.state)
  check(next(f.state) == nil, "new-match reset retained old cadence")
end

print("bloom_cadence_test: PASS (" .. checks .. " assertions; bounded charge/warmup fixture, no live-game claim)")
