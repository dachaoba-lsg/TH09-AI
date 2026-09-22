local config = dofile("config.lua")
local keys = dofile("keyutils.lua")
local dodge = dofile("dodge.lua")
local observer = dofile("bloom_observer.lua")
local bloom = dofile("bloom.lua")

local function loadRuntimeSettings()
  -- The launcher owns the user-facing settings in launcher-settings.json and
  -- generates this small file before launch. Standalone Lua use defaults to
  -- 600 seconds when the generated file is absent.
  local file = io.open("runtime-settings.lua", "r")
  if not file then
    return nil
  end
  file:close()
  local settings = assert(loadfile("runtime-settings.lua"))()
  assert(type(settings) == "table", "runtime-settings.lua: expected a table")
  local seconds = settings.seconds
  assert(type(seconds) == "number" and seconds >= 0 and seconds <= 86400
      and seconds == math.floor(seconds),
    "runtime-settings.lua: seconds must be an integer from 0 to 86400")
  return settings
end

-- 3.1 dodge difficulty. The launcher validates the JSON and emits plain values;
-- unknown keys and out-of-range numbers are ignored here too, because a bad
-- settings file must never break a battle. Presets live in config.lua.
local ATTENTION_NUMBERS = {
  threat_per_second = { 0.1, 64 }, tracked_threat = { 1, 64 }, plan_interval = { 1, 60 },
  reflex_radius = { 0, 256 }, urgent_frames = { 1, 600 }, blind_urgent_limit = { 1, 64 },
  sight_radius = { 0, 256 },
  overload_frames = { 1, 600 }, speed_reference = { 0.1, 20 }, speed_exponent = { 0.25, 2 },
  width_reference = { 16, 1024 },
}
local OVERLOAD_ACTIONS = { c = true, panic = true, c_then_panic = true, hold = true }

local function userNumber(value, low, high, integer)
  return type(value) == 'number' and value == value and value >= low and value <= high
    and (not integer or value == math.floor(value))
end

local function applyAttentionSettings(attention, ai)
  if type(ai) ~= "table" then return end
  local difficulty = type(ai.difficulty) == "string" and ai.difficulty or "human200"
  local aliases = config.dodge.attention_aliases or {}
  if aliases[difficulty] then difficulty = aliases[difficulty] end
  local custom = difficulty == "custom"
  local preset = config.dodge.attention_presets[difficulty]
    or config.dodge.attention_presets.human200
  for key, value in pairs(preset) do attention[key] = value end
  -- A named tier OWNS the simultaneous capacity and the acquisition rate.
  -- Numbers left over in launcher-settings.json by an older package must not
  -- silently pin every tier to the same budget (3.2.0/3.2.1 regression: all
  -- tiers ran as human200). Use difficulty "custom" to hand-tune those two.
  config.attention_difficulty = preset.enabled == false and "mech" or difficulty
  for name, range in pairs(ATTENTION_NUMBERS) do
    local value = ai[name]
    if type(value) == "number" and value == value and value ~= math.huge
        and value >= range[1] and value <= range[2]
        and (custom or (name ~= "tracked_threat" and name ~= "threat_per_second")) then
      attention[name] = value
    end
  end
  -- Deliberate player overrides are distinct from legacy budget fields
  -- left behind by old releases. They also work with named presets.
  if userNumber(ai.attention_capacity, 1, 256) then
    attention.tracked_threat = ai.attention_capacity
  end
  if userNumber(ai.attention_recovery_per_second, 0.1, 256) then
    attention.threat_per_second = ai.attention_recovery_per_second
  end
  if userNumber(ai.move_change_budget, 1, 10, true) then
    config.dodge.move_change_budget = ai.move_change_budget
  end
  if userNumber(ai.vision_radius, 16, 640) then
    config.dodge.vision_radius = ai.vision_radius
  end
  if OVERLOAD_ACTIONS[ai.overload_action] == true then attention.overload_action = ai.overload_action end
  if type(ai.enabled) == "boolean" then attention.enabled = ai.enabled end
  if type(ai.debug_log) == "boolean" then config.debug_log = ai.debug_log end
end

local runtime_settings = loadRuntimeSettings()
if runtime_settings then applyAttentionSettings(config.dodge.attention, runtime_settings.ai) end

-- Count battle callbacks at TH09's fixed 60 simulation frames/second.
-- Rendering speed does not change this configured simulation-frame budget.
local max_operation_frames = (runtime_settings and runtime_settings.seconds or 600) * 60

local state = {
  frame = 0, timed_out = false, last_move_key = nil,
  sensor_fault_reported = false, charge_mode_fault_reported = false,
  bloom = {}, observer = {}, round_id = 0, round_frame = 0, round_hits = 0,
}

local columns = {
  "frame", "x", "y", "life", "spell_point", "combo", "current_charge", "max_charge",
  "target_level", "bloom_phase", "timed_out", "move", "move_cost", "warning_lasers",
  "bullets", "enemies", "ex_attacks", "dodge_ms", "objects_relevant", "trajectory_tests",
  "laser_count", "tracked_lasers", "dynamic_lasers", "laser_sweep_tests", "laser_history_resets",
  "sensor_valid", "move_scale_x", "move_scale_y", "protection_frames", "can_charge",
  "charge_block_frames", "poison_clouds", "movement_segments", "player_state",
  "bloom_reason", "fairies", "spirits", "activated_spirits", "erasable_bullets",
  "chain_score", "chain_enemies", "chain_bullets", "future_score", "focus_requested",
  "focus_actual", "focus_used", "release_c1_requests", "release_c2_requests",
  "last_cycle_ready", "last_cycle_gain", "refill_pressure", "observe_ms", "bloom_ms", "chain_spirits",
  "c2_has_ignition", "c2_chain_score", "c2_chain_enemies", "c2_chain_bullets",
  "c2_direct_bullets", "c2_contested_bullets", "c2_future_score", "c2_future_bullets",
  "since_c_frames", "since_c2_frames", "cadence_charge",
  "bloom_min_y", "intent_x", "intent_y", "c2_position_valid", "c2_position_x", "c2_position_y",
  "c2_position_net_bullets", "c2_position_direct_bullets", "c2_position_contested_bullets",
  "c2_position_improvement", "height_limited", "height_recovering", "height_rejected", "c2_net_fraction",
  "prepare_locked", "prepare_age", "armed_age", "chain_leaving_bullets", "chain_arriving_bullets",
  "chain_exit_frames", "c2_leaving_bullets", "c2_arriving_bullets", "c2_exit_frames",
  "capture_preferred", "capture_value", "capture_chain_bullets", "c1_model_valid", "c1_model_limited",
  "c1_chain_bullets", "c1_hit_count", "common_waves_valid", "common_wave_count", "can_press_z",
  "c1_action_active", "followup_confirmed", "followup_z_requests", "followup_protection",
  "protected_route_checked", "protected_route_collides",
  "bloom_mode", "bloom_enters", "bloom_exit_reason", "opp_sensor_valid",
  "opp_charge_current", "opp_charge_max", "battle_seconds", "field_bullet_speed",
  "move_changes", "move_cap_forced", "move_cap_risk",
  "attention_tracked", "attention_blind_urgent", "attention_overloaded", "attention_escape",
  "attention_load", "attention_seen_cost", "attention_skipped", "attention_blind_cost",
  "attention_nearest_blind", "attention_nearest_cost", "attention_nearest_speed",
  "attention_budget", "attention_credit", "attention_entries", "attention_reach",
  "attention_free", "objects_seen", "hit", "hits_total",
  "round_id", "round_frame", "round_hits", "round_start", "battle_timer_units", "field_erasable",
  "bloom_enter_threshold", "bloom_exit_threshold", "bloom_late_active", "bloom_speed_active",
  "bloom_opponent_adjusted", "c2_reserve_active", "c2_reserve_age", "c2_reserve_reason", "c2_ready_updates",
  "vision_radius", "vision_visible_bullets", "vision_hidden_bullets",
  "vision_visible_enemies", "vision_hidden_enemies", "vision_visible_ex", "vision_hidden_ex",
  "vision_visible_poison", "vision_hidden_poison", "move_change_budget",
  "attention_capacity_config", "attention_recovery_config", "attention_enabled",
}
-- The game host runs Lua with a stripped standard environment (print is nil in
-- ka_ai_duka), so every optional global is probed before use: an unavailable
-- logger or clock must never take the whole script down.
local function log(message)
  if type(print) == "function" then print(message) end
end
local clock = (type(os) == "table" and type(os.clock) == "function") and os.clock or nil
local function now()
  if not clock then return 0 end
  local value = clock()
  return type(value) == "number" and value or 0
end
-- One file per Lua session, named after the difficulty tier. The game can keep
-- this Lua state across rounds; round_id separates them inside the CSV. Without a
-- clock in the host, existing files are numbered instead of overwritten.
local function debugFileName(tier)
  if type(os) == "table" and type(os.date) == "function" then
    local stamp = os.date("%Y%m%d-%H%M%S")
    if type(stamp) == "string" and stamp ~= "" then
      return "ai_debug_" .. tier .. "_" .. stamp .. ".csv"
    end
  end
  for index = 1, 999 do
    local candidate = "ai_debug_" .. tier .. "-" .. tostring(index) .. ".csv"
    local existing = io.open(candidate, "r")
    if not existing then return candidate end
    existing:close()
  end
  return "ai_debug_" .. tier .. "-overflow.csv"
end
local debug_file, debug_name = nil, nil
if config.debug_log then
  local tier = config.attention_difficulty or "custom"
  debug_name = debugFileName(tier)
  debug_file = io.open(debug_name, "w")
  if debug_file then
    debug_file:write(table.concat(columns, ",") .. "\n")
    log("TH09-AI: debug csv -> ai/" .. debug_name)
  end
end

local function writeDebug(side, player, movement, plan, obs, observe_ms, bloom_ms)
  if not debug_file then return end
  local event = plan.phase == 'release' or plan.reason == 'chain_lost_cancel'
    or plan.phase ~= state.last_debug_phase or state.hit == true or state.round_start == true
    or state.bloom.c2_reserve_active ~= state.last_debug_reserve
    or state.bloom.c2_reserve_reason ~= state.last_debug_reserve_reason
  state.last_debug_phase = plan.phase
  state.last_debug_reserve, state.last_debug_reserve_reason = state.bloom.c2_reserve_active,
    state.bloom.c2_reserve_reason
  if state.frame % config.debug_log_interval_frames ~= 0 and not event then return end
  local sensor, counts = player.sensor, obs.counts or {}
  local vision = state.vision or {}
  local c2 = obs.c2 or {}
  local chain_timing, c2_timing = obs.timing or {}, c2.timing or {}
  local position, intent = obs.c2_position or {}, plan.intent or {}
  local capture, c1 = obs.capture or {}, obs.c1 or {}
  local total = (c2.chain_bullets or 0) + (c2.direct_bullets or 0) + (c2.contested_bullets or 0)
  local values = {
    state.frame, player.x, player.y, player.life, player.spellPoint, player.combo,
    player.currentCharge, player.currentChargeMax, plan.target_level, plan.phase, state.timed_out,
    movement.name, movement.cost, movement.warning_lasers, #side.bullets, #side.enemies, #side.exAttacks,
    movement.dodge_ms or 0, movement.objects_relevant, movement.trajectory_tests, movement.laser_count,
    movement.tracked_lasers, movement.dynamic_lasers, movement.laser_sweep_tests, movement.laser_history_resets,
    sensor.valid and 1 or 0, sensor.moveScaleX, sensor.moveScaleY, movement.protection_frames,
    sensor.canCharge, sensor.chargeBlockFrames, movement.poison_clouds, movement.movement_segments, sensor.state,
    plan.reason, counts.fairies or 0, counts.spirits or 0, counts.activated or 0, counts.erasable or 0,
    obs.chain_score or 0, obs.chain_enemies or 0, obs.chain_bullets or 0, obs.future_score or 0,
    plan.focus, movement.focus == true, state.bloom.focus_used or 0, plan.release_c1, plan.release_c2,
    plan.cycle_ready, plan.cycle_gain, plan.refill_pressure, observe_ms or 0, bloom_ms or 0, obs.chain_spirits or 0,
    c2.has_ignition == true, c2.chain_score or 0, c2.chain_enemies or 0, c2.chain_bullets or 0,
    c2.direct_bullets or 0, c2.contested_bullets or 0, c2.future_score or 0, c2.future_bullets or 0,
    plan.since_c, plan.since_c2, plan.cadence_charge,
    intent.min_y or 0, intent.target_x or player.x, intent.target_y or player.y,
    position.has_ignition == true, position.target_x or player.x, position.target_y or player.y,
    position.chain_bullets or 0, position.direct_bullets or 0, position.contested_bullets or 0,
    position.improvement or 0, movement.height_limited == true, movement.height_recovering == true,
    movement.height_rejected or 0, total > 0 and (c2.chain_bullets or 0) / total or 0,
    plan.prepare_locked, plan.prepare_age, plan.armed_age,
    chain_timing.leaving_bullets or 0, chain_timing.arriving_bullets or 0,
    chain_timing.earliest_exit_frames or -1, c2_timing.leaving_bullets or 0,
    c2_timing.arriving_bullets or 0, c2_timing.earliest_exit_frames or -1,
    capture.preferred == true, capture.value or 0, capture.chain_bullets or 0,
    c1.valid == true, c1.model_limited == true, c1.chain_bullets or 0, c1.hit_count or 0,
    sensor.commonWavesValid == true, type(sensor.commonWaves) == 'table' and #sensor.commonWaves or 0,
    sensor.canPressZ == true, sensor.c1ActionActive == true, plan.followup_confirmed,
    plan.followup_z_requests, plan.followup_protection, movement.protected_route_checked == true,
    movement.protected_route_collides == true,
    state.bloom.bloom_mode == true, state.bloom.bloom_enters or 0,
    state.bloom.bloom_exit_reason or "", sensor.opponent and sensor.opponent.valid == true,
    sensor.opponent and sensor.opponent.chargeCurrent or 0,
    sensor.opponent and sensor.opponent.chargeMax or 0,
    (state.bloom.battle_time or 0) / 60, counts.field_erasable_speed or 0,
    movement.move_changes or 0, movement.move_cap_forced == true,
    movement.move_cap_risk == true,
    movement.attention_tracked or 0, movement.attention_blind_urgent or 0,
    movement.attention_overloaded == true, state.bloom.attention_escape == true,
    movement.attention_load or 0, movement.attention_seen_cost or 0, movement.attention_skipped or 0,
    movement.attention_blind_cost or 0, movement.attention_nearest_blind or -1,
    movement.attention_nearest_cost or 0, movement.attention_nearest_speed or 0,
    movement.attention_budget or 0, movement.attention_credit or 0,
    movement.attention_entries or 0, movement.attention_reach or 0,
    movement.attention_free or 0, movement.objects_seen or 0,
    state.hit == true, state.hits_total or 0,
    state.round_id, state.round_frame, state.round_hits, state.round_start == true,
    state.bloom.battle_time or 0, counts.field_erasable or 0,
    state.bloom.bloom_enter_threshold or 0, state.bloom.bloom_exit_threshold or 0,
    state.bloom.bloom_late_active == true, state.bloom.bloom_speed_active == true,
    state.bloom.bloom_opponent_adjusted == true, state.bloom.c2_reserve_active == true,
    state.bloom.c2_reserve_age or 0, state.bloom.c2_reserve_reason or "",
    state.bloom.c2_ready_updates or -1,
    vision.radius or config.dodge.vision_radius or 0,
    vision.visible_bullets or 0, vision.hidden_bullets or 0,
    vision.visible_enemies or 0, vision.hidden_enemies or 0,
    vision.visible_ex or 0, vision.hidden_ex or 0,
    vision.visible_poison or 0, vision.hidden_poison or 0,
    config.dodge.move_change_budget, config.dodge.attention.tracked_threat,
    config.dodge.attention.threat_per_second, config.dodge.attention.enabled ~= false,
  }
  for index = 1, #columns do values[index] = tostring(values[index] == nil and "" or values[index]) end
  debug_file:write(table.concat(values, ",") .. "\n")
  debug_file:flush()
end

local function validSensor(sensor)
  if type(sensor) ~= "table" or sensor.apiVersion ~= 1 or sensor.valid ~= true
      or type(sensor.canCharge) ~= "boolean" or type(sensor.poisonClouds) ~= "table"
      or #sensor.poisonClouds > 256 or type(sensor.state) ~= "number" then return false end
  for _, name in ipairs({"baseScaleX", "baseScaleY", "moveScaleX", "moveScaleY",
      "protectionFrames", "chargeBlockFrames"}) do
    local value = sensor[name]
    if type(value) ~= "number" or value ~= value or value < 0 or value == math.huge then return false end
  end
  -- Cadence uses these game-time fields when supplied. Older explicit test
  -- snapshots may omit them; malformed values must not silently alter timing.
  for _, name in ipairs({'chargeWarmupFrames', 'timeScale'}) do
    local value = sensor[name]
    local upper = name == 'timeScale' and 1 or 3600
    if value ~= nil and (type(value) ~= 'number' or value ~= value or value < 0 or value > upper) then return false end
  end
  if sensor.followupApiVersion ~= nil then
    if sensor.followupApiVersion ~= 1 or type(sensor.canPressZ) ~= 'boolean'
        or type(sensor.c1ActionActive) ~= 'boolean' then return false end
  end
  -- 3.0 read-only opponent gauge. A missing sub-table is an older native build
  -- and stays acceptable; a present but malformed one is a deployment fault,
  -- because strategy must never read a corrupted gauge as an energy level.
  if sensor.opponentApiVersion ~= nil then
    if sensor.opponentApiVersion ~= 1 or type(sensor.opponent) ~= 'table' then return false end
    local opponent = sensor.opponent
    if type(opponent.valid) ~= 'boolean' then return false end
    for _, name in ipairs({'chargeCurrent', 'chargeMax', 'chargeSpeed', 'state',
        'protectionFrames', 'life', 'spellPoint', 'combo'}) do
      local value = opponent[name]
      if type(value) ~= 'number' or value ~= value or value < 0 or value == math.huge then
        return false
      end
    end
    if opponent.chargeCurrent > 400.001 or opponent.chargeMax > 400.001
        or opponent.chargeSpeed >= 100 then return false end
  end
  return true
end

local function validCharge(player)
  for _, name in ipairs({'currentCharge', 'currentChargeMax', 'chargeSpeed'}) do
    local v = player[name]
    if type(v) ~= 'number' or v ~= v or v < 0 or v == math.huge then return false end
  end
  -- A whole-level jump could bypass C2 between callbacks. Supported original
  -- character features stay below this boundary; refuse anomalous snapshots.
  return player.currentCharge <= 400.001 and player.currentChargeMax <= 400.001
    and player.chargeSpeed > 0 and player.chargeSpeed < 100
end

local function observeRound(sensor)
  -- Only trusted, advancing snapshots can establish an initialization edge.
  -- In particular, neither healing nor a frozen/invalid snapshot proves that
  -- a new round started. Remember the last advancing state through such gaps.
  if sensor.cutIn == true or sensor.timeScale == 0 then return end
  local first = state.round_id == 0
  local initializing = sensor.state == 5 and state.round_sensor_state ~= 5
  if first or initializing then
    -- A round boundary invalidates every planner cache, including IDs that
    -- the game may reuse. Preserve only session counters and the total input
    -- deadline: a new round must not grant another configured N seconds.
    state = {
      frame = state.frame, timed_out = state.timed_out, hits_total = state.hits_total or 0,
      sensor_fault_reported = state.sensor_fault_reported,
      charge_mode_fault_reported = state.charge_mode_fault_reported,
      round_id = state.round_id + 1, round_frame = 1, round_hits = 0, round_start = true,
      bloom = {}, observer = {},
    }
  end
  state.round_sensor_state = sensor.state
end

local function resetBloomPlanning()
  -- Deployment/snapshot faults cancel actions but are not round boundaries.
  -- Keep the valid game time accumulated so far and do not count the gap.
  local battle_time = state.bloom.battle_time
  bloom.reset(state.bloom, true)
  state.bloom.battle_time = battle_time
end

function main()
  state.frame = state.frame + 1
  state.round_start = false
  if state.round_id > 0 then state.round_frame = state.round_frame + 1 end

  if max_operation_frames > 0 and state.frame > max_operation_frames then
    state.timed_out = true
  end

  -- sendKeys(0) is repeated on every remaining frame. Only a fresh Lua session
  -- restarts the total deadline; transitions between rounds never extend it.
  if state.timed_out then
    keys.send(0, false)
    return
  end

  local game_side = game_sides[player_side]
  local player = game_side.player
  -- The alternative Charge mode swaps the meaning of held Z and Shift.
  -- Never apply Slow-mode movement/charging predictions to that layout.
  if ChargeType and ChargeType.Charge ~= nil and game_side.chargeType == ChargeType.Charge then
    keys.send(0, false)
    state.laser_history, state.last_move_key = nil, nil
    resetBloomPlanning()
    state.observer = {}
    if not state.charge_mode_fault_reported then
      log("TH09-AI: unsupported 2P Charge Type. Select Slow (hold Z to charge, Shift for slow movement) in the game options; AI input released.")
      state.charge_mode_fault_reported = true
    end
    return
  end
  state.charge_mode_fault_reported = false
  -- Native and Lua changes must be deployed together. Do not silently run
  -- the old, poison-blind policy if the read-only sensor cannot be verified.
  if not validSensor(player.sensor) or not validCharge(player) then
    keys.send(0, false)
    state.laser_history, state.last_move_key = nil, nil
    state.attention_set, state.attention_tokens, state.attention_config = nil, nil, nil
    resetBloomPlanning()
    state.observer = {}
    if not state.sensor_fault_reported then
      log("TH09-AI: player sensor unavailable/invalid; AI input released. Use the complete matching package and inspect runtime/native-window.log.")
      state.sensor_fault_reported = true
    end
    return
  end
  state.sensor_fault_reported = false
  observeRound(player.sensor)
  -- A hit is the calibration event: log the frame and the attention state that
  -- surrounded it. life is the only exported health signal we trust here.
  state.hit = state.last_life ~= nil and player.life < state.last_life
  if state.hit then
    state.hits_total = (state.hits_total or 0) + 1
    state.round_hits = state.round_hits + 1
  end
  state.last_life = player.life
  local started = debug_file and now()
  -- Both policies see the same current circle. Raw counts are for CSV only;
  -- hidden objects cannot seed chains, affect pressure or plan an escape.
  local visible_side
  visible_side, state.vision = dodge.perceive(game_side, config.dodge)
  state.observer.lock_ids = (state.bloom.target_level or (state.bloom.shot_remaining or 0) > 0)
    and state.bloom.attack_ids or state.bloom.prepare_ids
  local observer_cfg = {}
  for k, v in pairs(config.bloom.observer) do observer_cfg[k] = v end
  observer_cfg.release_min_y = config.bloom.min_y
  -- Approximate remaining charge horizon, capped to a short linear forecast.
  -- The snapshot time scale is not a complete time-stop/low-FPS model.
  local remaining = math.max(0, (state.bloom.target_level or 2) * 100 - player.currentCharge)
  local warmup = player.sensor.chargeWarmupFrames or 10
  local eta = remaining / player.chargeSpeed + warmup
  observer_cfg.prediction_frames = math.max(12, math.min(60, eta))
  local obs = observer.observe(visible_side, state.observer, observer_cfg)
  local observe_ms = started and (now() - started) * 1000 or 0
  started = debug_file and now()
  local plan = bloom.update(visible_side, state.bloom, config.bloom, obs)
  local bloom_ms = started and (now() - started) * 1000 or 0
  started = debug_file and now()
  local movement = dodge.choose(visible_side, state, config.dodge, plan.intent)
  if started then movement.dodge_ms = (now() - started) * 1000 end
  bloom.feedback(state.bloom, movement, config.bloom)
  keys.send(movement.key, plan.press_z)
  writeDebug(game_side, player, movement, plan, obs, observe_ms, bloom_ms)
end
