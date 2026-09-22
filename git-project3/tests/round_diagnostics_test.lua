-- Main-loop integration: multiple rounds may share one Lua session.
-- All settings, key output and CSV writes stay in memory; no game is started.
HitType = { Rect = 0, Circle = 1, RotatableRect = 2 }
ExAttackType = { Medicine = 16 }
player_side = 2
local original_dofile, original_open, original_loadfile = dofile, io.open, loadfile
local original_charge_type = ChargeType
local checks = 0
local function check(value, message)
  checks = checks + 1
  assert(value, message)
end
local function split(line)
  local fields = {}
  for value in (line:gsub('\n', '') .. ','):gmatch('(.-),') do fields[#fields + 1] = value end
  return fields
end
local function fixture(seconds, interval, constant_phase)
  local cfg = original_dofile('config.lua')
  cfg.debug_log, cfg.debug_log_interval_frames = true, interval or 1
  local output, sent, entries = {}, {}, {}
  local p = { x = -160, y = 384, life = 10, spellPoint = 0, combo = 0,
    currentCharge = 0, currentChargeMax = 0, chargeSpeed = 10, speedFast = 4, speedSlow = 2,
    hitBodyRect = { type = HitType.Rect, width = 4, height = 4 }, hitBodyCircle = { radius = 2 },
    sensor = { apiVersion = 1, valid = true, state = 5, protectionFrames = 0, canCharge = true,
      chargeBlockFrames = 0, baseScaleX = 1, baseScaleY = 1, moveScaleX = 1, moveScaleY = 1,
      poisonClouds = {}, timeScale = 1, cutIn = false } }
  local side = { player = p, bullets = {}, enemies = {}, exAttacks = {} }
  dofile = function(path)
    if path == 'config.lua' then return cfg end
    local module = original_dofile(path)
    if path == 'dodge.lua' then
      local choose = module.choose
      module.choose = function(current, state, settings, intent)
        entries[#entries + 1] = { state = state, bloom = state.bloom, observer = state.observer,
          attention_set = state.attention_set, laser_history = state.laser_history,
          move_history = state.move_change_history, last_move_key = state.last_move_key }
        return choose(current, state, settings, intent)
      end
    elseif path == 'bloom.lua' and constant_phase then
      local update = module.update
      module.update = function(...)
        local plan = update(...)
        plan.phase = 'fixture_constant'
        return plan
      end
    end
    return module
  end
  io.open = function(path, mode)
    if path == 'runtime-settings.lua' then return { close = function() end } end
    if mode == 'r' then return nil end
    check(path:match('^ai_debug_.+%.csv$') ~= nil and mode == 'w', 'unexpected I/O')
    return { write = function(_, value) output[#output + 1] = value end,
      flush = function() end, close = function() end }
  end
  loadfile = function(path)
    if path == 'runtime-settings.lua' then return function() return { seconds = seconds or 0 } end end
    return original_loadfile(path)
  end
  sendKeys = function(mask) sent[#sent + 1] = mask end
  game_sides = { [2] = side }
  original_dofile('main.lua')
  local header, map = split(output[1]), {}
  for i, name in ipairs(header) do map[name] = i end
  local result = { player = p, side = side, output = output, sent = sent, entries = entries }
  function result.step()
    main()
    if #output == 1 then return nil end
    local values, row = split(output[#output]), {}
    check(#values == #header, 'CSV sample must match its header')
    for name, index in pairs(map) do row[name] = values[index] end
    return row
  end
  return result
end

local run = fixture(0)
local row = run.step()
check(row.round_id == '1' and row.round_frame == '1' and row.round_start == 'true',
  'the first initialization callback establishes round 1 exactly once')
for frame = 2, 3 do
  row = run.step()
  check(row.round_id == '1' and tonumber(row.round_frame) == frame and row.round_start == 'false',
    'multiple initialization callbacks cannot create duplicate rounds')
end
run.player.sensor.state = 0
run.step()
run.player.life = 6
row = run.step()
check(row.hit == 'true' and row.hits_total == '1' and row.round_hits == '1',
  'damage must increment both session and current-round counters')
run.player.life = 10
row = run.step()
check(row.round_id == '1' and row.round_start == 'false' and row.round_hits == '1',
  'healing at the spawn point on an empty field alone is not a new round')
run.player.life = 6
row = run.step()
check(row.hits_total == '2' and row.round_hits == '2', 'second hit missing')
local before = run.entries[#run.entries]
run.player.sensor.state, run.player.life = 5, 10
row = run.step()
local after = run.entries[#run.entries]
check(row.frame == '8' and row.round_id == '2' and row.round_frame == '1' and row.round_start == 'true',
  'a trusted initialization edge must start another round without resetting the session frame')
check(row.hit == 'false' and row.hits_total == '2' and row.round_hits == '0',
  'new round keeps session hits, clears round hits and discards the old health baseline')
check(after.state ~= before.state and after.bloom ~= before.bloom and after.observer ~= before.observer,
  'the new round must replace bloom and observer planning state')
check(after.attention_set == nil and after.laser_history == nil and after.move_history == nil
    and after.last_move_key == nil,
  'the new round must clear attention, laser and movement caches before dodge runs')
check(tonumber(row.battle_timer_units) == 1 and math.abs(tonumber(row.battle_seconds) - 1 / 60) < 1e-12,
  'the per-round game timer starts fresh and seconds use 60 timer units')
row = run.step()
check(row.round_id == '2' and row.round_frame == '2' and row.round_start == 'false',
  'a repeated state 5 must not reset a new round again')
run.player.sensor.state, run.player.life = 0, 6
row = run.step()
check(row.hits_total == '3' and row.round_hits == '1', 'hits must be attributed to the new round')
local timer_before_freeze = tonumber(row.battle_timer_units)
run.player.sensor.state, run.player.sensor.timeScale = 5, 0
row = run.step()
check(row.round_id == '2' and row.round_start == 'false'
    and tonumber(row.battle_timer_units) == timer_before_freeze,
  'timeScale 0 cannot establish a round edge or advance the game timer')
run.player.sensor.timeScale, run.player.sensor.cutIn = 1, true
row = run.step()
check(row.round_id == '2' and row.round_start == 'false'
    and tonumber(row.battle_timer_units) == timer_before_freeze,
  'cut-in snapshots cannot establish a round edge or advance the game timer')
run.player.sensor.cutIn, run.player.sensor.valid = false, false
local records = #run.output
run.step()
check(#run.output == records and run.sent[#run.sent] == 0 and after.state.round_id == 2,
  'invalid snapshots must release input without creating a round or a trusted CSV sample')
run.player.sensor.valid, run.player.life = true, 10
row = run.step()
check(row.round_id == '3' and row.round_start == 'true' and row.round_frame == '1'
    and row.hits_total == '3' and row.round_hits == '0',
  'initialization is confirmed once after the frozen/invalid gap becomes trustworthy')
run.player.sensor.valid = false
run.step()
run.player.sensor.valid = true
row = run.step()
check(row.round_id == '3' and row.round_start == 'false',
  'invalid snapshots in a held initialization state cannot manufacture another edge')
local last_timer = tonumber(row.battle_timer_units)
run.player.sensor.valid, run.player.sensor.state = false, 0
run.step()
run.player.sensor.valid, run.player.sensor.state = true, 5
row = run.step()
check(row.round_id == '3' and row.round_start == 'false',
  'an invalid apparent exit from state 5 cannot arm a new round')
check(tonumber(row.battle_timer_units) == last_timer + 1,
  'temporary sensor faults must preserve valid game-time accumulation within the same round')

local frozen = fixture(0)
frozen.player.sensor.timeScale = 0
row = frozen.step()
check(row.round_id == '0' and row.round_start == 'false',
  'a frozen initial snapshot must wait for a trusted advancing round observation')
frozen.player.sensor.timeScale = 1
row = frozen.step()
check(row.round_id == '1' and row.round_frame == '1' and row.round_start == 'true',
  'the first advancing callback establishes round 1 after initial freeze')

local charge_fault = fixture(0)
ChargeType = { Charge = 1, Slow = 0 }
charge_fault.player.sensor.state, charge_fault.side.chargeType = 0, ChargeType.Slow
row = charge_fault.step()
local charge_timer, charge_rows = tonumber(row.battle_timer_units), #charge_fault.output
charge_fault.side.chargeType = ChargeType.Charge
charge_fault.step()
check(#charge_fault.output == charge_rows and charge_fault.sent[#charge_fault.sent] == 0,
  'unsupported charge layout must release input without a trusted sample')
charge_fault.side.chargeType = ChargeType.Slow
row = charge_fault.step()
check(row.round_id == '1' and row.round_start == 'false'
    and tonumber(row.battle_timer_units) == charge_timer + 1,
  'recovering the input layout preserves valid round time without counting the fault gap')
ChargeType = original_charge_type

local sampled = fixture(0, 100, true)
sampled.player.sensor.state = 0
sampled.step()
sampled.step()
check(#sampled.output == 2, 'an unchanged phase below the sample interval should not log another row')
sampled.player.sensor.state = 5
row = sampled.step()
check(#sampled.output == 3 and row.round_start == 'true' and row.round_id == '2',
  'round_start must force a CSV sample even if the policy phase and sample interval do not')

local limited = fixture(1)
for frame = 1, 60 do
  limited.player.sensor.state = (frame == 1 or frame == 30) and 5 or 0
  row = limited.step()
end
check(row.frame == '60' and row.round_id == '2' and row.round_frame == '31'
    and row.timed_out == 'false', 'the second round must share the original 60-callback allowance')
local active_calls, logged = #limited.entries, #limited.output
limited.player.sensor.state = 5
for _ = 61, 65 do limited.step(); check(limited.sent[#limited.sent] == 0, 'timed-out input must stay released') end
check(#limited.entries == active_calls and #limited.output == logged,
  'new-round state after expiry cannot resume planners or extend the total operation duration')

io.open, dofile, loadfile = original_open, original_dofile, original_loadfile
ChargeType = original_charge_type
print(string.format('round_diagnostics_test: PASS (%d checks)', checks))
