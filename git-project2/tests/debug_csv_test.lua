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
  currentCharge=0, currentChargeMax=0, chargeSpeed=10, speedFast=4, speedSlow=2,
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
assert(#header == 109 and #first == 109 and #second == 109, 'CSV columns not aligned')
local map = {}; for index,name in ipairs(header) do map[name]=index end
assert(tonumber(first[map.laser_count]) == 1, 'laser count missing from diagnostics')
assert(tonumber(first[map.tracked_lasers]) == 0, 'first frame must not invent history')
assert(tonumber(second[map.tracked_lasers]) == 1, 'continuous history missing from diagnostics')
assert(tonumber(second[map.dynamic_lasers]) == 1, 'motion missing from diagnostics')
assert(tonumber(first[map.laser_history_resets]) == 0, 'new laser is not an invalid jump')
assert(tonumber(first[map.sensor_valid]) == 1, 'sensor validity missing')
assert(math.abs(tonumber(first[map.move_scale_x]) - 0.4) < 1e-6, 'poison speed missing')
assert(first[map.can_charge] == 'true', 'charge gate missing')
assert(first[map.bloom_phase] == 'grow', 'empty field should preserve resources')
assert(first[map.bloom_reason] == 'no_ignition_target', 'bloom decision reason missing')
assert(first[map.focus_requested] == 'false', 'empty field must preserve fairy supply')
assert(tonumber(first[map.release_c2_requests]) == 0, 'empty field must not request C2')
assert(first[map.c2_has_ignition] == 'false', 'empty field invented C2 ignition')
assert(tonumber(first[map.since_c2_frames]) == 1 and tonumber(second[map.since_c2_frames]) == 2,
  'cadence clock missing or reset without C2')
assert(first[map.cadence_charge] == 'false', 'cadence started before its lead window')
assert(tonumber(first[map.bloom_min_y]) == 150, 'height ceiling missing')
assert(first[map.c2_position_valid] == 'false', 'empty scene invented lower release opportunity')
assert(first[map.height_recovering] == 'false', 'legal player position marked above ceiling')
assert(tonumber(first[map.c2_net_fraction]) == 0, 'empty scene invented net yield share')
assert(first[map.prepare_locked] == 'false' and tonumber(first[map.armed_age]) == 0,
  'empty scene invented a prepared or armed chain')
assert(tonumber(first[map.chain_exit_frames]) == -1 and tonumber(first[map.c2_exit_frames]) == -1,
  'unknown exit estimate must not be reported as immediate leakage')
for _,name in ipairs({'c2_chain_score','c2_chain_enemies','c2_chain_bullets',
  'c2_direct_bullets','c2_contested_bullets','c2_future_score','c2_future_bullets'}) do
  assert(tonumber(first[map[name]]) == 0, 'empty C2 diagnostic missing: '..name)
end
for _,mask in ipairs(sent) do assert(math.floor(mask/2)%2 == 0, 'X key emitted') end
io.open, dofile = actual_open, actual_dofile
assert(first[map.followup_confirmed] == 'false' and tonumber(first[map.followup_z_requests]) == 0,
  'empty scene invented a confirmed C2 follow-up')
 print('PASS: in-memory main-loop CSV integration, 109 matching columns, C2 resources/cadence/position/height/follow-up/route, no X')
