local config = dofile("config.lua")
local keys = dofile("keyutils.lua")
local dodge = dofile("dodge.lua")
local observer = dofile("bloom_observer.lua")
local bloom = dofile("bloom.lua")

local function loadOperationSeconds()
  -- The launcher owns the user-facing duration in launcher-settings.json and
  -- generates this small file before launch. Standalone Lua use defaults to
  -- 600 seconds when the generated file is absent.
  local file = io.open("runtime-settings.lua", "r")
  if not file then
    return 600
  end
  file:close()
  local settings = assert(loadfile("runtime-settings.lua"))()
  local seconds = type(settings) == "table" and settings.seconds
  assert(type(seconds) == "number" and seconds >= 0 and seconds <= 86400
      and seconds == math.floor(seconds),
    "runtime-settings.lua: seconds must be an integer from 0 to 86400")
  return seconds
end

-- Count battle callbacks at TH09's fixed 60 simulation frames/second.
-- Rendering speed does not change this configured simulation-frame budget.
local max_operation_frames = loadOperationSeconds() * 60

local state = {
  frame = 0, timed_out = false, last_move_key = nil,
  sensor_fault_reported = false, charge_mode_fault_reported = false,
  bloom = {}, observer = {},
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
  "protected_route_checked", "protected_route_collides", "post_c2_phase", "post_c2_age",
  "post_c2_target_y", "cadence_limit", "bloom_cadence",
}
local debug_file = nil
if config.debug_log then
  debug_file = io.open("ai_debug.csv", "w")
  if debug_file then debug_file:write(table.concat(columns, ",") .. "\n") end
end

local function writeDebug(side, player, movement, plan, obs, observe_ms, bloom_ms)
  if not debug_file then return end
  local event = plan.phase == 'release' or plan.reason == 'chain_lost_cancel'
    or plan.phase ~= state.last_debug_phase
  state.last_debug_phase = plan.phase
  if state.frame % config.debug_log_interval_frames ~= 0 and not event then return end
  local sensor, counts = player.sensor, obs.counts or {}
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
    movement.protected_route_collides == true, plan.post_c2_phase, plan.post_c2_age,
    plan.post_c2_target_y, plan.cadence_limit, plan.bloom_cadence,
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

function main()
  state.frame = state.frame + 1

  if max_operation_frames > 0 and state.frame > max_operation_frames then
    state.timed_out = true
  end

  -- sendKeys(0) is repeated on every remaining frame. Lua is reloaded at the
  -- next battle, which resets the timer and all state automatically.
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
    bloom.reset(state.bloom, true)
    state.observer = {}
    if not state.charge_mode_fault_reported then
      print("TH09-AI: unsupported 2P Charge Type. Select Slow (hold Z to charge, Shift for slow movement) in the game options; AI input released.")
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
    bloom.reset(state.bloom, true)
    state.observer = {}
    if not state.sensor_fault_reported then
      print("TH09-AI: player sensor unavailable/invalid; AI input released. Use the complete matching 2.0.5 package and inspect runtime/native-window.log.")
      state.sensor_fault_reported = true
    end
    return
  end
  state.sensor_fault_reported = false
  local started = debug_file and os.clock()
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
  local obs = observer.observe(game_side, state.observer, observer_cfg)
  local observe_ms = started and (os.clock() - started) * 1000 or 0
  started = debug_file and os.clock()
  local plan = bloom.update(game_side, state.bloom, config.bloom, obs)
  local bloom_ms = started and (os.clock() - started) * 1000 or 0
  started = debug_file and os.clock()
  local movement = dodge.choose(game_side, state, config.dodge, plan.intent)
  if started then movement.dodge_ms = (os.clock() - started) * 1000 end
  bloom.feedback(state.bloom, movement, config.bloom)
  keys.send(movement.key, plan.press_z)
  writeDebug(game_side, player, movement, plan, obs, observe_ms, bloom_ms)
end
