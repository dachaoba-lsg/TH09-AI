-- 3.7 real main -> observer -> bloom -> dodge -> feedback integration.
-- Input snapshots are controlled fixtures, not an emulation of game damage,
-- charge physics, protection duration, or energy returned by a release.
HitType={Rect=0,Circle=1,RotatableRect=2}
ExAttackType={Medicine=16}
ChargeType={Slow=0,Charge=1}
local real_dofile,real_open,real_loadfile=dofile,io.open,loadfile
local checks,cases,failures=0,0,{}
local function check(ok,message) checks=checks+1;assert(ok,message) end
local function eq(actual,expected,message)
  check(actual==expected,message..': '..tostring(actual)..' ~= '..tostring(expected))
end
local function split(line)
  local values={}
  for value in (line:gsub('[\r\n]','')..','):gmatch('(.-),') do values[#values+1]=value end
  return values
end
local function scenario(name,run)
  cases=cases+1
  local ok,err=pcall(run)
  dofile,io.open,loadfile=real_dofile,real_open,real_loadfile
  if not ok then failures[#failures+1]=name..': '..tostring(err) end
end
local function player(character)
  return {character=character or 13,x=0,y=320,life=10,spellPoint=0,combo=0,
    currentCharge=0,currentChargeMax=300,chargeSpeed=10,speedFast=4,speedSlow=2,
    hitBodyRect={type=HitType.Rect,width=4,height=4},hitBodyCircle={type=HitType.Circle,radius=2},
    sensor={apiVersion=1,valid=true,state=0,protectionFrames=0,canCharge=true,
      chargeBlockFrames=0,chargeWarmupFrames=0,timeScale=1,cutIn=false,
      baseScaleX=1,baseScaleY=1,moveScaleX=1,moveScaleY=1,poisonClouds={}}}
end
local function bullet(id,x,y,radius)
  return {id=id,x=x,y=y,vx=0,vy=0,enabled=true,isErasable=true,
    hitBody={type=HitType.Circle,x=x,y=y,radius=radius or 3}}
end
local function fixture(ai,side,character)
  local f={output={},sent={},calls=0,feedback_calls=0}
  f.cfg=real_dofile('config.lua')
  f.cfg.debug_log,f.cfg.debug_log_interval_frames=true,1
  f.player=player(character)
  f.side={player=f.player,chargeType=ChargeType.Slow,bullets={},enemies={},exAttacks={}}
  f.other={player=player(9),chargeType=ChargeType.Slow,bullets={},enemies={},exAttacks={}}
  f.side_number=side or 2
  dofile=function(path)
    if path=='config.lua' then return f.cfg end
    local mod=real_dofile(path)
    if path=='bloom.lua' then
      local update,feedback=mod.update,mod.feedback
      mod.update=function(current,state,cfg,obs)
        f.bloom=state;f.obs=obs
        local plan=update(current,state,cfg,obs);f.plan=plan;return plan
      end
      mod.feedback=function(state,movement,cfg)
        f.feedback_calls=f.feedback_calls+1
        return feedback(state,movement,cfg)
      end
    elseif path=='dodge.lua' then
      local choose=mod.choose
      mod.choose=function(current,state,cfg,intent)
        f.state,f.effective,f.visible=state,cfg,current;f.calls=f.calls+1
        local movement=choose(current,state,cfg,intent)
        f.movement=movement;return movement
      end
    end
    return mod
  end
  io.open=function(path,mode)
    if path=='runtime-settings.lua' then return {close=function()end} end
    if mode=='r' then return nil end
    check(mode=='w' and path:match('^ai_debug_'),'unexpected fixture I/O')
    return {write=function(_,text)f.output[#f.output+1]=text end,flush=function()end,close=function()end}
  end
  loadfile=function(path)
    if path=='runtime-settings.lua' then return function()
      return {seconds=0,ai=ai or {difficulty='unlimited'}}
    end end
    return real_loadfile(path)
  end
  player_side=f.side_number
  game_sides={[f.side_number]=f.side,[3-f.side_number]=f.other}
  sendKeys=function(mask)f.sent[#f.sent+1]=mask end
  real_dofile('main.lua');f.main=main
  dofile,io.open,loadfile=real_dofile,real_open,real_loadfile
  f.header=split(f.output[1]);f.index={}
  for i,name in ipairs(f.header)do f.index[name]=i end
  function f.step()
    player_side=f.side_number
    game_sides={[f.side_number]=f.side,[3-f.side_number]=f.other}
    sendKeys=function(mask)f.sent[#f.sent+1]=mask end
    f.main()
    if #f.output<2 then return nil end
    local values,row=split(f.output[#f.output]),{}
    eq(#values,#f.header,'CSV row/header width')
    for i,name in ipairs(f.header)do row[name]=values[i]end
    f.row=row
    return row
  end
  return f
end

scenario('preset scan defaults and explicit legacy values reach real planner',function()
  for _,tier in ipairs({'human45','human200','human300','human480','custom','mech','unknown'})do
    local f=fixture({difficulty=tier});f.step()
    eq(f.effective.attention.plan_interval,6,'non-unlimited scan default '..tier)
    eq(f.effective.move_change_budget,6,'movement budget '..tier)
    check(math.abs(f.effective.vision_radius-448/3)<1e-9,'vision changed '..tier)
  end
  for _,tier in ipairs({'unlimited','infinite'})do
    local f=fixture({difficulty=tier});local row=f.step()
    eq(f.effective.attention.plan_interval,1,'unlimited scan default '..tier)
    eq(f.effective.attention.tracked_threat,120,'unlimited capacity '..tier)
    eq(f.effective.attention.threat_per_second,90,'unlimited recovery '..tier)
    eq(row.attention_plan_interval,'1','effective scan interval logged '..tier)
    f=fixture({difficulty=tier,plan_interval=6});f.step()
    eq(f.effective.attention.plan_interval,6,'old JSON explicit 6 must survive '..tier)
  end
  local f=fixture({difficulty='human200',plan_interval=1});f.step()
  eq(f.effective.attention.plan_interval,1,'human explicit interval override')
end)

local function blockRoutes(f)
  -- A known currently overlapping hit shape is a deterministic all-routes
  -- blocked fixture; it deliberately makes no prediction about actual hits.
  f.side.bullets={bullet(71,0,320,20)}
end
local function narrowRoutes(f)
  local shapes={{1,0,0,0,310,240,2},{2,0,0,0,330,240,2},{3,2,0,-20,320,4,40}}
  for _,s in ipairs(shapes)do
    f.side.bullets[#f.side.bullets+1]={id=s[1],vx=s[2],vy=s[3],x=s[4],y=s[5],
      enabled=true,isErasable=true,
      hitBody={type=HitType.Rect,x=s[4],y=s[5],width=s[6],height=s[7]}}
  end
end
local function startRescue(f)
  blockRoutes(f)
  f.step()
  check(f.movement.rescue_observed==true,'real dodge did not publish rescue evidence')
  eq(f.movement.rescue_routes_safe,0,'blocked fixture unexpectedly has a known safe route')
  eq(f.movement.rescue_known_ttc,0,'known collision must come from actual scoring')
  check(f.plan.rescue_state~='charging','first callback used future dodge feedback')
  eq(f.row.rescue_known_ttc,'-1','first callback invented previous-feedback timing')
  eq(f.row.rescue_route_ttc,'0','current route timing was not logged separately')
  eq(#f.header,197,'rescue CSV width')
  eq(f.header[182],'time_scale','3.6.1 CSV prefix boundary changed')
  eq(f.header[183],'rescue_state','rescue columns must append after the existing prefix')
  for _=1,4 do
    f.step()
    if f.plan.rescue_state=='charging' then break end
  end
  eq(f.plan.rescue_state,'charging','known blocked routes did not start funded rescue')
  eq(f.plan.target_level,2,'rescue did not use existing C2 target')
  check(f.plan.press_z==true and f.sent[#f.sent]%2==1,'rescue must reach actual Z output')
  return f
end

scenario('calm fields and unseen threats do not spend emergency stock',function()
  for _,ai in ipairs({{difficulty='human45'},{difficulty='human200'},{difficulty='unlimited'},
      {difficulty='mech'},{difficulty='unlimited',attention_capacity=1,attention_recovery_per_second=0.1}})do
    local f=fixture(ai)
    -- This fast bullet could reach the player soon, but its current body is
    -- outside the shared circle. It may not leak through a rescue TTC check.
    local hidden=bullet(99,0,100,3);hidden.vy=30;f.side.bullets={hidden}
    for _=1,20 do
      f.step()
      check(f.plan.rescue_state~='charging','hidden/calm field invented an emergency')
      eq(f.movement.rescue_known_ttc,-1,'hidden exact collision time leaked')
      eq(f.plan.release_c2,0,'calm rescue spent a C2')
      eq(#f.visible.bullets,0,'fixture threat was not hidden')
    end
  end
end)

scenario('funded rescue uses real feedback and both AI sides without role special casing',function()
  for _,side in ipairs({1,2})do
    for _,role in ipairs({0,9,13})do
      local f=startRescue(fixture({difficulty='unlimited'},side,role))
      eq(f.feedback_calls,f.calls,'each dodge result feeds policy exactly once')
      eq(f.row.ai_side,tostring(side),'actual side metadata')
      eq(f.row.ai_character,tostring(role),'actual character metadata')
      eq(f.row.rescue_state,'charging','CSV missed rescue entry')
      eq(f.row.rescue_late,'true','already-colliding emergency must report late preparation')
      check(f.row.rescue_reason and #f.row.rescue_reason>0,'CSV lacks entry reason')
      f.player.currentCharge=190;f.step()
      check(f.plan.press_z==true and f.plan.rescue_state=='charging','C2 did not stay committed before 200')
      f.player.currentCharge=200;f.step()
      check(f.plan.press_z==false,'mature rescue did not release Z')
      eq(f.plan.release_c2,1,'one observed mature charge means one C2 release request')
      eq(f.plan.rescue_state,'await_confirm','release falsely assumed successful protection')
      check(f.plan.rescue_confirmed~=true,'release request was treated as native confirmation')
      for _=1,3 do f.step();eq(f.plan.release_c2,1,'same mature charge requested repeated C2')end
    end
  end
end)

scenario('sustained acquisition pressure prepares before the legacy urgent blind delay',function()
  local f=fixture({difficulty='unlimited',attention_capacity=1,attention_recovery_per_second=0.1})
  for i=1,12 do
    local b=bullet(100+i,(i-6.5)*3,280,2);b.vy=1.5
    f.side.bullets[#f.side.bullets+1]=b
  end
  for frame=1,4 do
    f.step()
    check(f.movement.attention_load>=1 and f.movement.attention_skipped>0,'fixture did not exhaust acquisition')
    eq(f.movement.rescue_known_ttc,-1,'selected known route should remain clear')
    check(f.movement.attention_escape~=true,'fixture unexpectedly hit the legacy overload escape')
    if frame<4 then check(f.plan.rescue_state~='charging','coarse pressure ignored entry dwell')end
  end
  eq(f.plan.rescue_state,'charging','early budget pressure waited for the legacy escape layers')
  eq(f.plan.rescue_reason,'attention_budget_low','coarse pressure got an exact hidden-TTC reason')
end)

scenario('a real narrow safe corridor prepares without inventing collision timing',function()
  local f=fixture();narrowRoutes(f)
  local preceding_narrow=0
  local entered=false
  for _=1,15 do
    f.step()
    eq(f.movement.rescue_known_ttc,-1,'narrow safe path invented selected collision timing')
    eq(f.movement.attention_skipped,0,'narrow fixture accidentally became an acquisition-pressure test')
    if f.plan.rescue_state=='charging' then
      eq(preceding_narrow,3,'narrow rescue must consume three consecutive real narrow observations')
      eq(f.plan.rescue_reason,'known_routes_narrow','narrow corridor did not select the intended cause')
      eq(f.plan.rescue_known_ttc,-1,'policy used hidden or rejected-route exact timing')
      check(f.plan.rescue_late~=true,'safe selected route was advertised as a timed incoming hit')
      check(f.plan.press_z==true,'narrow corridor preparation did not reach Z output')
      entered=true;break
    end
    local total,safe=f.movement.rescue_routes_total,f.movement.rescue_routes_safe
    if total>=3 and safe>0 and safe<=2 and safe*3<=total then
      preceding_narrow=math.min(3,preceding_narrow+1)
    else preceding_narrow=0 end
  end
  check(entered,'reachable narrow corridor never prepared C2 under normal movement-cap settings')
end)

scenario('two fully safe cap-constrained routes are not treated as a narrow trapped corridor',function()
  local f=fixture();narrowRoutes(f)
  f.step()
  eq(f.movement.rescue_routes_total,18,'initial unrestricted pool fixture changed')
  eq(f.movement.rescue_routes_safe,2,'initial narrow geometry changed')
  -- The actual move chosen above establishes the existing five-update dwell.
  -- During it, both eligible fast/slow right routes are safe. No state or
  -- feedback is fabricated to obtain this two-route pool.
  for _=1,4 do
    f.step()
    eq(f.movement.rescue_routes_total,2,'real direction dwell did not constrain the pool')
    eq(f.movement.rescue_routes_safe,2,'the two eligible choices should both be safe')
    eq(f.movement.rescue_known_ttc,-1,'safe cap pool invented timing')
    check(f.plan.rescue_state~='charging','small entirely-safe pool triggered rescue')
  end
  eq(f.plan.rescue_pressure,0,'entirely-safe cap pool kept accumulating narrow-route pressure')
end)

scenario('actual charge reset and protection confirm rescue and block repeated empty cycles',function()
  local f=startRescue(fixture())
  f.player.sensor.followupApiVersion=1
  f.player.sensor.canPressZ=true;f.player.sensor.c1ActionActive=false
  f.player.sensor.c1ActionAge=0
  f.player.currentCharge=200;f.step()
  eq(f.plan.rescue_state,'await_confirm','missing release observation state')
  f.player.currentCharge=0;f.player.currentChargeMax=100
  local sensor=f.player.sensor
  sensor.state=3;sensor.protectionFrames=50
  sensor.c1ActionActive=true;sensor.c1ActionAge=1;sensor.canPressZ=false
  f.step()
  eq(f.plan.rescue_state,'recover','native protection/reset did not confirm rescue')
  check(f.plan.rescue_confirmed==true,'confirmed protection was not recorded')
  for frame=1,10 do
    sensor.protectionFrames=50-frame;sensor.c1ActionAge=frame+1;f.step()
    eq(f.plan.release_c2,1,'protected recovery repeated the release')
    check(f.plan.rescue_state~='charging','protection established a new rescue')
  end
  sensor.state=0;sensor.protectionFrames=0;sensor.c1ActionActive=false;sensor.canPressZ=true
  -- Enough stock for another C2 is not proof that the spent 300-stock cycle
  -- has been recovered; remain below the original release stock.
  f.player.currentChargeMax=200
  for _=1,110 do
    f.step();eq(f.plan.release_c2,1,'persistent pressure caused another empty emergency')
    eq(f.plan.rescue_attempts,1,'same unrecovered emergency began another charge')
    check(f.plan.rescue_state~='charging','unrecovered stock rearmed the rescue')
  end
end)

scenario('a charge gate that closes after entry cannot hold emergency charge forever',function()
  local f=startRescue(fixture())
  f.player.currentCharge=50;f.player.sensor.canCharge=false
  f.player.sensor.chargeBlockFrames=300
  for _=1,185 do f.step()end
  check(f.plan.rescue_state~='charging','post-entry charge gate bypassed the bounded charge wait')
  check(f.plan.press_z~=true,'post-entry charge gate left unbounded held Z below C1')
  eq(f.plan.release_c2,0,'blocked incomplete charge became a C2')
end)

scenario('a hit interrupts pending rescue without becoming a release confirmation',function()
  for _,awaiting in ipairs({false,true})do
    local f=startRescue(fixture())
    if awaiting then f.player.currentCharge=200;f.step()end
    f.player.life=6;f.player.currentCharge=0;f.player.sensor.state=1
    f.step()
    check(f.plan.rescue_state~='charging','hit preserved the pending charge')
    check(f.plan.rescue_confirmed~=true,'hit recovery was treated as rescue success')
    check(f.plan.press_z~=true,'hit recovery kept a rescue input')
    local requests=f.plan.release_c2
    f.player.sensor.state=0;f.side.bullets={};f.step()
    check(f.plan.rescue_state~='charging','hit recovery replayed the old threat')
    eq(f.plan.release_c2,requests,'hit recovery replayed an old release')
  end
end)

scenario('unfunded and charge-blocked known danger cannot acquire a C2',function()
  for _,stock in ipairs({0,99,199.9})do
    local f=fixture();f.player.currentChargeMax=stock;blockRoutes(f)
    for _=1,8 do f.step();check(f.plan.rescue_state~='charging','unfunded rescue started')end
    eq(f.plan.release_c2,0,'unfunded rescue released C2')
  end
  local f=fixture();f.player.sensor.canCharge=false;f.player.sensor.chargeBlockFrames=30;blockRoutes(f)
  for _=1,8 do f.step();check(f.plan.rescue_state~='charging','blocked charge became a rescue')end
  eq(f.plan.release_c2,0,'charge block ignored')
end)

scenario('pause recovery faults and new rounds discard previous emergency evidence',function()
  for _,kind in ipairs({'cutin','frozen','recovering','round','sensor','charge_mode'})do
    local f=fixture();blockRoutes(f);f.step()
    eq(f.movement.rescue_routes_safe,0,'missing initial dangerous feedback')
    f.side.bullets={}
    if kind=='cutin' then f.player.sensor.cutIn=true
    elseif kind=='frozen' then f.player.sensor.timeScale=0
    elseif kind=='recovering' then f.player.sensor.state=1
    elseif kind=='round' then f.player.sensor.state=5
    elseif kind=='sensor' then f.player.sensor.valid=false
    else f.side.chargeType=ChargeType.Charge end
    f.step()
    if kind=='sensor' or kind=='charge_mode' then eq(f.sent[#f.sent],0,'fault must release all inputs')end
    f.player.sensor.cutIn=false;f.player.sensor.timeScale=1
    f.player.sensor.state=0;f.player.sensor.valid=true;f.side.chargeType=ChargeType.Slow
    f.step()
    check(f.plan.rescue_state~='charging','stale rescue after '..kind)
    eq(f.plan.release_c2,0,'stale C2 release after '..kind)
    eq(f.plan.rescue_pressure,0,'old pressure survived '..kind)
  end
end)

dofile,io.open,loadfile=real_dofile,real_open,real_loadfile
for _,failure in ipairs(failures)do print('FAIL '..failure)end
assert(#failures==0,string.format('rescue integration: %d/%d cases failed',#failures,cases))
print(string.format('rescue_integration_test: PASS (%d cases / %d checks; real main and feedback, no game)',cases,checks))
