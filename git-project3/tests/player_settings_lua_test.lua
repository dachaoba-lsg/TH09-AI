-- 3.3.0 player controls through the real main.lua runtime-settings loader.
-- Source modules and choose() run unmodified; only I/O and outbound keys are
-- captured. RUNTIME_SETTINGS_FIXTURE optionally names real launcher output.
HitType={Rect=0,Circle=1,RotatableRect=2}
ExAttackType={Medicine=16}
ChargeType={Slow=0,Charge=1}
player_side=2
local real_dofile,real_open,real_loadfile=dofile,io.open,loadfile
local checks,cases,failures=0,0,{}
local function check(v,m) checks=checks+1;assert(v,m) end
local function eq(a,b,m)
  if type(a)=='number' and type(b)=='number' then check(math.abs(a-b)<1e-9,m..': '..tostring(a)..' ~= '..tostring(b))
  else check(a==b,m..': '..tostring(a)..' ~= '..tostring(b)) end
end
local function scenario(name,fn)
  cases=cases+1;local ok,err=pcall(fn)
  dofile,io.open,loadfile=real_dofile,real_open,real_loadfile
  if not ok then failures[#failures+1]=name..': '..tostring(err) end
end
local function split(line)
  local out={};for part in (line:gsub('[\r\n]','')..','):gmatch('(.-),') do out[#out+1]=part end;return out
end
local function fixture(ai, external, absent)
  local f={output={},sent={},calls=0,loader_calls=0,perceive_calls=0}
  local cfg=real_dofile('config.lua')
  cfg.debug_log,cfg.debug_log_interval_frames=true,1
  local p={x=0,y=320,life=10,spellPoint=0,combo=0,currentCharge=0,currentChargeMax=0,
    chargeSpeed=10,speedFast=4,speedSlow=2,
    hitBodyRect={type=HitType.Rect,x=0,y=320,width=4,height=4},
    hitBodyCircle={type=HitType.Circle,x=0,y=320,radius=2},
    sensor={apiVersion=1,valid=true,state=0,protectionFrames=0,canCharge=true,
      chargeBlockFrames=0,baseScaleX=1,baseScaleY=1,moveScaleX=1,moveScaleY=1,
      poisonClouds={},timeScale=1,cutIn=false,chargeWarmupFrames=0}}
  f.side={player=p,bullets={},enemies={},exAttacks={},items={},chargeType=ChargeType.Slow}
  dofile=function(path)
    if path=='config.lua' then return cfg end
    local module=real_dofile(path)
    if path=='dodge.lua' then
      local choose,perceive=module.choose,module.perceive
      module.perceive=function(side,settings)
        f.perceive_calls=f.perceive_calls+1
        return perceive(side,settings)
      end
      module.choose=function(side,state,settings,intent)
        f.calls=f.calls+1;f.effective=settings;f.state=state;f.visible=side
        local r=choose(side,state,settings,intent);f.movement=r;return r
      end
    end
    return module
  end
  io.open=function(path,mode)
    if path=='runtime-settings.lua' then
      if external then return real_open(external,mode) end
      if absent then return nil,'fixture absent' end
      return {close=function() end}
    end
    if mode=='r' then return nil,'no existing in-memory CSV' end
    check(mode=='w' and path:match('^ai_debug_.+%.csv$')~=nil,'unexpected file write')
    return {write=function(_,s) f.output[#f.output+1]=s end,flush=function()end,close=function()end}
  end
  loadfile=function(path)
    if path=='runtime-settings.lua' then
      f.loader_calls=f.loader_calls+1
      if external then return real_loadfile(external) end
      return function() return {seconds=0,ai=ai} end
    end
    return real_loadfile(path)
  end
  game_sides={[2]=f.side};sendKeys=function(mask)f.sent[#f.sent+1]=mask end
  local real_print=print;print=function()end
  local loaded,load_error=pcall(real_dofile,'main.lua');print=real_print
  if not loaded then error(load_error) end
  dofile,io.open,loadfile=real_dofile,real_open,real_loadfile
  f.main=main
  function f.step()
    game_sides={[2]=f.side};sendKeys=function(mask)f.sent[#f.sent+1]=mask end
    f.main()
    if #f.output<2 then return nil end
    local header,values,row=split(f.output[1]),split(f.output[#f.output]),{}
    eq(#values,#header,'CSV values match header')
    for i,name in ipairs(header) do row[name]=values[i] end
    return row
  end
  return f
end
local function settings(ai,expected)
  local f=fixture(ai);local row=f.step()
  eq(f.loader_calls,1,'real main runtime loader is used once')
  eq(f.calls,1,'real choose runs once');eq(f.perceive_calls,1,'main shares perception before planners')
  for key,value in pairs(expected or {}) do
    local actual
    if key=='capacity' then actual=f.effective.attention.tracked_threat
    elseif key=='recovery' then actual=f.effective.attention.threat_per_second
    elseif key=='enabled' then actual=f.effective.attention.enabled
    else actual=f.effective[key] end
    eq(actual,value,'effective '..key)
  end
  return f,row
end

scenario('absent settings preserve safe defaults',function()
  local f=fixture(nil,nil,true);local row=f.step()
  eq(f.loader_calls,0,'no generated file means defaults');eq(f.effective.move_change_budget,6,'default movement')
  eq(f.effective.vision_radius,448/3,'default vision');eq(f.effective.attention.tracked_threat,26,'default capacity')
  eq(f.effective.attention.threat_per_second,19,'default recovery');eq(row.attention_enabled,'true','default attention on')
end)
scenario('new explicit fields override a named tier and reach real choose',function()
  local f,row=settings({difficulty='human300',move_change_budget=8,vision_radius=220,
    attention_capacity=76,attention_recovery_per_second=91},
    {move_change_budget=8,vision_radius=220,capacity=76,recovery=91,enabled=true})
  eq(tonumber(row.move_change_budget),8,'CSV movement config');eq(tonumber(row.vision_radius),220,'CSV vision')
  eq(tonumber(row.attention_capacity_config),76,'CSV capacity');eq(tonumber(row.attention_recovery_config),91,'CSV recovery')
end)
scenario('inclusive minimum and maximum boundaries',function()
  settings({move_change_budget=1,vision_radius=16,attention_capacity=1,attention_recovery_per_second=0.1},
    {move_change_budget=1,vision_radius=16,capacity=1,recovery=0.1})
  settings({move_change_budget=10,vision_radius=640,attention_capacity=256,attention_recovery_per_second=256},
    {move_change_budget=10,vision_radius=640,capacity=256,recovery=256})
end)
scenario('noninteger capacity recovery and radius are permitted',function()
  settings({attention_capacity=1.5,attention_recovery_per_second=0.25,vision_radius=16.5},
    {capacity=1.5,recovery=0.25,vision_radius=16.5})
end)
scenario('named presets ignore old leftover capacity fields',function()
  settings({difficulty='human480',tracked_threat=1,threat_per_second=0.1},{capacity=55,recovery=40})
  settings({difficulty='veteran',tracked_threat=2,threat_per_second=2},{capacity=40,recovery=30})
end)
scenario('custom accepts legacy fields but new explicit fields win',function()
  settings({difficulty='custom',tracked_threat=7,threat_per_second=8},{capacity=7,recovery=8})
  settings({difficulty='custom',tracked_threat=7,threat_per_second=8,
    attention_capacity=60,attention_recovery_per_second=70},{capacity=60,recovery=70})
end)
scenario('mech and disabled attention retain vision and movement settings',function()
  local f,row=settings({difficulty='mech',move_change_budget=2,vision_radius=42,
    attention_capacity=100,attention_recovery_per_second=200},
    {enabled=false,move_change_budget=2,vision_radius=42,capacity=100,recovery=200})
  eq(row.attention_enabled,'false','mech is still off after numeric overrides')
  settings({difficulty='human300',enabled=false,vision_radius=55,move_change_budget=3},
    {enabled=false,vision_radius=55,move_change_budget=3,capacity=40,recovery=30})
  settings({difficulty='mech',enabled=true},{enabled=true}) -- retained explicit-switch compatibility
end)
scenario('invalid movement values fall back without changing the preset',function()
  for _,bad in ipairs({0,11,3.5,'5',true,0/0,math.huge,-math.huge}) do
    settings({difficulty='human300',move_change_budget=bad},{move_change_budget=6,capacity=40,recovery=30})
  end
end)
scenario('invalid vision values fall back to one-third field height',function()
  for _,bad in ipairs({0,15.99,640.01,-1,'200',true,0/0,math.huge,-math.huge}) do
    settings({vision_radius=bad},{vision_radius=448/3})
  end
end)
scenario('invalid explicit attention values cannot erase named settings',function()
  for _,bad in ipairs({0,0.99,256.01,-1,'26',true,0/0,math.huge,-math.huge}) do
    settings({difficulty='human300',attention_capacity=bad},{capacity=40,recovery=30})
  end
  for _,bad in ipairs({0,0.09,256.01,-1,'19',true,0/0,math.huge,-math.huge}) do
    settings({difficulty='human300',attention_recovery_per_second=bad},{capacity=40,recovery=30})
  end
end)
scenario('missing and malformed ai blocks keep defaults',function()
  settings(nil,{move_change_budget=6,vision_radius=448/3,capacity=26,recovery=19})
  settings(false,{move_change_budget=6,vision_radius=448/3,capacity=26,recovery=19})
  settings('human300',{capacity=26,recovery=19})
  settings({difficulty='not-a-preset'},{capacity=26,recovery=19})
end)
scenario('CSV appends thirteen fields after the existing 149 columns',function()
  local f=settings({});local header=split(f.output[1])
  eq(#header,162,'3.3.0 CSV width');eq(header[1],'frame','first original column')
  eq(header[134],'hits_total','pre-3.2.5 prefix boundary');eq(header[135],'round_id','round diagnostics position')
  eq(header[149],'c2_ready_updates','existing 149-column suffix')
  local suffix={'vision_radius','vision_visible_bullets','vision_hidden_bullets','vision_visible_enemies',
    'vision_hidden_enemies','vision_visible_ex','vision_hidden_ex','vision_visible_poison','vision_hidden_poison',
    'move_change_budget','attention_capacity_config','attention_recovery_config','attention_enabled'}
  for i,name in ipairs(suffix) do eq(header[149+i],name,'appended field '..i) end
end)

if RUNTIME_SETTINGS_FIXTURE then
  scenario('real launcher-generated runtime file controls main and its timeout',function()
    local expected=assert(real_loadfile(RUNTIME_SETTINGS_FIXTURE))()
    check(type(expected)=='table' and expected.seconds==1,'end-to-end fixture must request one second')
    local f=fixture(nil,RUNTIME_SETTINGS_FIXTURE)
    f.side.bullets={{id=91,enabled=true,isErasable=false,x=0,y=310,vx=0,vy=1.5,
      hitBody={type=HitType.Circle,x=0,y=310,radius=2}}}
    f.step()
    eq(f.loader_calls,1,'main parsed the actual generated file')
    local mapping={move_change_budget='move_change_budget',vision_radius='vision_radius',
      attention_capacity='tracked_threat',attention_recovery_per_second='threat_per_second'}
    for field,destination in pairs(mapping) do
      if expected.ai and expected.ai[field]~=nil then
        local target=(field=='move_change_budget' or field=='vision_radius') and f.effective or f.effective.attention
        eq(target[destination],expected.ai[field],'JSON-generated '..field..' reaches choose')
      end
    end
    for _=2,60 do f.step() end
    eq(f.calls,60,'real planners remain live for all sixty allowed callbacks')
    check(f.sent[1]~=0,'fixture must issue real avoidance input before expiry')
    f.step();eq(f.calls,60,'sixty-first callback bypasses all planners')
    eq(f.sent[#f.sent],0,'sixty-first callback releases keys')
    for _=1,3 do f.step();eq(f.sent[#f.sent],0,'timeout remains latched') end
  end)
end

dofile,io.open,loadfile=real_dofile,real_open,real_loadfile
for _,m in ipairs(failures) do print('FAIL '..m) end
assert(#failures==0,string.format('player settings: %d/%d scenarios failed',#failures,cases))
print(string.format('player settings PASS: %d scenarios, %d assertions',cases,checks))
