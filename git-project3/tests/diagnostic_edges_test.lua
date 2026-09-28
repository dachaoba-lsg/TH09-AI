-- Real main + real policies, with a wrapper supplying diagnostic-only alert
-- transitions. Verify sampling and metadata without game or filesystem I/O.
HitType = { Rect=0, Circle=1, RotatableRect=2 }
ExAttackType = { Medicine=16 }
ChargeType = { Slow=0, Charge=1 }
player_side = 1
local real_dofile, real_open, real_loadfile = dofile, io.open, loadfile
local cfg = real_dofile('config.lua')
cfg.debug_log, cfg.debug_log_interval_frames = true, 30
local output, sent, frame, checks = {}, {}, 0, 0
local function check(value,message) checks=checks+1;assert(value,message) end
local function p(character)
  return { character=character,x=0,y=320,life=10,spellPoint=0,combo=0,
    currentCharge=0,currentChargeMax=0,chargeSpeed=3.3,speedFast=4,speedSlow=2,
    hitBodyRect={type=HitType.Rect,width=4,height=4},hitBodyCircle={radius=2},
    sensor={apiVersion=1,valid=true,state=0,protectionFrames=0,canCharge=true,
      chargeBlockFrames=0,chargeWarmupFrames=7,timeScale=1,cutIn=false,
      baseScaleX=1,baseScaleY=1,moveScaleX=1,moveScaleY=1,poisonClouds={}} }
end
game_sides = {
  [1]={player=p(13),chargeType=ChargeType.Slow,bullets={},enemies={},exAttacks={}},
  [2]={player=p(9),chargeType=ChargeType.Slow,bullets={},enemies={},exAttacks={}}
}
dofile=function(path)
  if path=='config.lua' then return cfg end
  local mod=real_dofile(path)
  if path=='dodge.lua' then
    local choose=mod.choose
    mod.choose=function(...)
      local move=choose(...)
      move.attention_blind_urgent=frame==2 and 1 or 0
      move.move_cap_risk=frame==5
      move.attention_overloaded=frame==8
      -- A scan flag changing alone must not create a high-frequency log.
      move.attention_scanned=frame%2==0
      return move
    end
  end
  return mod
end
io.open=function(path,mode)
  if path=='runtime-settings.lua' then return {close=function()end} end
  if mode=='r' then return nil end
  check(mode=='w' and path:match('^ai_debug_unlimited'), 'unexpected diagnostic I/O')
  return {write=function(_,s)output[#output+1]=s end,flush=function()end,close=function()end}
end
loadfile=function(path)
  if path=='runtime-settings.lua' then return function()
    return {seconds=0,ai={difficulty='unlimited',plan_interval=6}}
  end end
  return real_loadfile(path)
end
sendKeys=function(mask)sent[#sent+1]=mask end
real_dofile('main.lua')
for step=1,30 do frame=step;main() end
local function split(line)
  local values={};for v in (line:gsub('[\r\n]','')..','):gmatch('(.-),') do values[#values+1]=v end
  return values
end
local header=split(output[1]);local index={}
for i,name in ipairs(header)do index[name]=i end
local expected={1,2,3,5,6,8,9,30}
check(#header==211 and header[169]=='c1_seed_wait_age','CSV prefix/width changed')
check(#output==#expected+1,'alert edges or periodic sample lost/duplicated')
for i,f in ipairs(expected)do
  local row=split(output[i+1])
  check(#row==211,'row width mismatch')
  check(tonumber(row[index.frame])==f,'unexpected sample frame')
  check(row[index.ai_version]=='3.9.0-test','build identity missing')
  check(row[index.ai_side]=='1' and row[index.ai_character]=='13' and row[index.opponent_character]=='9','character/side identity incorrect')
  check(row[index.attention_plan_interval]=='6','runtime scan interval override not logged')
  check(row[index.charge_warmup_frames]=='7' and row[index.time_scale]=='1','charge timing missing')
end
check(#sent==30,'logging changed callback count')
for _,mask in ipairs(sent)do check(mask==0,'diagnostic alerts changed calm-policy inputs')end
-- Malformed/missing role metadata must stay unknown; logging cannot crash or
-- silently classify an absent character as character zero.
game_sides[1].player.character=0/0;game_sides[2].player.character=16
frame=31;cfg.debug_log_interval_frames=1;main()
local row=split(output[#output])
check(row[index.ai_character]=='-1' and row[index.opponent_character]=='-1','invalid role metadata was trusted')
game_sides[1].player.character=0;game_sides[2]=nil
frame=32;main();row=split(output[#output])
check(row[index.ai_character]=='0' and row[index.opponent_character]=='-1','valid Reimu or missing opposite side misreported')
io.open,dofile,loadfile=real_open,real_dofile,real_loadfile
print('diagnostic_edges_test: PASS ('..checks..' checks; real main sampling/metadata, no game or file writes)')
