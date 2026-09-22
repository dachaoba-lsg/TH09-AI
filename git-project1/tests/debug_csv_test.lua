-- In-memory diagnostic integration: no CSV, INI or game files are written.
HitType = { Rect = 0, Circle = 1, RotatableRect = 2 }
player_side = 2
local actual_dofile, actual_open = dofile, io.open
local output, sent = {}, {}
local cfg = actual_dofile('config.lua')
cfg.debug_log, cfg.debug_log_interval_frames = true, 1
dofile = function(path)
  if path == 'config.lua' then return cfg end
  return actual_dofile(path)
end
io.open = function(path, mode)
  if path == 'runtime-settings.lua' then return nil end
  assert(path == 'ai_debug.csv' and mode == 'w', 'unexpected I/O')
  return { write = function(_, text) output[#output+1] = text end,
    flush = function() end, close = function() end }
end
function sendKeys(mask) sent[#sent+1] = mask end
local player = { x=0, y=320, life=10, spellPoint=0, combo=0,
  currentCharge=0, currentChargeMax=0, speedFast=4, speedSlow=2,
  hitBodyRect={type=HitType.Rect,width=4,height=4}, hitBodyCircle={radius=2},
  sensor={apiVersion=1,valid=true,state=0,protectionFrames=0,canCharge=true,
    chargeBlockFrames=0,baseScaleX=1,baseScaleY=1,moveScaleX=0.4,moveScaleY=0.4,
    poisonClouds={{x=0,y=320,radius=64,age=50,framesLeft=250,active=true}}} }
local beam = { id=42, x=120, y=20, vx=0, vy=0,
  hitBody={type=HitType.RotatableRect,x=120,y=20,width=400,height=4,angle=math.pi/2} }
game_sides = {[2]={player=player,bullets={beam},enemies={},exAttacks={}}}
actual_dofile('main.lua')
main()
beam.hitBody.x = 116
main()
assert(#output == 3 and #sent == 2, 'header and two samples expected')
local function columns(line)
  local result = {}
  for value in (line:gsub('\n','')..','):gmatch('(.-),') do result[#result+1] = value end
  return result
end
local header, first, second = columns(output[1]), columns(output[2]), columns(output[3])
assert(#header == 34 and #first == 34 and #second == 34, 'CSV columns not aligned')
local map = {}; for index,name in ipairs(header) do map[name]=index end
assert(tonumber(first[map.laser_count]) == 1, 'laser count missing from diagnostics')
assert(tonumber(first[map.tracked_lasers]) == 0, 'first frame must not invent history')
assert(tonumber(second[map.tracked_lasers]) == 1, 'continuous history missing from diagnostics')
assert(tonumber(second[map.dynamic_lasers]) == 1, 'motion missing from diagnostics')
assert(tonumber(first[map.laser_history_resets]) == 0, 'new laser is not an invalid jump')
assert(tonumber(first[map.sensor_valid]) == 1, 'sensor validity missing')
assert(math.abs(tonumber(first[map.move_scale_x]) - 0.4) < 1e-6, 'poison speed missing')
assert(first[map.can_charge] == 'true', 'charge gate missing')
for _,mask in ipairs(sent) do assert(math.floor(mask/2)%2 == 0, 'X key emitted') end
io.open, dofile = actual_open, actual_dofile
print('PASS: in-memory main-loop CSV integration, 34 matching columns, laser/poison/state counters, no X')
