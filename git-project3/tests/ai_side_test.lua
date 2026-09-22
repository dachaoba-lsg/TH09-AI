-- 3.4 integration: the host-selected player_side owns observation, policy,
-- movement, diagnostics and fail-closed gates. Both real fields coexist and
-- deliberately disagree. No game process, key mapping or disk writes are used.
HitType = { Rect = 0, Circle = 1, RotatableRect = 2 }
ExAttackType = { Medicine = 16 }
ChargeType = { Slow = 0, Charge = 1 }
local real_dofile, real_open, real_loadfile, real_print = dofile, io.open, loadfile, print
local checks = 0
local function check(value, message)
  checks = checks + 1
  assert(value, message)
end
local function eq(actual, expected, message)
  check(actual == expected, message .. ': ' .. tostring(actual) .. ' ~= ' .. tostring(expected))
end
local function bit(mask, value) return math.floor(mask / value) % 2 == 1 end
local function split(line)
  local fields = {}
  for value in (line:gsub('[\r\n]', '') .. ','):gmatch('(.-),') do fields[#fields + 1] = value end
  return fields
end
local function player(x, y, energy)
  return { x = x, y = y, character = 0, life = 10, spellPoint = 12345, combo = 3,
    currentCharge = 0, currentChargeMax = energy, chargeSpeed = 10, speedFast = 4, speedSlow = 2,
    hitBodyRect = { type = HitType.Rect, x = x, y = y, width = 4, height = 4 },
    hitBodyCircle = { type = HitType.Circle, x = x, y = y, radius = 2 },
    sensor = { apiVersion = 1, valid = true, state = 5, protectionFrames = 0, canCharge = true,
      chargeBlockFrames = 0, chargeWarmupFrames = 0, timeScale = 1, cutIn = false,
      baseScaleX = 1, baseScaleY = 1, moveScaleX = 1, moveScaleY = 1, poisonClouds = {},
      opponentApiVersion = 1, opponent = { valid = true, chargeCurrent = 70, chargeMax = 120,
        chargeSpeed = 10, state = 0, protectionFrames = 0, life = 6, spellPoint = 76543, combo = 8 } } }
end
local function side(p)
  return { player = p, chargeType = ChargeType.Slow, bullets = {}, enemies = {}, exAttacks = {}, items = {} }
end
local function fixture(selected, seconds)
  local f = { output = {}, sent = {}, logs = {}, calls = 0 }
  local cfg = real_dofile('config.lua')
  cfg.debug_log, cfg.debug_log_interval_frames = true, 1
  f.own = side(player(0, 320, 400))
  f.other = side(player(120, 180, 17))
  f.other.player.life, f.other.player.spellPoint, f.other.player.combo = 2, 900000, 99
  f.other.player.sensor.opponent.chargeCurrent, f.other.player.sensor.opponent.chargeMax = 290, 399
  f.other.player.sensor.state, f.other.chargeType = 0, ChargeType.Charge
  for index = 1, 4 do
    f.own.enemies[index] = { id = index, enabled = true, x = (index % 2) * 12 - 6,
      y = 190 + (index - 1) * 30, vx = 0, vy = 0, isSpirit = false, isActivatedSpirit = false,
      isBoss = false, isLily = false, isPseudoEnemy = false,
      hitBody = { type = HitType.Circle, x = (index % 2) * 12 - 6, y = 190 + (index - 1) * 30, radius = 4 } }
  end
  for index = 1, 20 do
    local x, y = (index % 5) * 10 - 20, 190 + math.floor(index / 5) * 5
    f.own.bullets[index] = { id = 100 + index, enabled = true, hittable = true, isErasable = true,
      x = x, y = y, vx = 0, vy = 0, hitBody = { type = HitType.Circle, x = x, y = y, radius = 2 } }
  end
  -- A warning laser requires real movement; the other field has no threats.
  f.own.bullets[21] = { id = 121, enabled = true, hittable = true, isErasable = false,
    x = 0, y = 320, vx = 0, vy = 0,
    hitBody = { type = HitType.RotatableRect, x = 0, y = 320, width = 420, height = 0, angle = math.pi / 2 } }
  dofile = function(path)
    if path == 'config.lua' then return cfg end
    local module = real_dofile(path)
    if path == 'dodge.lua' then
      local perceive, choose = module.perceive, module.choose
      module.perceive = function(current, settings)
        eq(current, f.own, 'perception must receive the selected host side')
        local visible, diagnostics = perceive(current, settings)
        f.visible = visible
        return visible, diagnostics
      end
      module.choose = function(current, state, settings, intent)
        eq(current, f.visible, 'dodge must use selected-side perception')
        f.calls, f.state = f.calls + 1, state
        return choose(current, state, settings, intent)
      end
    elseif path == 'bloom_observer.lua' then
      local observe = module.observe
      module.observe = function(current, state, settings)
        eq(current, f.visible, 'observer must use selected-side perception')
        return observe(current, state, settings)
      end
    elseif path == 'bloom.lua' then
      local update = module.update
      module.update = function(current, state, settings, observation)
        eq(current, f.visible, 'C policy must use selected-side perception')
        return update(current, state, settings, observation)
      end
    end
    return module
  end
  io.open = function(path, mode)
    if path == 'runtime-settings.lua' then return { close = function() end } end
    if mode == 'r' then return nil end
    check(mode == 'w' and path:match('^ai_debug_.+%.csv$'), 'unexpected I/O')
    return { write = function(_, value) f.output[#f.output + 1] = value end,
      flush = function() end, close = function() end }
  end
  loadfile = function(path)
    if path == 'runtime-settings.lua' then return function() return { seconds = seconds or 0 } end end
    return real_loadfile(path)
  end
  print = function(message) f.logs[#f.logs + 1] = message end
  player_side, game_sides = selected, { [selected] = f.own, [3 - selected] = f.other }
  sendKeys = function(mask)
    check(not bit(mask, 2), 'AI must never send X on either side')
    f.sent[#f.sent + 1] = mask
  end
  real_dofile('main.lua')
  local header = split(f.output[1])
  eq(#header, 169, '3.5 appends C1 diagnostics after the 162 original columns')
  function f.step()
    local rows = #f.output
    main()
    if #f.output == rows then return nil end
    local values, result = split(f.output[#f.output]), {}
    eq(#values, 169, 'CSV row width')
    for index, name in ipairs(header) do result[name] = values[index] end
    return result
  end
  return f
end
local traces = {}
for selected = 1, 2 do
  local f = fixture(selected)
  local row = f.step()
  eq(row.x, '0', 'own position must reach diagnostics')
  eq(row.y, '320', 'own field coordinates must not be offset or mirrored')
  eq(row.life, '10', 'own life must reach diagnostics')
  eq(row.spell_point, '12345', 'own score must reach diagnostics')
  eq(row.max_charge, '400', 'own gauge must reach diagnostics')
  eq(row.opp_charge_current, '70', 'opponent gauge must use selected sensor sub-snapshot')
  eq(row.opp_charge_max, '120', 'opponent gauge must not use the other sensor backwards')
  eq(row.bullets, '21', 'only own bullets belong to this policy')
  eq(row.enemies, '4', 'only own targets belong to this policy')
  check(f.sent[1] ~= 0, 'selected Slow side must act even when other side uses Charge')
  check(bit(f.sent[1], 16) or bit(f.sent[1], 32) or bit(f.sent[1], 64) or bit(f.sent[1], 128),
    'the real selected-side warning laser must produce a movement action')
  local trace, any_z = {}, false
  for frame = 1, 32 do
    f.own.player.sensor.state = 0
    row = f.step()
    local mask = f.sent[#f.sent]
    trace[#trace + 1] = mask
    any_z = any_z or bit(mask, 1)
    f.own.player.currentCharge = bit(mask, 1) and math.min(200, f.own.player.currentCharge + 10) or 0
  end
  check(any_z, 'real selected-side resources must produce shooting or charge')
  traces[selected] = trace
  -- Unselected health and round edges must not become AI hits/rounds.
  f.other.player.life, f.other.player.sensor.state = 0, 5
  row = f.step()
  eq(row.round_id, '1', 'other-side initialization must not reset own round')
  eq(row.hits_total, '0', 'other-side damage must not count as own damage')
  f.own.player.life = 6
  row = f.step()
  eq(row.hits_total, '1', 'selected-side damage must count')
  eq(row.round_hits, '1', 'selected-side round hit must count')
  local previous_state = f.state
  f.own.player.sensor.state, f.own.player.life = 5, 10
  row = f.step()
  eq(row.round_id, '2', 'selected initialization edge starts next round')
  eq(row.round_hits, '0', 'selected round resets round hits')
  eq(row.hits_total, '1', 'session hits persist across rounds')
  check(f.state ~= previous_state, 'selected new round replaces planning state')
  -- Only the AI-selected Charge layout causes fail-closed release.
  f.own.chargeType, f.other.chargeType = ChargeType.Charge, ChargeType.Slow
  local before = f.calls
  eq(f.step(), nil, 'unsupported selected charge type must not run policy')
  eq(f.calls, before, 'charge fault cannot enter dodge')
  eq(f.sent[#f.sent], 0, 'charge fault releases all selected AI keys')
  check(f.logs[#f.logs]:find('unsupported ' .. selected .. 'P Charge Type', 1, true),
    'charge fault message identifies actual AI side')
  f.own.chargeType = ChargeType.Slow
  check(f.step() ~= nil, 'selected Slow layout recovers')
  f.other.player.sensor.valid = false
  check(f.step() ~= nil, 'unselected sensor validity must not gate the AI')
  f.own.player.sensor.valid = false
  eq(f.step(), nil, 'invalid own sensor stops selected AI')
  eq(f.sent[#f.sent], 0, 'own sensor fault releases all selected keys')
  f.own.player.sensor.valid = true
  check(f.step() ~= nil, 'selected sensor recovery resumes policy')
  -- Across rounds, 60 callbacks means the same operation budget on both sides.
  f = fixture(selected, 1)
  for frame = 1, 60 do
    f.own.player.sensor.state = (frame == 1 or frame == 30) and 5 or 0
    row = f.step()
  end
  eq(row.frame, '60', 'one-second limit must allow 60 callbacks')
  eq(row.round_id, '2', 'a second round is observed before timeout')
  eq(f.calls, 60, 'both sides must receive the full configured callback budget')
  local output_count = #f.output
  for _ = 1, 5 do
    f.own.player.sensor.state = 5
    eq(f.step(), nil, 'timeout must not emit another planning sample')
    eq(f.sent[#f.sent], 0, 'timeout keeps selected AI keys released')
  end
  eq(f.calls, 60, 'new rounds must not revive timed-out AI')
  eq(#f.output, output_count, 'timeout must not advance CSV planning rows')
end
for index, mask in ipairs(traces[1]) do
  eq(traces[2][index], mask, 'identical selected scene must produce identical actions after side swap')
end
dofile, io.open, loadfile, print = real_dofile, real_open, real_loadfile, real_print
print(string.format('ai_side_test: PASS (%d checks, real policy/geometry on both host sides)', checks))
