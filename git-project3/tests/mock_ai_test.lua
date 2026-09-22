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
local function loadBattle(seconds, fixture, timer_only)
  local actual_dofile = dofile
  dofile = function(path, ...)
    if path == "config.lua" then
      local cfg = actual_dofile(path, ...)
      -- These legacy resource fixtures deliberately span the whole field.
      -- Default-circle wiring is tested separately in vision_integration_test.
      cfg.dodge.vision_radius = 640
      return cfg
    end
    if path == "dodge.lua" and timer_only then
      local module = actual_dofile(path, ...)
      module.choose = function() return {key=16,name="timer-fixture",focus=false} end
      return module
    end
    return actual_dofile(path, ...)
  end
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
  loadfile, io.open, dofile = actual_loadfile, actual_open, actual_dofile
  if not ok then error(result) end
end


local function richWorld()
  local p, side = resetWorld()
  for i=1,4 do
    side.enemies[i] = {id=i,enabled=true,x=(i%2)*12-6,y=100+(i-1)*45,vx=0,vy=0,
      isSpirit=false,isActivatedSpirit=false,isBoss=false,isLily=false,isPseudoEnemy=false}
  end
  for i=1,20 do
    side.bullets[i] = {id=100+i,enabled=true,isErasable=true,x=(i%5)*10-20,y=80+math.floor(i/5)*5,vx=0,vy=0}
  end
  return p, side
end

-- Empty resources mean waiting, even with full energy and high score.
do
  local p = resetWorld(); p.currentChargeMax=400; p.spellPoint=900000
  loadBattle()
  for i=1,120 do main(); assert(not hasBit(sent[#sent],1),'empty field fired Z'); assert(not hasBit(sent[#sent],4),'empty field held Shift') end
  assertNoX()
end

-- Real main-loop cadence wiring: a transient sensor fault must stop keys,
-- but cannot erase the accumulated C2 interval or postpone it another 8s.
do
  local p=resetWorld();p.currentChargeMax=400;p.sensor.chargeWarmupFrames=11
  loadBattle()
  for i=1,440 do main();assert(not hasBit(sent[#sent],1),'deadline began before its lead window') end
  local sensor=p.sensor;p.sensor=nil;main();assert(sent[#sent]==0,'cadence bypassed invalid sensor')
  p.sensor=sensor
  for i=441,446 do main();assert(not hasBit(sent[#sent],1),'cadence clock advanced during invalid snapshot') end
  main();assert(hasBit(sent[#sent],1),'sensor reset erased the accumulated C2 interval')
  p.currentCharge=200;main();assert(not hasBit(sent[#sent],1),'deadline C2 failed to release')
  assertNoX()
end

-- Ordinary taps bootstrap a useful fairy chain without charge energy.
do
  local p = richWorld(); loadBattle()
  local shot, previous = false, false
  for i=1,60 do
    main(); local z=hasBit(sent[#sent],1)
    assert(not (previous and z),'normal fire accidentally held charge')
    shot=shot or z;previous=z
  end
  assert(shot,'useful fairy chain did not bootstrap normal fire');assertNoX()
end

-- Resource-rich C2: no random target, never charge to 300/400.
do
  local p = richWorld();p.currentChargeMax=400;loadBattle()
  local saw=false
  for i=1,40 do
    main();local z=hasBit(sent[#sent],1)
    if z then saw=true;p.currentCharge=p.currentCharge+25
    elseif saw then assert(p.currentCharge>=200 and p.currentCharge<300,'release was not C2');break end
  end
  assert(saw and p.currentCharge==200,'resource-ready C2 did not complete');assertNoX()
end

-- C2 can ignite an off-axis, entirely unactivated spirit chain. The same
-- scene at C1-only energy must not pretend ordinary shots can ignite it.
do
  local p, side = richWorld();p.currentChargeMax=400
  for _,e in ipairs(side.enemies) do e.x=70;e.isSpirit=true;e.isActivatedSpirit=false end
  for _,b in ipairs(side.bullets) do b.x=70 end
  loadBattle();main();assert(hasBit(sent[#sent],1),'C2 wrongly required shot ignition/alignment')
  p.currentCharge=125;main();assert(hasBit(sent[#sent],1),'unactivated C2 lock failed during charge')
  p.currentCharge=200;main();assert(not hasBit(sent[#sent],1),'C2 did not release at 200')
  p.currentCharge,p.currentChargeMax=0,100;loadBattle()
  for i=1,10 do main();assert(not hasBit(sent[#sent],1),'unactivated spirit directly shot by C1/normal fire') end
  assertNoX()
end

-- Many white bullets inside the direct-C2 envelope cannot fund another C2.
-- Fairy ignition remains a useful C1; unactivated-only resources must wait.
do
  local p, side=richWorld();p.currentChargeMax=400
  for i,e in ipairs(side.enemies) do e.y=200+i*15 end
  for i,b in ipairs(side.bullets) do b.y=210+math.floor(i/5)*10 end
  loadBattle()
  for i=1,12 do main();if hasBit(sent[#sent],1) then p.currentCharge=p.currentCharge+25 else break end end
  assert(p.currentCharge==100,'directly swallowed white bullets were budgeted for C2')
  p.currentCharge=0
  for _,e in ipairs(side.enemies) do e.isSpirit=true;e.isActivatedSpirit=false end
  loadBattle();main();assert(not hasBit(sent[#sent],1),'swallowed-only spirit scene fired C2')
  assertNoX()
end

-- Spell Point does not affect the new policy.
for _, score in ipairs({499999,500000,900000,100,0}) do
  local p=richWorld();p.currentChargeMax=400;p.spellPoint=score;loadBattle();main()
  assert(hasBit(sent[#sent],1),'obsolete Spell Point lock remains at '..score);assertNoX()
end

-- A sparse chain can choose C1 even when C2 energy is available.
do
  local p, side=richWorld();side.enemies[4]=nil;side.bullets={};p.currentChargeMax=400;loadBattle()
  for i=1,20 do main();if hasBit(sent[#sent],1) then p.currentCharge=p.currentCharge+25 else break end end
  assert(p.currentCharge==100,'active chain-building C1 did not release at 100');assertNoX()
end

-- Loss of the original chain must not silently adopt a remote chain while charging.
do
  local p, side=richWorld();p.currentChargeMax=400;loadBattle();main();assert(hasBit(sent[#sent],1))
  p.currentCharge=50
  for i,e in ipairs(side.enemies) do e.id=50+i;e.x=120 end
  main();assert(not hasBit(sent[#sent],1),'lost locked chain continued charging C2');assertNoX()
end

-- User-confirmed mechanic: unactivated spirits relay a fairy explosion, but
-- cannot be the ordinary-shot ignition target. This bridge changes the plan.
do
  local p, side = resetWorld();p.currentChargeMax=100
  side.enemies={
    {id=1,enabled=true,isSpirit=false,x=0,y=220,vx=0,vy=0},
    {id=2,enabled=true,isSpirit=true,isActivatedSpirit=false,x=50,y=220,vx=0,vy=0},
    {id=3,enabled=true,isSpirit=false,x=100,y=220,vx=0,vy=0},
  }
  loadBattle();main();assert(hasBit(sent[#sent],1),'unactivated spirit was excluded from explosion chain')
  side.enemies={side.enemies[1],side.enemies[3]}
  loadBattle();main();assert(not hasBit(sent[#sent],1),'disconnected fairies counted as one chain')
  side.enemies={{id=2,enabled=true,isSpirit=true,isActivatedSpirit=false,x=0,y=220,vx=0,vy=0}}
  loadBattle();main();assert(not hasBit(sent[#sent],1),'unactivated spirit selected as direct shot target');assertNoX()
end

-- Slow can be selected without movement, but is not the default supply mode.
do
  local p,side=resetWorld()
  side.enemies={{id=30,enabled=true,isSpirit=true,isActivatedSpirit=false,x=0,y=240,vx=0,vy=0}}
  loadBattle();local slow=false
  for i=1,105 do
    main();if i<=72 then assert(not hasBit(sent[#sent],4),'focus started before fast interval') end
    slow=slow or hasBit(sent[#sent],4)
  end
  assert(slow,'no selective spirit-capture window');assertNoX()
end

-- Existing warning-laser escape is still active.
do
  local p,side=resetWorld()
  side.bullets={{x=0,y=320,vx=0,vy=0,hitBody={type=HitType.RotatableRect,x=0,y=320,width=420,height=0,angle=math.pi/2}}}
  loadBattle();main();local m=sent[#sent]
  assert(hasBit(m,16) or hasBit(m,32) or hasBit(m,64) or hasBit(m,128),'laser warning did not trigger dodge');assertNoX()
end

-- The actual main -> bloom -> dodge -> key path enforces the ceiling even
-- when all escape paths collide. An initially high position recovers by
-- ordinary inputs, never by rewriting the player snapshot.
do
  for _, y in ipairs({100,150,150.5}) do
    local p,side=resetWorld();p.y=y
    side.bullets={{x=0,y=y,vx=0,vy=0,
      hitBody={type=HitType.Circle,x=0,y=y,radius=300}}}
    loadBattle();main()
    assert(not hasBit(sent[#sent],16),'main allowed upward crossing of bloom ceiling')
    assert(p.y==y,'height policy rewrote native player position');assertNoX()
  end
  local p=resetWorld();p.y=100;loadBattle()
  for _=1,30 do
    local old_y=p.y
    main();local mask=sent[#sent]
    local speed=hasBit(mask,4) and p.speedSlow or p.speedFast
    local dy=(hasBit(mask,32) and 1 or 0)-(hasBit(mask,16) and 1 or 0)
    local dx=(hasBit(mask,128) and 1 or 0)-(hasBit(mask,64) and 1 or 0)
    if dx~=0 and dy~=0 then speed=speed/math.sqrt(2) end
    p.y=p.y+dy*speed
    assert(p.y>=math.min(old_y,150),'recovery moved farther above the ceiling')
  end
  assert(p.y>=150,'safe above-ceiling position did not recover with real inputs')
end

-- Timing is tested with a deliberately constant movement provider, so a
-- legitimate empty-field bloom wait cannot masquerade as a timeout.
do
  resetWorld();loadBattle(nil,nil,true)
  for i=1,36000 do main();assert(sent[#sent]==16,'default timeout occurred early') end
  for i=1,10 do main();assert(sent[#sent]==0,'default timeout did not remain stopped') end
  assertNoX()
end
for _,seconds in ipairs({0,1}) do
  resetWorld();loadBattle(seconds,nil,true)
  local n=seconds==0 and 36061 or 60
  for i=1,n do main();assert(sent[#sent]==16,'configured duration stopped early') end
  if seconds==1 then
    for i=1,120 do main();assert(sent[#sent]==0,'timed-out battle resumed') end
    loadBattle(1,nil,true);main();assert(sent[#sent]==16,'next battle did not reset timer')
  end
  assertNoX()
end

-- Charge layout and sensor faults release every key; recovery does not reset time.
do
  local p,side=richWorld();p.currentChargeMax=400;side.chargeType=ChargeType.Charge;loadBattle(1)
  main();assert(sent[#sent]==0,'unsupported layout did not stop input')
  side.chargeType=ChargeType.Slow;main();assert(hasBit(sent[#sent],1),'Slow layout did not recover')
  local sensor=p.sensor;p.sensor=nil;main();assert(sent[#sent]==0,'missing sensor did not stop input')
  p.sensor=sensor;sensor.apiVersion=0;main();assert(sent[#sent]==0,'wrong sensor API did not stop input')
  sensor.apiVersion=1;sensor.moveScaleX=0/0;main();assert(sent[#sent]==0,'NaN sensor did not stop input')
  sensor.moveScaleX=1;p.currentCharge=400;main();assert(not hasBit(sent[#sent],1),'stale full charge reused after fault')
  p.currentCharge=0;main();assert(hasBit(sent[#sent],1),'fresh valid snapshot did not recover')
  for i=1,60 do main() end
  assert(sent[#sent]==0,'fault recovery reset timeout');assertNoX()
end
for _, bad in ipairs({0,100,math.huge,0/0}) do
  local p=richWorld();p.currentChargeMax=400;p.chargeSpeed=bad;loadBattle();main()
  assert(sent[#sent]==0,'invalid charge speed did not stop all input')
end
for _, field in ipairs({'currentCharge','currentChargeMax'}) do
  for _,bad in ipairs({-1,401,math.huge,0/0}) do
    local p=richWorld();p.currentChargeMax=400;p[field]=bad;loadBattle();main()
    assert(sent[#sent]==0,'invalid charge snapshot did not stop all input')
  end
end
for _,field in ipairs({'timeScale','chargeWarmupFrames'}) do
  for _,bad in ipairs({-1,math.huge,0/0,'1'}) do
    local p=richWorld();p.currentChargeMax=400;p.sensor[field]=bad;loadBattle();main()
    assert(sent[#sent]==0,'invalid cadence timing field did not fail closed: '..field)
  end
end

-- Closed action gate neither starts a new attack nor reuses stale full charge.
do
  local p=richWorld();p.currentChargeMax=400;p.currentCharge=400;p.sensor.canCharge=false
  loadBattle();main();assert(not hasBit(sent[#sent],1),'blocked action started a new charge')
  p.sensor.canCharge=true;main();assert(not hasBit(sent[#sent],1),'old full charge reused')
  p.currentCharge=0;main();assert(hasBit(sent[#sent],1),'fresh available action did not start');assertNoX()
end
for _, invalid in ipairs({-1,86401,1.5,'1',false}) do
  resetWorld();assert(not pcall(loadBattle,invalid),'invalid duration accepted')
end
if RUNTIME_SETTINGS_FIXTURE then
  resetWorld();loadBattle(nil,RUNTIME_SETTINGS_FIXTURE,true)
  for i=1,60 do main();assert(sent[#sent]==16,'real launcher settings stopped early') end
  main();assert(sent[#sent]==0,'real launcher settings were ignored');assertNoX()
  print('runtime-settings fixture: PASS')
end
print('mock_ai_test: PASS (bloom integration, limits, fail-closed snapshots, no X)')
