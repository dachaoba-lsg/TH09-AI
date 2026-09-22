-- Lightweight Lua runtime tests. Run with the working directory set to src/ai.

HitType = { Rect = 0, Circle = 1, RotatableRect = 2 }
ItemType = {}
ExAttackType = {}
CharacterType = {}
ChargeType = { Slow = 0, Charge = 1 }
player_side = 2
round = 0
difficulty = 1

local sent = {}
function sendKeys(mask)
  table.insert(sent, mask)
end

local function rectHalf(body, field)
  return math.abs(body[field] or 0) * 0.5
end

local function rectVsRect(a, b)
  return math.abs((a.x or 0) - (b.x or 0)) <= rectHalf(a, "width") + rectHalf(b, "width")
    and math.abs((a.y or 0) - (b.y or 0)) <= rectHalf(a, "height") + rectHalf(b, "height")
end

local function rectVsCircle(rect, circle)
  local nearest_x = math.max((rect.x or 0) - rectHalf(rect, "width"), math.min(circle.x or 0, (rect.x or 0) + rectHalf(rect, "width")))
  local nearest_y = math.max((rect.y or 0) - rectHalf(rect, "height"), math.min(circle.y or 0, (rect.y or 0) + rectHalf(rect, "height")))
  local dx = (circle.x or 0) - nearest_x
  local dy = (circle.y or 0) - nearest_y
  return dx * dx + dy * dy <= (circle.radius or 0) ^ 2
end

local function rectVsRotatedRect(rect, rotated)
  local dx = (rect.x or 0) - (rotated.x or 0)
  local dy = (rect.y or 0) - (rotated.y or 0)
  local angle = rotated.angle or 0
  local c = math.cos(angle)
  local s = math.sin(angle)
  local local_x = c * dx + s * dy
  local local_y = -s * dx + c * dy
  return local_x >= -rectHalf(rect, "width")
    and local_x <= (rotated.width or 0) + rectHalf(rect, "width")
    and math.abs(local_y) <= rectHalf(rotated, "height") + rectHalf(rect, "height")
end

function hitTest(a, b)
  if b.type == HitType.RotatableRect then
    return rectVsRotatedRect(a, b)
  end
  if a.type == HitType.RotatableRect then
    return rectVsRotatedRect(b, a)
  end
  if a.type == HitType.Circle and b.type == HitType.Circle then
    local dx = (a.x or 0) - (b.x or 0)
    local dy = (a.y or 0) - (b.y or 0)
    return dx * dx + dy * dy <= ((a.radius or 0) + (b.radius or 0)) ^ 2
  end
  if a.type == HitType.Circle or b.type == HitType.Circle then return false end
  return rectVsRect(a, b)
end

function saveSnapshot()
end

local function newPlayer()
  return {
    x = 0,
    y = 320,
    life = 5,
    spellPoint = 0,
    combo = 0,
    currentCharge = 0,
    currentChargeMax = 0,
    chargeSpeed = 10,
    speedFast = 4,
    speedSlow = 2,
    sensor = { apiVersion=1, valid=true, state=0, protectionFrames=0,
      canCharge=true, chargeBlockFrames=0, baseScaleX=1, baseScaleY=1,
      moveScaleX=1, moveScaleY=1, poisonClouds={} },
    hitBodyRect = { type = HitType.Rect, x = 0, y = 320, width = 4, height = 4 },
    hitBodyCircle = { type = HitType.Circle, x = 0, y = 320, radius = 2 },
  }
end

local function resetWorld()
  sent = {}
  local player = newPlayer()
  game_sides = {
    [1] = { player = newPlayer(), enemies = {}, bullets = {}, exAttacks = {}, items = {} },
    [2] = { player = player, enemies = {}, bullets = {}, exAttacks = {}, items = {} },
  }
  return player, game_sides[2]
end

local function hasBit(mask, value)
  return math.floor(mask / value) % 2 == 1
end

local function assertNoX()
  for index, mask in ipairs(sent) do
    assert(not hasBit(mask, 2), "X bit emitted at output " .. tostring(index))
  end
end

-- Isolate optional generated settings from the machine's current AI folder.
-- A fixture path uses the actual Lua file loader, including syntax parsing.
local function loadBattle(seconds, fixture)
  local actual_loadfile, actual_open = loadfile, io.open
  loadfile = function(path, ...)
    if path == "runtime-settings.lua" then
      if fixture then return actual_loadfile(fixture, ...) end
      if seconds == nil then return nil, "fixture intentionally absent" end
      return function() return { seconds = seconds } end
    end
    return actual_loadfile(path, ...)
  end
  io.open = function(path, ...)
    if path == "runtime-settings.lua" then
      if fixture then return actual_open(fixture, ...) end
      if seconds == nil then return nil, "fixture intentionally absent" end
      return { close = function() end }
    end
    return actual_open(path, ...)
  end
  local ok, result = pcall(dofile, "main.lua")
  loadfile, io.open = actual_loadfile, actual_open
  if not ok then error(result) end
end

-- Insufficient energy: alternate Z press/release for normal shots, never hold
-- it across consecutive frames, and never emit X.
do
  local player = resetWorld()
  loadBattle()
  for _ = 1, 120 do
    main()
  end
  local saw_normal_shot = false
  local previous_z = false
  for _, mask in ipairs(sent) do
    local current_z = hasBit(mask, 1)
    saw_normal_shot = saw_normal_shot or current_z
    assert(not (previous_z and current_z), "Z was held while charge energy was insufficient")
    previous_z = current_z
  end
  assert(saw_normal_shot, "AI did not perform normal tap shooting while waiting for energy")
  assertNoX()
end

-- Enough energy: hold Z, then release it once the selected threshold is met.
do
  local player = resetWorld()
  player.currentChargeMax = 400
  loadBattle()
  local saw_press = false
  local saw_release_after_press = false
  for _ = 1, 120 do
    main()
    local pressed = hasBit(sent[#sent], 1)
    if pressed then
      saw_press = true
      player.currentCharge = math.min(400, player.currentCharge + 25)
    elseif saw_press then
      saw_release_after_press = true
      break
    end
  end
  assert(saw_press, "AI never started charging with full energy")
  assert(saw_release_after_press, "AI never released Z after reaching its target charge")
  assertNoX()
end

-- Spell Point lock has hysteresis: reaching 500k locks, falling below 500k
-- does not unlock, and reaching exactly zero unlocks.
do
  local player = resetWorld()
  player.currentChargeMax = 400
  player.spellPoint = 500000
  loadBattle()
  main()
  assert(not hasBit(sent[#sent], 1), "Z emitted at the Spell Point stop threshold")
  player.spellPoint = 100
  main()
  assert(not hasBit(sent[#sent], 1), "Spell Point lock released before zero")
  player.spellPoint = 0
  main()
  assert(hasBit(sent[#sent], 1), "Spell Point lock did not release at zero")
  assertNoX()
end

-- A visible zero-thickness rotated laser is treated as a warning hazard.
do
  local player, side = resetWorld()
  side.bullets = {
    {
      x = 0, y = 320, vx = 0, vy = 0,
      hitBody = {
        type = HitType.RotatableRect,
        x = 0, y = 320,
        width = 420, height = 0,
        angle = math.pi / 2,
      },
    },
  }
  loadBattle()
  main()
  assert(hasBit(sent[#sent], 16) or hasBit(sent[#sent], 32)
    or hasBit(sent[#sent], 64) or hasBit(sent[#sent], 128),
    "AI stayed still on a visible zero-thickness laser warning")
  assertNoX()
end

-- The first 600 * 60 active frames are controlled; the following frame and
-- every frame after it contain zero generated input.
do
  local player = resetWorld()
  player.x = 100
  -- Keep charge below target so Z stays held: this tests the timer independent
  -- of the dodge planner legitimately stopping in an empty field.
  player.currentChargeMax = 400
  player.hitBodyRect.x = 100
  player.hitBodyCircle.x = 100
  loadBattle()
  for _ = 1, 36000 do
    main()
  end
  assert(sent[#sent] ~= 0, "AI stopped before completing 600 active seconds")
  main()
  assert(sent[#sent] == 0, "AI did not release all keys at the operation limit")
  for _ = 1, 10 do
    main()
    assert(sent[#sent] == 0, "AI resumed input after timing out")
  end
  assertNoX()
end

-- A generated one-second limit controls exactly 60 frames, stays stopped for
-- the rest of the battle, and resets when main.lua is reloaded next battle.
do
  local player = resetWorld()
  player.currentChargeMax = 400
  loadBattle(1)
  for _ = 1, 60 do main(); assert(sent[#sent] ~= 0, "One-second limit stopped early") end
  for _ = 1, 120 do main(); assert(sent[#sent] == 0, "Timed-out battle resumed input") end
  loadBattle(1)
  for _ = 1, 60 do main(); assert(sent[#sent] ~= 0, "Next battle did not reset timer") end
  main()
  assert(sent[#sent] == 0, "Next battle did not apply its fresh one-second limit")
  assertNoX()
end

-- Zero means unlimited and must not silently fall back to the 600s default.
do
  local player = resetWorld()
  player.currentChargeMax = 400
  loadBattle(0)
  for _ = 1, 36061 do main() end
  assert(sent[#sent] ~= 0, "seconds=0 incorrectly stopped after the default limit")
  assertNoX()
end

-- Alternative controls must not silently swap charge and slow movement.
do
  local player, side = resetWorld()
  player.currentChargeMax = 400
  side.chargeType = ChargeType.Charge
  loadBattle(1)
  for _ = 1, 5 do main(); assert(sent[#sent] == 0, "Charge mode must release every key") end
  side.chargeType = ChargeType.Slow
  main()
  assert(hasBit(sent[#sent], 1), "Slow mode must restore ordinary charging")
  for _ = 1, 60 do main() end
  assert(sent[#sent] == 0, "Mode recovery must not reset battle timeout")
  assertNoX()
end

-- Generated settings still reject malformed values if used without launcher.
-- A mixed-version/malformed sensor must release every key, then recover only
-- after a complete fresh snapshot. Timeout and Spell Point lock still win.
do
  local player = resetWorld()
  player.currentChargeMax = 400
  local sensor = player.sensor
  loadBattle(1)
  main()
  assert(hasBit(sent[#sent], 1), "valid sensor must allow ordinary charging")
  player.sensor = nil
  main()
  assert(sent[#sent] == 0, "missing native sensor must release all input")
  player.sensor = sensor
  sensor.apiVersion = 0
  main()
  assert(sent[#sent] == 0, "wrong sensor API must release all input")
  sensor.apiVersion = 1
  sensor.moveScaleX = 0/0
  main()
  assert(sent[#sent] == 0, "nonfinite speed must release all input")
  sensor.moveScaleX = 1
  main()
  assert(hasBit(sent[#sent], 1), "valid snapshot should recover ordinary charging")
  for _ = 1, 60 do main() end
  assert(sent[#sent] == 0, "sensor recovery must not reset battle timeout")
  assertNoX()
end

do
  local player = resetWorld()
  player.currentChargeMax, player.currentCharge = 400, 400
  player.sensor.canCharge, player.sensor.chargeBlockFrames = false, 20
  loadBattle()
  main()
  assert(hasBit(sent[#sent], 1), "blocked action must not release an old full-charge value")
  player.spellPoint = 500000
  main()
  assert(not hasBit(sent[#sent], 1), "Spell Point lock must override pre-holding Z")
  player.spellPoint = 0
  main()
  assert(hasBit(sent[#sent], 1), "zero Spell Point must resume pre-holding")
  player.sensor.canCharge, player.sensor.chargeBlockFrames = true, 0
  main()
  assert(not hasBit(sent[#sent], 1), "ready selected charge must release after action gate opens")
  assertNoX()
end

for _, invalid in ipairs({ -1, 86401, 1.5, "1", false }) do
  resetWorld()
  assert(not pcall(loadBattle, invalid), "Invalid generated seconds was accepted")
end

-- The integration test supplies a real file emitted by prepare-and-start.ps1
-- from launcher-settings.json, rather than mocking its parsed contents.
if RUNTIME_SETTINGS_FIXTURE then
  local player = resetWorld()
  player.currentChargeMax = 400
  loadBattle(nil, RUNTIME_SETTINGS_FIXTURE)
  for _ = 1, 60 do main(); assert(sent[#sent] ~= 0, "Generated fixture stopped early") end
  main()
  assert(sent[#sent] == 0, "Launcher-generated seconds did not reach Lua timer")
  assertNoX()
  print("runtime-settings fixture: PASS")
end

print("mock_ai_test: PASS")
