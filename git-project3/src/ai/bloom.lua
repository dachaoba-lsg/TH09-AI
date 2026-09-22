-- Deterministic bloom policy. All geometry/score thresholds below are planning
-- heuristics, NOT verified blast radii or a formula for guaranteed energy.
-- This module never receives dodge danger as an attack trigger.
local M = {}
local abs, max, min = math.abs, math.max, math.min

M.defaults = {
  c1_score = 3, c1_enemies = 2,
  c2_score = 4.5, c2_enemies = 3, c2_bullets = 8,
  c2_future_ratio = 0.65, c2_future_enemies = 2, c2_future_bullets = 4,
  c2_min_net_fraction = 0.35,
  shot_score = 2.2, shot_enemies = 2,
  future_wait_ratio = 1.35, future_wait_gain = 1,
  focus_value = 0.7, focus_min_frames = 8, focus_max_frames = 32,
  fast_min_frames = 72, focus_budget_frames = 40, focus_budget_window = 180,
  focus_alignment = 42, focus_reach = 180,
  shot_burst_frames = 8, shot_settle_frames = 18,
  release_settle_frames = 12, recharge_observe_frames = 150,
  max_c_interval_frames = 480, cadence_margin_frames = 2,
  c2_reserve_margin = 10, c2_reserve_max_frames = 18, c2_reserve_samples = 3,
  position_weight = 0.002, focus_mismatch_cost = 8,
  min_y = 150, idle_y = 320, c2_position_lead_frames = 90,
  prepare_max_frames = 90, armed_max_frames = 24,
  bloom_enter_bullets = 160, bloom_exit_bullets = 110,
  bloom_c2_interval_frames = 260, bloom_energy_floor = 100,
  bloom_exit_cycles = 2, bloom_min_net_fraction = 0.15,
  bloom_c2_enemies = 2, bloom_c2_bullets = 4, bloom_c2_score = 2.5,
  bloom_opponent_margin = 100, bloom_opponent_lead_bullets = 40,
  -- Entry timing. The game rank rises over a match but is not readable and is
  -- not the same for every player, so the field itself is the signal: after
  -- bloom_late_seconds of battle time the field is dense enough that blooming
  -- is worth it, and a self-calibrated mean-bullet-speed ratio acts as a rank
  -- proxy earlier than that. Both only lower the entry/exit thresholds.
  bloom_late_seconds = 180, bloom_late_bullets = 60, bloom_late_exit_bullets = 40,
  bloom_speed_ratio = 1.35, bloom_speed_bullets = 90, bloom_speed_exit_bullets = 60,
  -- Movement-cap coupling: when the dodge planner reports that the human-like
  -- direction-change cap overrode a better escape, a charge attack is the
  -- answer (clear the wave) instead of pretending to out-micro it. The counter
  -- decays while the cap is not binding.
  move_cap_escape_frames = 4, move_cap_pressure_max = 30, move_cap_decay = 1,
  move_cap_escape_interval = 120,
  -- Attention-overload pressure (dodge.attention) uses the same escape path:
  -- consecutive overloaded callbacks before the policy answers with a charge.
  attention_escape_frames = 6, attention_pressure_max = 30, attention_pressure_decay = 1,
  capture_approach_frames = 60, followup_confirm_frames = 8,
  protected_focus_fast_min_frames = 24,
  c1_return_advantage = 1.25,
}

local function finite(v) return type(v) == 'number' and v == v and abs(v) < math.huge end
local function setting(cfg, key)
  local v = cfg and cfg[key]
  if not finite(v) or v < 0 then return M.defaults[key] end
  return v
end
local function number(v, fallback) return finite(v) and v or (fallback or 0) end

local function endReserve(state, reason)
  if state.c2_reserve_active then state.c2_reserve_reason = reason end
  state.c2_reserve_active = nil
end

local function clearRefillEvidence(state)
  state.reserve_stock, state.reserve_elapsed = nil, nil
  state.reserve_samples, state.reserve_rate = nil, nil
end

-- Observe only stock that actually arrived while THIS C1 remained held.
-- Its unreleased shot cannot be credited with future energy. A positive
-- sequence is a short scheduling hint, never a guaranteed refill.
local function observeHeldRefill(state, p, obs, elapsed)
  local sensor = p.sensor or {}
  local eligible = obs.valid and elapsed > 0 and state.target_level == 1
    and state.fresh_charge and state.press_z == true
    and sensor.canCharge ~= false and sensor.c1ActionActive ~= true
  if not eligible then
    clearRefillEvidence(state)
    if not obs.valid then endReserve(state, 'invalid_observer')
    elseif sensor.canCharge == false or sensor.c1ActionActive == true then
      endReserve(state, 'charge_gate')
    elseif state.target_level ~= 1 or not state.fresh_charge then
      endReserve(state, 'charge_changed')
    end
    return
  end
  local energy = number(p.currentChargeMax)
  local gain = state.reserve_stock and energy - state.reserve_stock or 0
  if gain > 0.000001 and number(state.reserve_elapsed) > 0 then
    local rate = gain / state.reserve_elapsed
    state.reserve_samples = (state.reserve_samples or 0) + 1
    state.reserve_rate = state.reserve_rate and min(state.reserve_rate, rate) or rate
  else
    state.reserve_samples, state.reserve_rate = 0, nil
  end
  state.reserve_stock, state.reserve_elapsed = energy, elapsed
end

-- Unknown/blocked/unfunded is -1. This estimates charging only after real
-- stock reaches 200, including the native warm-up; it promises no invulnerability.
local function updateC2Ready(state, p, sensor, elapsed)
  state.c2_ready_updates = -1
  if elapsed <= 0 or sensor.canCharge == false or sensor.c1ActionActive == true
      or number(p.currentChargeMax) < 200 or number(p.chargeSpeed) <= 0 then return end
  local charged = state.target_level and state.fresh_charge and number(p.currentCharge) or 0
  -- Warm-up and charging occupy separate updates; do not borrow the unused
  -- fraction of the final warm-up update to understate the charge delay.
  state.c2_ready_updates = math.ceil(max(0, number(sensor.chargeWarmupFrames, 11)) / elapsed)
    + math.ceil(max(0, 200 - charged) / (p.chargeSpeed * elapsed))
end

local function clearPreparation(state)
  state.prepare_ids, state.prepare_age, state.prepare_focus_frames = nil, nil, nil
  state.prepare_activated, state.prepare_capturing = nil, nil
  state.prepare_approaching = nil
end

local function chainIds(source)
  local ids = {}
  for _, id in ipairs(source.chain_ids or {}) do ids[id] = true end
  local seed = source.seed_id or source.ignition_id
  if next(ids) == nil and seed ~= nil then ids[seed] = true end
  return ids
end

local function timing(source)
  local t = type(source) == 'table' and source.timing
  return type(t) == 'table' and t.valid == true and t or nil
end

local function urgent(source)
  local t = timing(source)
  return t and t.urgency == true
end

local function improves(source)
  local t = timing(source)
  return t and t.improving == true and not t.urgency
end

-- This is a scheduling estimate, not an exact shot/blast travel model.
local function missesWindow(source, level, player, sensor)
  local t = timing(source)
  if not t or not t.urgency or not finite(t.earliest_exit_frames) then return false end
  local lead = max(0, level * 100 - number(player.currentCharge)) / max(0.01, number(player.chargeSpeed))
    + max(0, number(sensor.chargeWarmupFrames, 11))
  if level == 2 then lead = lead + max(0, number(source.seed_contact_updates)) end
  return lead >= t.earliest_exit_frames
end

function M.reset(state, keep_cadence)
  local since_c, since_c2 = state.since_c, state.since_c2
  for k in pairs(state) do state[k] = nil end
  if keep_cadence then state.since_c, state.since_c2 = since_c, since_c2 end
end

-- Count ACTUAL Shift output, including focus required by the dodge planner.
-- This prevents a new capture window immediately after defensive slow motion.
function M.feedback(state, movement, cfg)
  -- Movement-cap pressure is feedback from the dodge planner, so it is tracked
  -- even while paused; only the resource planning below is pause-gated.
  if movement.move_cap_forced then
    state.move_cap_pressure = min(setting(cfg, 'move_cap_pressure_max'),
      (state.move_cap_pressure or 0) + 1)
  else
    state.move_cap_pressure = max(0, (state.move_cap_pressure or 0)
      - setting(cfg, 'move_cap_decay'))
  end
  -- 3.1 attention overload: the dodge planner could not see everything that is
  -- about to hit it, which is the human moment to clear the screen with a
  -- charge attack instead of pretending to read it.
  if movement.attention_escape then
    state.attention_pressure = min(setting(cfg, 'attention_pressure_max'),
      (state.attention_pressure or 0) + 1)
  else
    state.attention_pressure = max(0, (state.attention_pressure or 0)
      - setting(cfg, 'attention_pressure_decay'))
  end
  if state.paused then return end
  local focus = movement.focus
  if focus == nil then focus = math.floor((movement.key or 0) / 4) % 2 == 1 end
  local window = max(1, math.floor(setting(cfg, 'focus_budget_window')))
  state.focus_history = state.focus_history or {}
  state.focus_index = (state.focus_index or 0) % window + 1
  state.focus_used = (state.focus_used or 0) - (state.focus_history[state.focus_index] or 0)
  state.focus_history[state.focus_index] = focus and 1 or 0
  state.focus_used = state.focus_used + state.focus_history[state.focus_index]
  state.fast_frames = focus and 0 or ((state.fast_frames or 0) + 1)
  if state.prepare_capturing and focus then
    state.prepare_focus_frames = (state.prepare_focus_frames or 0) + 1
  end
end

local function updateRecovery(state, player, cfg)
  local energy = number(player.currentChargeMax)
  state.energy_gain = max(0, energy - (state.last_energy or energy))
  state.last_energy = energy
  local cycle = state.cycle
  if not cycle then return end
  cycle.age = cycle.age + 1
  cycle.minimum = min(cycle.minimum, energy)
  cycle.gain = cycle.gain + state.energy_gain
  if energy >= 200 and (cycle.minimum < 200 or cycle.age >= setting(cfg, 'release_settle_frames')) then
    cycle.ready = true
  end
  -- Feedback is measured over the whole post-release window, not attributed
  -- exclusively to C2. A missed refill raises the NEXT resource requirement;
  -- no role is switched to an emergency/non-bloom strategy.
  if cycle.age >= setting(cfg, 'recharge_observe_frames') or cycle.ready then
    state.last_cycle_ready = cycle.ready == true
    state.last_cycle_gain = cycle.gain
    if cycle.level == 2 then
      state.refill_pressure = cycle.ready and max(0, (state.refill_pressure or 0) - 0.1)
        or min(0.75, (state.refill_pressure or 0) + 0.15)
      -- Bloom exits when completed C2 cycles stop returning energy. Counting
      -- completed cycles (not frames) keeps the exit tied to real feedback.
      if state.bloom_mode then
        if cycle.ready then state.bloom_low_cycles = 0
        else state.bloom_low_cycles = (state.bloom_low_cycles or 0) + 1 end
      end
    end
    state.cycle = nil
  end
end

local function focusIntent(state, player, obs, cfg)
  local x, y = number(player.x), number(player.y)
  local capture = type(obs.capture) == 'table' and obs.capture or {}
  local c1 = type(obs.c1) == 'table' and obs.c1 or {}
  local c1_available = c1.valid and c1.has_ignition and
    ((c1.remaining_only and number(c1.chain_bullets) > 0) or
      (not c1.remaining_only and number(player.currentChargeMax) >= 100
        and (player.sensor or {}).canCharge ~= false
        and number(c1.chain_enemies) >= setting(cfg, 'c1_enemies')
        and number(c1.chain_score) >= setting(cfg, 'c1_score')
        and not missesWindow(c1, 1, player, player.sensor or {})))
  local selected_capture = capture.valid and capture.has_target and
    (capture.preferred or (capture.preferred_before_c1 and not c1_available)
      or state.prepare_approaching or state.prepare_capturing)
  local source = selected_capture and capture or obs
  local fx, fy = source.focus_x, source.focus_y
  local prefer_c1 = capture.valid and capture.has_target and not capture.preferred
    and c1_available and number(c1.value) >= number(capture.value)
    and not state.prepare_capturing and not state.prepare_approaching
  local potential = obs.valid and number(source.focus_value) >= setting(cfg, 'focus_value')
    and finite(fx) and finite(fy) and fy <= y + 20 and y - fy <= setting(cfg, 'focus_reach')
    and not prefer_c1
  local aligned = potential and abs(fx - x) <= setting(cfg, 'focus_alignment')
  local exhausted = (state.focus_used or 0) >= setting(cfg, 'focus_budget_frames')
  local fast_min = setting(cfg, 'fast_min_frames')
  if (state.followup_protection or 0) >= setting(cfg, 'focus_min_frames') + 4 then
    fast_min = min(fast_min, setting(cfg, 'protected_focus_fast_min_frames'))
  end
  if state.focus then
    state.focus_age = (state.focus_age or 0) + 1
    if state.focus_age >= setting(cfg, 'focus_max_frames') or exhausted
        or (state.focus_age >= setting(cfg, 'focus_min_frames') and not aligned) then
      state.focus, state.focus_age, state.fast_frames = false, 0, 0
    end
  elseif aligned and not state.target_level and not exhausted
      and (state.capture_retry or 0) == 0
      and (state.fast_frames or 0) >= fast_min then
    state.focus, state.focus_age = true, 0
  end
  local tx, ty = obs.target_x, obs.target_y
  -- Ordinary fire reaches upward: approaching a high target unnecessarily
  -- puts the later cancel circle into its white-bullet cloud. Stay at least
  -- as low as now; selective spirit capture is the only upward approach here.
  if finite(ty) then ty = max(y, ty) end
  local approach = potential and selected_capture and not aligned and not state.target_level
    and not exhausted and (state.capture_retry or 0) == 0
    and (state.fast_frames or 0) >= fast_min
    and not urgent(obs) and not urgent(capture)
  if potential and (state.focus or approach or not obs.has_target) then
    tx, ty = fx, min(400, max(180, fy + 80))
  end
  if not finite(ty) then ty = max(y, setting(cfg, 'idle_y')) end
  if not finite(tx) then tx = x end
  ty = max(setting(cfg, 'min_y'), ty)
  return { focus = state.focus == true, target_x = tx, target_y = ty,
    approach_capture = approach, capture_source = source, capture_potential = potential,
    prefer_c1 = prefer_c1,
    min_y = setting(cfg, 'min_y'),
    position_weight = setting(cfg, 'position_weight'),
    focus_mismatch_cost = setting(cfg, 'focus_mismatch_cost') }
end

local function result(state, intent, press, phase, reason)
  state.phase, state.reason, state.press_z = phase, reason, press
  return { press_z = press, phase = phase, reason = reason, intent = intent,
    target_level = state.target_level or 0, focus = intent.focus,
    focus_used = state.focus_used or 0, refill_pressure = state.refill_pressure or 0,
    release_c1 = state.release_c1 or 0, release_c2 = state.release_c2 or 0,
    cycle_ready = state.last_cycle_ready == true, cycle_gain = state.last_cycle_gain or 0,
    since_c = state.since_c or 0, since_c2 = state.since_c2 or 0,
    cadence_charge = state.cadence_charge == true,
    prepare_age = state.prepare_age or 0, armed_age = state.armed_age or 0,
    prepare_locked = state.prepare_ids ~= nil,
    followup_confirmed = state.followup ~= nil,
    followup_z_requests = state.followup_z_requests or 0,
    followup_protection = state.followup_protection or 0 }
end

-- Requests do not grant protection. Associate an actual charge reset and a
-- newly observed protection/wave with the preceding C2 release, then keep
-- using live state3 only. Other sources of invulnerability are not C2 events.
local function waveSnapshot(sensor)
  local waves = {}
  if sensor.commonWavesValid == true and type(sensor.commonWaves) == 'table' then
    for _, w in ipairs(sensor.commonWaves) do
      if w.slotId ~= nil then waves[w.slotId] = {life=w.life, radius=w.radius} end
    end
  end
  return waves
end

local function updateFollowup(state, p, sensor, cfg)
  state.followup_protection = 0
  local valid = sensor.valid == true and sensor.followupApiVersion == 1
    and type(sensor.canPressZ) == 'boolean'
  local protected = valid and sensor.state == 3 and finite(sensor.protectionFrames)
    and max(0, math.floor(sensor.protectionFrames) - 1) or 0
  local pending = state.followup_pending
  if pending then
    pending.age = pending.age + 1
    local new_wave = false
    if valid and sensor.commonWavesValid == true and type(sensor.commonWaves) == 'table' then
      for _, w in ipairs(sensor.commonWaves) do
        local old = pending.waves[w.slotId]
        if (w.type == 1 or w.type == 4) and w.enabled == true and w.listed == true and w.delay == 0
            and finite(w.x) and finite(w.y) and finite(w.life) and w.life > 0
            and abs(w.x-pending.x) <= 2 and abs(w.y-pending.y) <= 2
            and (not old or number(w.life) > number(old.life)
              or number(w.radius) < number(old.radius)) then new_wave = true end
      end
    end
    local new_action = sensor.c1ActionActive == true and (not pending.action_active
      or number(sensor.c1ActionAge) < pending.action_age)
    local new_protection = protected > 0 and new_action and (pending.state ~= 3
      or number(sensor.protectionFrames) > pending.protection)
    if valid and number(p.currentCharge) < 100 and protected > 0
        and (new_protection or new_wave) then
      state.followup = {age=0, requested=false}
      state.followup_pending = nil
    elseif pending.age >= setting(cfg, 'followup_confirm_frames') then
      state.followup_pending = nil
    end
  end
  if state.followup then
    state.followup.age = state.followup.age + 1
    if protected <= 0 or state.followup.age > 90 then state.followup = nil
    else state.followup_protection = protected end
  end
  state.release_snapshot = {x=number(p.x), y=number(p.y), state=sensor.state,
    protection=number(sensor.protectionFrames), waves=waveSnapshot(sensor),
    action_active=sensor.c1ActionActive == true, action_age=number(sensor.c1ActionAge)}
end

-- 3.0 bloom (energy) mode. Recorded PVP play keeps a C2 rhythm of one release
-- every ~3-5 s while the own field is dense, converting bullets into energy
-- instead of pure dodging. This module only changes WHEN the already-authorized
-- C1/C2 plan releases; it never fires on danger and never uses X. The opponent
-- gauge is a read-only native sub-snapshot: a missing/invalid opponent reading
-- changes nothing except the optional early-entry relaxation.
local function bloomPressure(obs)
  local counts = type(obs) == 'table' and obs.counts
  local field = type(counts) == 'table' and counts.field_erasable
  return finite(field) and max(0, field) or nil
end

local function opponentGauge(p)
  local sensor = type(p) == 'table' and p.sensor
  if type(sensor) ~= 'table' or sensor.opponentApiVersion ~= 1 then return nil end
  local opponent = sensor.opponent
  if type(opponent) ~= 'table' or opponent.valid ~= true then return nil end
  if not finite(opponent.chargeMax) then return nil end
  return opponent
end

local function gaugeClearlyAhead(p, cfg)
  local opponent = opponentGauge(p)
  if not opponent then return false end
  return number(p.currentChargeMax) >= number(opponent.chargeMax) + setting(cfg, 'bloom_opponent_margin')
end

-- Rank proxy from the own field only: the mean speed of whole-field erasable
-- bullets relative to the slowest smoothed value seen in this battle. The real
-- game rank is unreadable and player-specific, so this never reads it.
local function bulletSpeedRank(state, obs, cfg)
  local counts = type(obs) == 'table' and obs.counts
  local speed = type(counts) == 'table' and counts.field_erasable_speed
  if not finite(speed) or speed <= 0 then return false end
  local alpha = 0.2
  state.bullet_speed_ema = state.bullet_speed_ema
    and (state.bullet_speed_ema * (1 - alpha) + speed * alpha) or speed
  state.bullet_speed_ref = state.bullet_speed_ref
    and min(state.bullet_speed_ref, state.bullet_speed_ema) or state.bullet_speed_ema
  local ratio = setting(cfg, 'bloom_speed_ratio')
  return ratio > 0 and state.bullet_speed_ref > 0
    and state.bullet_speed_ema >= state.bullet_speed_ref * ratio
end

-- Effective entry/exit thresholds. Battle-time and rank-proxy rules only lower
-- them; they never raise the base requirement, and the observer must be valid.
local function bloomThresholds(state, obs, cfg)
  local enter = setting(cfg, 'bloom_enter_bullets')
  local leave = setting(cfg, 'bloom_exit_bullets')
  local late = setting(cfg, 'bloom_late_seconds')
  state.bloom_late_active = obs.valid and late > 0 and (state.battle_time or 0) >= late * 60
  state.bloom_speed_active = obs.valid and bulletSpeedRank(state, obs, cfg) or false
  if state.bloom_late_active then
    enter, leave = setting(cfg, 'bloom_late_bullets'), setting(cfg, 'bloom_late_exit_bullets')
  end
  if state.bloom_speed_active then
    enter = min(enter, setting(cfg, 'bloom_speed_bullets'))
    leave = min(leave, setting(cfg, 'bloom_speed_exit_bullets'))
  end
  return enter, leave
end

-- Pressure hysteresis decides only whether the fast C2 rhythm is active. Entry
-- additionally needs enough energy for a C2; exit keeps the loop alive until
-- the field calms down or completed C2 cycles stop returning energy.
local function updateBloomMode(state, player, obs, cfg)
  local pressure = bloomPressure(obs)
  local energy = number(player.currentChargeMax)
  local enter, leave = bloomThresholds(state, obs, cfg)
  state.bloom_opponent_adjusted = gaugeClearlyAhead(player, cfg)
  local threshold = state.bloom_opponent_adjusted
    and max(0, enter - setting(cfg, 'bloom_opponent_lead_bullets')) or enter
  state.bloom_enter_threshold, state.bloom_exit_threshold = threshold, leave
  if not state.bloom_mode then
    if obs.valid and pressure and pressure >= threshold and energy >= 200 then
      state.bloom_mode = true
      state.bloom_enters = (state.bloom_enters or 0) + 1
      state.bloom_exit_reason = nil
      state.bloom_low_cycles = 0
      return true
    end
    return false
  end
  state.bloom_age = (state.bloom_age or 0) + 1
  if not obs.valid then
    state.bloom_mode, state.bloom_exit_reason = nil, 'invalid_observer'
  elseif pressure and pressure < leave then
    state.bloom_mode, state.bloom_exit_reason = nil, 'pressure_dropped'
  elseif energy < setting(cfg, 'bloom_energy_floor')
      and (state.bloom_low_cycles or 0) >= setting(cfg, 'bloom_exit_cycles') then
    state.bloom_mode, state.bloom_exit_reason = nil, 'energy_not_recovering'
  end
  return state.bloom_mode == true
end

-- The interval is measured between RELEASE REQUESTS, never ordinary shots or
-- charge starts. C1 does not reset the independent C2 deadline. Account for
-- warm-up and remaining charge now so the eighth second is a release goal.
local function cadenceLevel(state, player, sensor, cfg, available_energy)
  local speed = number(player.chargeSpeed)
  if speed <= 0 then return nil end
  local limit = max(1, setting(cfg, 'max_c_interval_frames'))
  -- Bloom shortens the same deadline; it does not bypass the release rules.
  if state.bloom_mode then
    limit = min(limit, max(1, setting(cfg, 'bloom_c2_interval_frames')))
  end
  -- A wave that needs more direction changes than the human-like cap allows is
  -- answered with a charge attack, so the C2 deadline is shortened further
  -- while that pressure lasts.
  if state.cap_escape then
    limit = min(limit, max(1, setting(cfg, 'move_cap_escape_interval')))
  end
  -- Reset warm-up can report 11; do not clamp it to an assumed ten updates.
  local warmup = max(0, number(sensor.chargeWarmupFrames, 11))
  local function due(level, age)
    local charge_time = max(0, level * 100 - number(player.currentCharge)) / speed
    local lead = warmup + charge_time
    if level == 2 and state.target_level == 1 then
      -- Releasing this C1 resets charge AND warm-up. Reserve a complete new
      -- C2 cycle, or keep this held charge and promote it before that reset.
      lead = max(lead, 11 + 200 / speed)
    end
    return number(age) + lead + setting(cfg, 'cadence_margin_frames') >= limit
  end
  local energy = available_energy or number(player.currentChargeMax)
  if energy >= 200 and due(2, state.since_c2) then return 2 end
  if energy >= 100 and due(1, state.since_c) then return 1 end
end

local function c2Resources(state, obs, cfg)
  -- Direct C2 erasure gives NEITHER energy NOR opponent bullets. Only the
  -- separate enemy/spirit-chain estimate may fund this decision. Never fall
  -- back to ordinary-shot totals when the C2 estimate is absent.
  local c2 = obs.c2
  local net = type(c2) == 'table' and max(0, number(c2.chain_bullets)) or 0
  local swallowed = type(c2) == 'table' and (max(0, number(c2.direct_bullets))
    + max(0, number(c2.contested_bullets))) or 0
  if state.bloom_mode or state.cap_escape then
    -- Bloom (and a cap-blocked dodge) keeps the ignition requirement and the
    -- direct/contested deduction, but no longer waits for a rich or improving
    -- future chain: the dense field itself is the resource. Thresholds stay
    -- observable candidates.
    return obs.valid and type(c2) == 'table' and c2.has_ignition == true
      and net >= (net + swallowed) * min(1, setting(cfg, 'bloom_min_net_fraction'))
      and number(c2.chain_enemies) >= setting(cfg, 'bloom_c2_enemies')
      and number(c2.chain_bullets) >= setting(cfg, 'bloom_c2_bullets')
      and number(c2.chain_score) >= setting(cfg, 'bloom_c2_score')
  end
  return obs.valid and type(c2) == 'table' and c2.has_ignition == true
    and net >= (net + swallowed) * min(1, setting(cfg, 'c2_min_net_fraction'))
    and number(c2.chain_enemies) >= setting(cfg, 'c2_enemies')
    and number(c2.chain_bullets) >= setting(cfg, 'c2_bullets')
    and number(c2.chain_score) >= setting(cfg, 'c2_score') * (1 + (state.refill_pressure or 0))
    -- A good current overlap that is about to leave should not be rejected
    -- precisely because its future snapshot has fewer bullets. Direct erasure
    -- still contributes no budget and all CURRENT net gates still apply.
    and (urgent(c2) or (c2.future_has_ignition == true
    and number(c2.future_enemies) >= setting(cfg, 'c2_future_enemies')
    and number(c2.future_bullets) >= setting(cfg, 'c2_future_bullets')
    and number(c2.future_score) >= number(c2.chain_score) * setting(cfg, 'c2_future_ratio')))
end

local function c2Intent(intent, obs)
  -- C2 is an area ignition, including unactivated spirits. Ordinary-shot
  -- x alignment must not pull the player away from this selected area plan.
  if not obs.valid then return end
  local c2 = obs.c2_position
  if type(c2) ~= 'table' or not c2.has_ignition then c2 = obs.c2 end
  if type(c2) ~= 'table' or not c2.has_ignition then return end
  if finite(c2.target_x) then intent.target_x = c2.target_x end
  if finite(c2.target_y) then intent.target_y = max(intent.min_y, c2.target_y) end
end

local function beginCharge(state, intent, charged, level, source, cadence, original_ids, c1_profile)
  clearRefillEvidence(state)
  state.c2_reserve_active, state.c2_reserve_reason, state.c2_reserve_age = nil, nil, 0
  local prepared_ids = original_ids or state.prepare_ids
  state.target_level, state.fresh_charge = level, charged < 100
  state.c1_profile_charge = level == 1 and c1_profile == true
  state.cadence_charge = cadence == true
  state.shot_remaining, state.shot_pressed = nil, nil
  clearPreparation(state)
  state.armed_age, state.overlap_wait = nil, nil
  if cadence then
    -- The user-authorized deadline commits despite poor/disappearing resources;
    -- it must not pretend to be a profitable chain or inherit a resource lock.
    state.attack_ids, state.settle = nil, 0
    return result(state, intent, true, 'charge', 'cadence_c' .. level)
  end
  state.attack_ids = prepared_ids or chainIds(source)
  return result(state, intent, true, 'charge', level == 2 and 'chain_for_c2' or 'build_with_c1')
end

local function release(state, intent, energy, level, cfg, reason)
  endReserve(state, 'released')
  clearRefillEvidence(state)
  if not reason and state.cadence_charge then reason = 'cadence_release_c' .. level end
  state.target_level, state.fresh_charge, state.attack_ids = nil, nil, nil
  state.c1_profile_charge = nil
  clearPreparation(state)
  state.armed_age, state.overlap_wait = nil, nil
  state.cadence_charge, state.since_c = nil, 0
  if level == 2 then state.since_c2 = 0 end
  if level == 2 and state.release_snapshot then
    state.followup_pending = state.release_snapshot
    state.followup_pending.age = 0
    state.followup = nil
  end
  state.settle = max(1, setting(cfg, 'release_settle_frames'))
  state['release_c' .. level] = (state['release_c' .. level] or 0) + 1
  if not state.cycle or level == 2 or state.cycle.level ~= 2 then
    state.cycle = { level = level, age = 0, minimum = energy, gain = 0 }
  end
  return result(state, intent, false, 'release', reason or ('release_c' .. level))
end

local function reserveC2(state, p, obs, cfg, safe)
  local energy = number(p.currentChargeMax)
  local age = number(state.c2_reserve_age)
  local limit = setting(cfg, 'c2_reserve_max_frames')
  local needed = obs.valid and (cadenceLevel(state, p, p.sensor or {}, cfg, 200) == 2
    or c2Resources(state, obs, cfg))
  local reason
  if not obs.valid then reason = 'invalid_observer'
  elseif energy >= 200 then reason = 'funded'
  elseif energy < 200 - setting(cfg, 'c2_reserve_margin') then reason = 'stock_too_low'
  elseif not needed then reason = 'c2_not_needed'
  elseif not safe then reason = 'charge_ceiling'
  elseif age >= limit then reason = 'wait_limit'
  elseif (state.reserve_samples or 0) < max(1, setting(cfg, 'c2_reserve_samples'))
      or number(state.reserve_rate) <= 0 then reason = 'refill_unconfirmed'
  elseif (200 - energy) / state.reserve_rate > limit - age then reason = 'refill_too_slow'
  end
  if reason then
    local was_active = state.c2_reserve_active
    endReserve(state, reason)
    return false, was_active and reason or nil
  end
  state.c2_reserve_active, state.c2_reserve_reason = true, 'observed_refill'
  state.c2_reserve_age = age + number(state.update_elapsed, 1)
  return true
end

local function matureCharge(state, intent, p, obs, cfg, level)
  local source = level == 2 and obs.c2 or (state.c1_profile_charge and obs.c1 or obs)
  if level == 1 and source and source.remaining_only then source = nil end
  state.armed_age = (state.armed_age or 0) + 1
  -- Do not trust the current energy cap: a chain can raise it during the next
  -- game update. Budget a full update even when timeScale currently is lower.
  local ceiling = (level + 1) * 100
  local safe = number(p.currentCharge) + number(p.chargeSpeed) < ceiling
  if level == 1 then
    local hold, stopped = reserveC2(state, p, obs, cfg, safe)
    if hold then return result(state, intent, true, 'armed', 'wait_c2_refill') end
    -- A failed reservation must not silently turn into another shape wait.
    if stopped then
      return release(state, intent, number(p.currentChargeMax), 1, cfg, 'c2_reserve_' .. stopped)
    end
  end
  -- Bloom releases are prompt: the recorded PVP rhythm does not hold a mature
  -- charge for a better chain shape. The charge ceiling still ends the wait.
  local can_wait = not state.cadence_charge and not state.bloom_mode and not state.cap_escape
    and obs.valid and source and source.has_ignition
    and improves(source) and safe and state.armed_age < setting(cfg, 'armed_max_frames')
  if can_wait then
    return result(state, intent, true, 'armed', 'wait_shape_c' .. level)
  end
  local reason
  if not state.cadence_charge then
    if not safe then reason = 'charge_ceiling_c' .. level
    elseif urgent(source) then reason = 'intercept_c' .. level
    elseif state.armed_age >= setting(cfg, 'armed_max_frames') then reason = 'shape_wait_limit_c' .. level end
  end
  return release(state, intent, number(p.currentChargeMax), level, cfg, reason)
end

function M.update(game_side, state, cfg, obs)
  local p = game_side.player
  local sensor = p.sensor or {}
  obs = obs or { valid = false, counts = {} }
  -- Use game-time units, not wall clock. Cut-ins/time stops freeze the clock;
  -- hit recovery still consumes battle time but cannot issue an attack below.
  local elapsed = sensor.cutIn == true and 0 or max(0, min(1, number(sensor.timeScale, 1)))
  state.update_elapsed, state.c2_ready_updates = elapsed, -1
  state.since_c, state.since_c2 = (state.since_c or 0) + elapsed, (state.since_c2 or 0) + elapsed
  -- Battle time in game Timer units: cut-ins and time stops freeze it, so the
  -- 180-second bloom-entry rule is match time, not wall-clock time.
  state.battle_time = (state.battle_time or 0) + elapsed
  if state.last_life and number(p.life) < state.last_life then
    endReserve(state, 'hit')
    clearRefillEvidence(state)
    -- A hit interrupts our command plan. Do not replay a pre-hit release.
    state.target_level, state.shot_remaining, state.fresh_charge, state.attack_ids = nil, nil, nil, nil
    state.cadence_charge = nil
    clearPreparation(state)
    state.armed_age = nil
    state.settle = setting(cfg, 'release_settle_frames')
    state.focus, state.fast_frames = false, 0
    state.followup, state.followup_pending = nil, nil
  end
  state.last_life = number(p.life)
  local recovering = sensor.state ~= nil and sensor.state ~= 0 and sensor.state ~= 3
  if recovering then
    endReserve(state, 'recovery')
    clearRefillEvidence(state)
    -- Recovery must suppress pending input even when a no-damage setting or
    -- a missed HP transition leaves life unchanged in this snapshot.
    state.target_level, state.shot_remaining, state.fresh_charge, state.attack_ids = nil, nil, nil, nil
    state.cadence_charge, state.focus, state.fast_frames = nil, false, 0
    clearPreparation(state)
    state.armed_age = nil
    state.followup, state.followup_pending = nil, nil
  end
  state.paused = sensor.cutIn == true or sensor.timeScale == 0 or recovering
  if state.paused then
    endReserve(state, 'paused')
    clearRefillEvidence(state)
    return result(state, {focus = state.focus == true, min_y = setting(cfg, 'min_y')},
      state.target_level ~= nil and state.press_z == true, 'paused', 'action_pause')
  end
  state.frame = (state.frame or 0) + 1
  state.capture_retry = max(0, (state.capture_retry or 0) - 1)
  updateFollowup(state, p, sensor, cfg)
  updateRecovery(state, p, cfg)
  observeHeldRefill(state, p, obs, elapsed)
  updateC2Ready(state, p, sensor, elapsed)
  state.bloom_mode = updateBloomMode(state, p, obs, cfg) and true or nil
  -- Cap pressure from the previous dodge call turns the next decision toward a
  -- charge attack instead of more movement (see dodge.choose move_cap_forced).
  state.cap_escape = (state.move_cap_pressure or 0) >= setting(cfg, 'move_cap_escape_frames')
  state.attention_escape = (state.attention_pressure or 0) >= setting(cfg, 'attention_escape_frames')
  if state.attention_escape then state.cap_escape = true end
  local intent = focusIntent(state, p, obs, cfg)
  intent.protected_followup = state.followup ~= nil
  local charged, energy = number(p.currentCharge), number(p.currentChargeMax)
  local deadline_level = obs.valid and cadenceLevel(state, p, sensor, cfg) or nil
  -- Prepare lower release geometry before the deadline, without borrowing
  -- the suggested point's resources to justify an attack at the actual point.
  local position_due = number(state.since_c2) >= setting(cfg, 'max_c_interval_frames')
    - setting(cfg, 'c2_position_lead_frames')
  if energy >= 200 and (state.target_level == 2 or deadline_level == 2
      or (not state.target_level and not state.focus and not intent.approach_capture
        and (position_due or c2Resources(state, obs, cfg)
          or (not obs.has_ignition and not intent.capture_potential)))) then
    c2Intent(intent, obs)
  end

  if state.target_level then
    if state.c2_reserve_active and charged < 100 then
      endReserve(state, 'charge_reset')
      clearRefillEvidence(state)
    end
    if state.c2_reserve_active and energy >= 200 then
      if deadline_level == 2 or c2Resources(state, obs, cfg) then
        endReserve(state, 'promoted_c2')
        clearRefillEvidence(state)
        state.target_level, state.cadence_charge = 2, deadline_level == 2
        state.attack_ids = state.cadence_charge and nil or chainIds(obs.c2 or {})
      else
        endReserve(state, 'c2_not_needed')
        return release(state, intent, energy, charged >= 200 and 2 or 1, cfg, 'c2_reserve_c2_not_needed')
      end
    end
    -- Actual release level follows the already observed charge, not the
    -- possibly lower energy cap in the same snapshot. Do not label a full
    -- C2 release as C1 or cancel after an energy-cap change.
    if charged < 100 then state.fresh_charge = true end
    if deadline_level then
      -- A pending C1 cannot indefinitely postpone the independent C2 clock.
      if not state.cadence_charge or deadline_level == 2 then state.target_level = deadline_level end
      state.cadence_charge, state.attack_ids = true, nil
    end
    if sensor.canCharge ~= false and state.fresh_charge and charged >= 200 then
      state.target_level = 2
      return matureCharge(state, intent, p, obs, cfg, 2)
    end
    if energy < state.target_level * 100 then
      if energy >= 100 or charged >= 100 then state.target_level = 1
      else
        state.target_level, state.fresh_charge, state.attack_ids, state.cadence_charge = nil, nil, nil, nil
        return result(state, intent, false, 'grow', 'need_charge_energy')
      end
    end
    if state.target_level == 2 then c2Intent(intent, obs) end
    local target = state.target_level * 100
    if charged < 100 then state.fresh_charge = true end
    if sensor.canCharge ~= false and state.fresh_charge and charged >= target then
      local level = state.target_level
      return matureCharge(state, intent, p, obs, cfg, level)
    end
    -- A launch is a resource plan, not an irrevocable random target. If the
    -- same chain disappears BEFORE C2 matures, release below C1 to cancel or
    -- end at C1 rather than charging into an empty C2. Once 200 is already
    -- observed, a bounded shape wait may be possible inside its charge band.
    if state.target_level == 2 and not state.cadence_charge and not c2Resources(state, obs, cfg) then
      if charged >= 100 and state.fresh_charge and sensor.canCharge ~= false then
        return release(state, intent, energy, 1, cfg, 'chain_lost_end_c1')
      elseif charged < 100 then
        state.target_level, state.fresh_charge, state.attack_ids = nil, nil, nil
        state.settle = max(1, setting(cfg, 'shot_settle_frames'))
        return result(state, intent, false, 'grow', 'chain_lost_cancel')
      end
    end
    if sensor.canCharge == false then
      return result(state, intent, true, 'charge', 'charge_gate')
    end
    return result(state, intent, true, 'charge', 'committed_c' .. state.target_level)
  end
  local settling = (state.settle or 0) > 0
  if settling then state.settle = state.settle - 1 end

  -- A worthwhile capture can require FAST lateral travel before Shift has
  -- any effect. Preserve its original nodes rather than firing an inferior
  -- aligned fairy in place. A failed approach cannot hold fire indefinitely.
  local capture = intent.capture_source or obs
  if not deadline_level and intent.approach_capture then
    if not state.prepare_ids then
      state.prepare_ids, state.prepare_age = chainIds(capture), 0
      state.prepare_focus_frames, state.prepare_activated = 0, 0
      state.shot_remaining, state.shot_pressed = nil, nil
    end
    state.prepare_approaching = true
    state.prepare_age = (state.prepare_age or 0) + 1
    if state.prepare_age < setting(cfg, 'capture_approach_frames') then
      return result(state, intent, false, 'approach', 'approach_capture')
    end
    state.capture_retry = setting(cfg, 'fast_min_frames')
    clearPreparation(state)
    intent.approach_capture = false
  elseif state.prepare_approaching then
    state.prepare_approaching = nil
    if state.focus then state.prepare_capturing = true
    elseif not capture.valid or not capture.has_target then clearPreparation(state) end
  end

  local intercept = urgent(obs) or urgent(obs.c2) or urgent(capture)
  local prepared_ids = state.prepare_ids
  if not deadline_level then
    -- Capture first, then preserve the same resource chain while it develops.
    -- Legacy/minimal snapshots without timing retain the old immediate policy.
    if not state.prepare_ids and state.focus and (timing(capture) or timing(obs)) and not intercept then
      local source = {chain_ids = capture.focus_chain_ids or capture.chain_ids or obs.focus_chain_ids or obs.chain_ids}
      local ids = chainIds(source)
      if next(ids) then
        state.prepare_ids, state.prepare_age, state.prepare_focus_frames = ids, 0, 0
        state.prepare_capturing, state.prepare_activated = true, 0
        state.shot_remaining, state.shot_pressed = nil, nil
      end
    end
    if state.prepare_ids then
      -- A previous overlap wait is allowed to become capture preparation.
      -- The old lock blocked Shift precisely when alignment became possible.
      if state.focus then state.prepare_capturing = true end
      state.prepare_age = (state.prepare_age or 0) + 1
      state.prepare_activated = (state.prepare_activated or 0)
        + number(capture.chain_activated_gain, number(obs.chain_activated_gain))
      local expired = state.prepare_age >= setting(cfg, 'prepare_max_frames')
      local lost = not obs.valid or (not obs.has_ignition and not (obs.c2 and obs.c2.has_ignition)
        and not timing(obs) and not (capture.valid and capture.has_target) and not timing(capture))
      if intercept or expired or lost then
        state.focus, intent.focus = false, false
        state.fast_frames = 0
        if expired then state.overlap_wait = setting(cfg, 'prepare_max_frames') end
        clearPreparation(state)
      else
        if state.prepare_capturing and ((state.prepare_focus_frames or 0) >= setting(cfg, 'focus_min_frames')
            and state.prepare_activated > 0 or not state.focus) then
          state.prepare_capturing, state.focus, intent.focus = false, false, false
        end
        if state.prepare_capturing then
          return result(state, intent, false, 'prepare', 'capture_chain')
        end
      if improves(obs) and not intent.prefer_c1 and not (energy >= 200 and c2Resources(state, obs, cfg)) then
          return result(state, intent, false, 'prepare', 'wait_chain_overlap')
        end
      end
    elseif intercept then
      state.focus, intent.focus = false, false
    end

  end

  local c1 = type(obs.c1) == 'table' and obs.c1 or {}
  local c1_ready = obs.valid and c1.valid and c1.has_ignition and not c1.remaining_only and energy >= 100
    and number(c1.chain_enemies) >= setting(cfg, 'c1_enemies')
    and number(c1.chain_score) >= setting(cfg, 'c1_score')
    and not missesWindow(c1, 1, p, sensor)
  -- C2's release starts a role attack already. This is the user's follow-up
  -- Z edge, NOT a second confirmed C1 attack or a fresh 100-charge release.
  -- The separate input gate permits it while the C1 action blocks charging.
  local followup_useful = (c1.valid and c1.has_ignition and number(c1.chain_bullets) > 0)
    or (obs.has_ignition and obs.ignition_aligned and number(obs.chain_score) >= setting(cfg, 'shot_score'))
  if state.followup and not state.followup.requested and sensor.canPressZ == true
      and charged < 100 and not intent.focus and not state.prepare_capturing
      and not intent.approach_capture and followup_useful then
    state.followup.requested = true
    state.followup_z_requests = (state.followup_z_requests or 0) + 1
    if deadline_level or (energy >= 200 and c2Resources(state, obs, cfg)) or c1_ready then
      local level = deadline_level or (energy >= 200 and c2Resources(state, obs, cfg) and 2 or 1)
      local source = level == 2 and obs.c2 or c1
      local out = beginCharge(state, intent, charged, level, source, deadline_level ~= nil, nil, level == 1)
      out.reason, state.reason = 'post_c2_z_prewarm', 'post_c2_z_prewarm'
      return out
    end
    return result(state, intent, true, 'followup', 'post_c2_z_edge')
  end
  if sensor.canCharge == false then
    return result(state, intent, false, 'grow', 'action_blocked')
  end
  -- Release in the original engine resets charge_current (41FBFA). Wait for
  -- that fresh snapshot before starting another attack; an old full value is
  -- never accepted as a newly charged C2.
  if charged >= 100 then
    return result(state, intent, false, 'recover', 'await_charge_reset')
  end

  -- Cadence has priority over shot bursts, settle waits and resource gates,
  -- but never overrides engine action gates, missing energy or stale charge.
  if deadline_level then
    state.focus, intent.focus = false, false
    if deadline_level == 2 then c2Intent(intent, obs) end
    return beginCharge(state, intent, charged, deadline_level, obs, true)
  end
  if settling then
    return result(state, intent, false, 'recover', 'observe_chain')
  end

  if (state.shot_remaining or 0) > 0 then
    if not obs.valid or not obs.has_target or obs.has_ignition ~= true or not obs.ignition_aligned then
      state.shot_remaining = 0
      state.attack_ids = nil
      state.settle = max(1, setting(cfg, 'shot_settle_frames'))
      return result(state, intent, false, 'grow', 'shot_target_lost')
    end
    state.shot_remaining = state.shot_remaining - 1
    state.shot_pressed = not state.shot_pressed
    local pressed = state.shot_pressed
    if state.shot_remaining == 0 then state.settle = max(1, setting(cfg, 'shot_settle_frames')) end
    return result(state, intent, pressed, 'shot', 'ignite_chain')
  end
  -- C2 has its own reachable seeds and net chain resources. Test it BEFORE
  -- ordinary-shot eligibility/alignment, which excludes unactivated spirits.
  local c2_ready = energy >= 200 and c2Resources(state, obs, cfg)
  local c1_better = c1_ready and number(c1.chain_bullets) > number(obs.c2 and obs.c2.chain_bullets)
    * setting(cfg, 'c1_return_advantage')
  if c2_ready and not c1_better and not (obs.has_ignition and obs.ignition_aligned
      and missesWindow(obs.c2, 2, p, sensor)) then
    c2Intent(intent, obs)
    return beginCharge(state, intent, charged, 2, obs.c2, false, prepared_ids)
  end
  -- Character C1 coverage is independent of the normal-shot column. It may
  -- ignite an off-axis chain, or return more whites than a swallowing C2.
  if c1_ready then
    return beginCharge(state, intent, charged, 1, c1, false, prepared_ids, true)
  end
  if not obs.valid or not obs.has_target or obs.has_ignition ~= true then
    return result(state, intent, false, state.focus and 'focus' or 'grow', 'no_ignition_target')
  end
  local score, enemies = number(obs.chain_score), number(obs.chain_enemies)
  local future = number(obs.future_score, score)
  if not obs.ignition_aligned then
    return result(state, intent, false, state.focus and 'focus' or 'grow', 'align_ignition')
  end
  -- C2 was considered before this wait. For shots/C1, preserve a current
  -- overlap that is substantially better in the short future sample.
  local wait_for_overlap = timing(obs) and improves(obs) or (not timing(obs)
    and future >= score * setting(cfg, 'future_wait_ratio')
    and future - score >= setting(cfg, 'future_wait_gain'))
  state.overlap_wait = wait_for_overlap and not intercept and ((state.overlap_wait or 0) + 1) or 0
  if wait_for_overlap and not intercept and state.overlap_wait < setting(cfg, 'prepare_max_frames') then
    if not state.prepare_ids and timing(obs) then
      state.prepare_ids, state.prepare_age = chainIds(obs), state.overlap_wait
    end
    return result(state, intent, false, state.focus and 'focus' or 'grow', 'wait_for_overlap')
  end
  local legacy_c1 = (not c1.valid or c1.model_limited == true) and energy >= 100 and enemies >= setting(cfg, 'c1_enemies')
    and score >= setting(cfg, 'c1_score')
  if legacy_c1 and not missesWindow(obs, 1, p, sensor) then
    return beginCharge(state, intent, charged, 1, obs, false, prepared_ids)
  end
  if score >= setting(cfg, 'shot_score') and enemies >= setting(cfg, 'shot_enemies') then
    state.attack_ids = prepared_ids or state.prepare_ids or chainIds(obs)
    clearPreparation(state)
    state.overlap_wait = nil
    state.shot_remaining = max(1, math.floor(setting(cfg, 'shot_burst_frames'))) - 1
    state.shot_pressed = true
    if state.shot_remaining == 0 then state.settle = max(1, setting(cfg, 'shot_settle_frames')) end
    return result(state, intent, true, 'shot', 'ignite_chain')
  end
  return result(state, intent, false, state.focus and 'focus' or 'grow', 'preserve_resources')
end

return M
