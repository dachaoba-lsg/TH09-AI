local config = dofile("config.lua")
local keys = dofile("keyutils.lua")
local dodge = dofile("dodge.lua")

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
  frame = 0,
  timed_out = false,
  spell_locked = false,
  target_charge_level = nil,
  release_cooldown = 0,
  tap_shot_pressed = false,
  last_move_key = nil,
  sensor_fault_reported = false,
  charge_mode_fault_reported = false,
}

math.randomseed(os.time() + player_side * 1009)

local debug_file = nil
if config.debug_log then
  debug_file = io.open("ai_debug.csv", "w")
  if debug_file then
    debug_file:write("frame,x,y,life,spell_point,combo,current_charge,max_charge,target_level,spell_locked,timed_out,move,move_cost,warning_lasers,bullets,enemies,ex_attacks,dodge_ms,objects_relevant,trajectory_tests,laser_count,tracked_lasers,dynamic_lasers,laser_sweep_tests,laser_history_resets,sensor_valid,move_scale_x,move_scale_y,protection_frames,can_charge,charge_block_frames,poison_clouds,movement_segments,player_state\n")
  end
end

local function chooseChargeLevel()
  local total = 0
  for level = 1, 4 do
    total = total + math.max(0, config.charge_weights[level] or 0)
  end
  if total <= 0 then
    return 1
  end

  local pick = math.random() * total
  local accumulated = 0
  for level = 1, 4 do
    accumulated = accumulated + math.max(0, config.charge_weights[level] or 0)
    if pick < accumulated then
      return level
    end
  end
  return 4
end

local function updateSpellLock(player)
  local spell_point = player.spellPoint or 0
  if not state.spell_locked and spell_point >= config.spell_point_stop then
    state.spell_locked = true
    state.target_charge_level = nil
    state.release_cooldown = 0
    state.tap_shot_pressed = false
  elseif state.spell_locked and spell_point <= config.spell_point_resume then
    state.spell_locked = false
  end
end

local function nextTapShotKey()
  -- TH09 enters charge when Z is held. Alternating press/release produces
  -- normal shots without deliberately charging.
  state.tap_shot_pressed = not state.tap_shot_pressed
  return state.tap_shot_pressed
end

local function shouldPressZ(player)
  -- Never shoot while deliberately breaking Spell Point.
  if state.spell_locked then
    state.tap_shot_pressed = false
    return false
  end

  if state.release_cooldown > 0 then
    state.release_cooldown = state.release_cooldown - 1
    state.tap_shot_pressed = false
    return false
  end

  if state.target_charge_level == nil then
    state.target_charge_level = chooseChargeLevel()
  end

  local threshold = config.charge_thresholds[state.target_charge_level]
  local available = player.currentChargeMax or 0
  local charged = player.currentCharge or 0

  -- Keep the selected random charge level. While energy is insufficient,
  -- continue normal tap shooting, but do not hold Z long enough to charge and
  -- do not fall back to a lower charge attack.
  if available + 0.001 < threshold then
    return nextTapShotKey()
  end

  -- A previous attack can still block effective charging after protection
  -- expires. Pre-hold Z, but do not mistake an old charge value for a newly
  -- completed attack. The game itself decides when accumulation can resume.
  if player.sensor and player.sensor.valid and player.sensor.canCharge == false then
    state.tap_shot_pressed = false
    return true
  end

  if charged + 0.001 < threshold then
    state.tap_shot_pressed = false
    return true
  end

  -- Releasing Z for at least one frame fires the selected C1/C2/C3/C4.
  state.target_charge_level = nil
  state.release_cooldown = config.charge_release_cooldown_frames
  state.tap_shot_pressed = false
  return false
end

local function writeDebug(game_side, player, movement)
  if not debug_file then
    return
  end
  if state.frame % config.debug_log_interval_frames ~= 0 then
    return
  end
  local sensor = player.sensor or {}
  debug_file:write(string.format(
    "%d,%.3f,%.3f,%d,%d,%d,%.3f,%.3f,%s,%s,%s,%s,%.4f,%d,%d,%d,%d,%.3f,%d,%d,%d,%d,%d,%d,%d,%d,%.6f,%.6f,%.3f,%s,%.3f,%d,%d,%d\n",
    state.frame,
    player.x or 0,
    player.y or 0,
    player.life or 0,
    player.spellPoint or 0,
    player.combo or 0,
    player.currentCharge or 0,
    player.currentChargeMax or 0,
    tostring(state.target_charge_level or ""),
    tostring(state.spell_locked),
    tostring(state.timed_out),
    movement.name or "",
    movement.cost or 0,
    movement.warning_lasers or 0,
    #game_side.bullets,
    #game_side.enemies,
    #game_side.exAttacks,
    movement.dodge_ms or 0,
    movement.objects_relevant or 0,
    movement.trajectory_tests or 0,
    movement.laser_count or 0,
    movement.tracked_lasers or 0,
    movement.dynamic_lasers or 0,
    movement.laser_sweep_tests or 0,
    movement.laser_history_resets or 0,
    sensor.valid == true and 1 or 0,
    sensor.moveScaleX or 0,
    sensor.moveScaleY or 0,
    movement.protection_frames or 0,
    tostring(sensor.canCharge),
    sensor.chargeBlockFrames or 0,
    movement.poison_clouds or 0,
    movement.movement_segments or 0,
    sensor.state or -1
  ))
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
  return true
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
    if not state.charge_mode_fault_reported then
      print("TH09-AI: unsupported 2P Charge Type. Select Slow (hold Z to charge, Shift for slow movement) in the game options; AI input released.")
      state.charge_mode_fault_reported = true
    end
    return
  end
  state.charge_mode_fault_reported = false
  -- Native and Lua changes must be deployed together. Do not silently run
  -- the old, poison-blind policy if the read-only sensor cannot be verified.
  if not validSensor(player.sensor) then
    keys.send(0, false)
    state.laser_history, state.last_move_key = nil, nil
    if not state.sensor_fault_reported then
      print("TH09-AI: player sensor unavailable/invalid; AI input released. Use the complete matching 0.1.9 package and inspect runtime/native-window.log.")
      state.sensor_fault_reported = true
    end
    return
  end
  state.sensor_fault_reported = false
  local started = debug_file and os.clock()
  local movement = dodge.choose(game_side, state, config.dodge)
  if started then
    movement.dodge_ms = (os.clock() - started) * 1000
  end

  updateSpellLock(player)
  local press_z = shouldPressZ(player)
  keys.send(movement.key, press_z)
  writeDebug(game_side, player, movement)
end
