-- Same observed states and RNG seed must produce identical firing decisions.
-- Movement may differ. No files, inputs or actual game state are modified.
HitType = { Rect = 0, Circle = 1, RotatableRect = 2 }
ExAttackType = { Medicine = 16 }
ChargeType = { Slow = 0, Charge = 1 }
player_side = 2
local actual_dofile, actual_open, actual_loadfile = dofile, io.open, loadfile
local actual_seed, actual_random = math.randomseed, math.random
-- Optional historical source is deliberately not distributed. Without it,
-- compare navigation enabled/disabled while retaining all current assertions.
local old_root = os.getenv('TH09_POISON_BASELINE_ROOT')
if old_root and old_root ~= '' then
  old_root = old_root:gsub('\\', '/'):gsub('/+$', '') .. '/'
  local old_file = assert(actual_open(old_root .. 'main.lua', 'r'), 'configured baseline root has no main.lua')
  old_file:close()
else old_root = nil end
local function run(root, seconds, disable_navigation)
  local masks, random_calls = {}, 0
  local player = { x=0,y=320,life=10,spellPoint=0,combo=0,
    speedFast=4,speedSlow=2,hitBodyRect={width=4,height=4},hitBodyCircle={radius=2},
    sensor={apiVersion=1,valid=true,state=0,canCharge=true,chargeBlockFrames=0,
      protectionFrames=0,baseScaleX=1,baseScaleY=1,moveScaleX=1,moveScaleY=1,poisonClouds={}} }
  game_sides = {[2]={player=player,chargeType=ChargeType.Slow,bullets={},enemies={},exAttacks={}}}
  math.randomseed = function() actual_seed(192192) end
  math.random = function(...) random_calls = random_calls + 1; return actual_random(...) end
  io.open = function(path, ...)
    if path == 'runtime-settings.lua' then return {close=function() end} end
    return actual_open(path, ...)
  end
  loadfile = function(path, ...)
    if path == 'runtime-settings.lua' then return function() return {seconds=seconds} end end
    return actual_loadfile(path, ...)
  end
  dofile = function(path)
    local value = actual_dofile(root .. path)
    if path == 'config.lua' and disable_navigation then
      assert(value.dodge.poison_navigation, 'current navigation configuration missing')
      value.dodge.poison_navigation.enabled = false
    end
    return value
  end
  sendKeys = function(mask) masks[#masks+1] = mask end
  actual_dofile(root .. 'main.lua')
  for frame=1,720 do
    local stage = frame % 90
    player.currentChargeMax = stage < 20 and 80 or 400
    player.currentCharge = math.min(400, (frame % 23) * 25)
    player.spellPoint = stage >= 60 and (stage < 70 and 550000 or 100) or 0
    player.sensor.canCharge = frame % 37 >= 8
    player.sensor.chargeBlockFrames = player.sensor.canCharge and 0 or 8
    player.sensor.state = frame % 41 < 12 and 3 or 0
    player.sensor.protectionFrames = player.sensor.state == 3 and 60 or 0
    if frame % 120 < 90 then
      player.sensor.poisonClouds = {{x=0,y=320,radius=64,age=50,ageInt=50,framesLeft=250,active=true}}
      player.sensor.moveScaleX,player.sensor.moveScaleY = 0.4,0.4
    else
      player.sensor.poisonClouds = {}
      player.sensor.moveScaleX,player.sensor.moveScaleY = 1,1
    end
    main()
    local mask = masks[#masks]
    assert(math.floor(mask/2)%2 == 0, 'X emitted')
    if seconds > 0 and frame > seconds*60 then assert(mask == 0, 'timeout did not release every key') end
    if stage >= 60 then assert(mask%2 == 0, 'Spell Point lock did not suppress Z') end
  end
  return masks,random_calls
end
for _,seconds in ipairs({0,1}) do
  local old,old_random = run(old_root or '',seconds,not old_root)
  local new,new_random = run('',seconds)
  assert(#old == #new and old_random == new_random, 'firing RNG consumption changed')
  for i=1,#old do assert(old[i]%2 == new[i]%2, 'Z policy changed at frame '..i) end
end
io.open,loadfile,dofile,math.randomseed,math.random = actual_open,actual_loadfile,actual_dofile,actual_seed,actual_random
print('random_c_unchanged_test: PASS (1440 states; same Z/RNG, no X, score lock and timeout; baseline=' ..
  (old_root and 'explicit historical source' or 'current navigation disabled') .. ')')
