-- 3.7 rescue uses prior perceived pressure, real stock and the existing C2
-- pipeline. Explicit native snapshots below never promise energy or immunity.
local bloom = dofile('bloom.lua')
local checks, cases, failures = 0, 0, {}
local function check(v, message) checks=checks+1; assert(v,message) end
local function copy(t) local r={}; for k,v in pairs(t) do r[k]=type(v)=='table' and copy(v) or v end; return r end
local function scenario(name,fn) cases=cases+1;local ok,e=pcall(fn);if not ok then failures[#failures+1]=name..': '..tostring(e) end end
local low={rescue_observed=true,rescue_routes_total=9,rescue_routes_safe=9,rescue_known_ttc=-1,
  attention_load=10,attention_budget=120,attention_credit=120,attention_skipped=0}
local high=copy(low); high.attention_load=120;high.attention_credit=10;high.attention_skipped=4
local function fixture()
  local cfg=copy(bloom.defaults);cfg.max_c_interval_frames=100000;cfg.bloom_c2_interval_frames=100000
  return {cfg=cfg,state={},world={player={x=0,y=320,life=10,currentCharge=0,currentChargeMax=300,
    chargeSpeed=4,sensor={valid=true,state=0,protectionFrames=0,canCharge=true,canPressZ=true,
      c1ActionActive=false,cutIn=false,timeScale=1,chargeWarmupFrames=0,followupApiVersion=1}},
    bullets={},enemies={},exAttacks={}},obs={valid=true,counts={field_erasable=0},has_ignition=false,c2={}}}
end
local function tick(f,feedback)
  if feedback then bloom.feedback(f.state,feedback,f.cfg) end
  local stock=f.world.player.currentChargeMax
  local r=bloom.update(f.world,f.state,f.cfg,f.obs)
  check(f.world.player.currentChargeMax==stock,'must not invent energy')
  check((r.target_level or 0)<=2 and r.press_x==nil and r.use_x==nil,'C2 only, no X input')
  return r
end
local function start(f)
  local releases=f.state.release_c2 or 0
  tick(f,high);tick(f,high);local r=tick(f,high)
  check(r.rescue_state=='charging' and r.target_level==2 and r.press_z,'third coarse pressure starts C2')
  check((f.state.release_c2 or 0)==releases,'preparation is not release')
  return r
end
local function release(f)
  f.world.player.currentCharge=200
  local r=tick(f,high)
  check(r.phase=='release' and r.reason=='rescue_release_c2' and not r.press_z,'release at first observed 200')
  check(r.rescue_state=='await_confirm' and not r.rescue_confirmed,'request grants no protection')
  return r
end
local function confirm(f)
  local p=f.world.player; p.currentCharge=0;p.currentChargeMax=100
  p.sensor.state=3;p.sensor.protectionFrames=40;p.sensor.c1ActionActive=true;p.sensor.c1ActionAge=0
  p.sensor.canCharge=false
  local r=tick(f,high)
  check(r.rescue_confirmed and r.rescue_state=='recover','real charge reset plus native protection/action confirms')
  return r
end

scenario('no feedback retains original behavior',function()
  local f=fixture();for i=1,20 do check(tick(f).rescue_state=='idle','no new contract means no rescue') end
end)
scenario('low pressure never buys empty C2',function()
  local f=fixture();for i=1,120 do local r=tick(f,low);check(r.rescue_attempts==0,'low pressure cannot rescue') end
end)
scenario('coarse overload precedes urgent blind alarm',function()
  local f=fixture();local r=start(f)
  check(r.rescue_reason=='attention_budget_low' and not f.state.attention_escape,'no legacy second six-frame gate')
  check(r.rescue_known_ttc==-1 and not r.rescue_late,'unknown blind geometry stays unknown')
end)
scenario('rich credit and no skipped targets are not overload',function()
  for _,kind in ipairs({'credit','skipped','budget'}) do
    local f=fixture();local m=copy(high)
    if kind=='credit' then m.attention_credit=30 elseif kind=='skipped' then m.attention_skipped=0 else m.attention_budget=0 end
    for i=1,8 do check(tick(f,m).rescue_attempts==0,'coarse needs budget/load/credit/skipped together') end
  end
end)
scenario('pressure must persist rather than accumulate disconnected blips',function()
  local f=fixture();for i=1,10 do tick(f,high);tick(f,high);check(tick(f,low).rescue_attempts==0,'two-frame blips do not accumulate') end
end)
scenario('unfunded cannot borrow expected chain energy',function()
  local f=fixture(); f.world.player.currentChargeMax=199.99
  for i=1,8 do check(tick(f,high).rescue_attempts==0,'real 200 threshold') end
  f.world.player.currentChargeMax=200;check(tick(f,high).rescue_state=='charging','real stock now enables rescue')
end)
scenario('known no-route risk starts immediately',function()
  local f=fixture();local m=copy(low);m.rescue_routes_safe=0;m.rescue_known_ttc=8
  local r=tick(f,m);check(r.rescue_state=='charging' and r.rescue_late,'known imminent risk triggers without double wait')
  check(r.rescue_known_ttc==7 and r.rescue_ready_updates==50,'prior callback consumed, charge time distinct')
end)
scenario('narrow route uses sustained perceived risk',function()
  local f=fixture();local m=copy(low);m.rescue_routes_safe=2;m.rescue_known_ttc=-1
  check(tick(f,m).rescue_attempts==0,'narrow alone first sample waits')
  tick(f,m);check(tick(f,m).rescue_reason=='known_routes_narrow','three fresh narrow samples')
  check(f.state.rescue_known_ttc==-1,'selected safe route does not need a collision TTC')
end)
scenario('small cap pool entirely safe is not route narrowing',function()
  for _,total in ipairs({1,2,3}) do
    local f=fixture();local m=copy(low);m.rescue_routes_total=total;m.rescue_routes_safe=total
    for i=1,8 do check(tick(f,m).rescue_attempts==0,'relative safe fraction prevents false narrowing') end
  end
end)
scenario('unidentified TTC cannot act as known route risk',function()
  local f=fixture();local m=copy(low);m.rescue_routes_safe=0;m.attention_nearest_blind=0
  for i=1,8 do check(tick(f,m).rescue_attempts==0,'never reads nearest blind TTC') end
end)
scenario('safe routes and unknown future are not pressure',function()
  local f=fixture();local m=copy(low);m.rescue_known_ttc=5
  for i=1,8 do check(tick(f,m).rescue_attempts==0,'nine safe alternatives cannot rescue on TTC alone') end
end)
scenario('slow game time converts observed TTC to callback units',function()
  local f=fixture();f.world.player.sensor.timeScale=0.5
  local m=copy(low);m.rescue_routes_safe=0;m.rescue_known_ttc=8
  local r=tick(f,m);check(r.rescue_known_ttc==15 and r.rescue_ready_updates==100,'same units for lead and known collision')
end)
scenario('charge latch survives short relief and missing seed',function()
  local f=fixture();start(f)
  for _,charge in ipairs({40,80,120,160,199}) do
    f.world.player.currentCharge=charge;local r=tick(f,low)
    check(r.rescue_state=='charging' and r.press_z and r.target_level==2,'relief cannot cancel latched C2')
  end
  release(f);check(f.state.release_c1==nil,'never drops a partial C1 under relief')
end)
scenario('charge gate and active C1 prevent new rescue',function()
  for _,gate in ipairs({'canCharge','c1ActionActive','valid'}) do
    local f=fixture();f.world.player.sensor[gate]=gate=='c1ActionActive'
    for i=1,8 do check(tick(f,high).rescue_attempts==0,'native action gate must be open') end
  end
end)
scenario('warmup included and ready never means invincible',function()
  local f=fixture();f.world.player.sensor.chargeWarmupFrames=11
  local r=start(f);check(r.rescue_ready_updates==61 and not r.rescue_confirmed,'warmup and charging distinct from confirmation')
end)
scenario('held fresh C1 promotes only at actual funding',function()
  local f=fixture();f.state={target_level=1,fresh_charge=true,press_z=true,last_life=10}
  f.world.player.currentCharge=80;f.world.player.currentChargeMax=199
  tick(f,high);tick(f,high);check(tick(f,high).rescue_attempts==0,'held C1 lacks actual C2 stock')
  f.world.player.currentChargeMax=200;f.world.player.currentCharge=120
  local r=tick(f,high);check(r.target_level==2 and r.rescue_state=='charging','fresh held C1 promoted without release')
  check((f.state.release_c1 or 0)==0,'promotion preserves charge')
end)
scenario('stale full charge cannot be mistaken for a new C2',function()
  local f=fixture();f.world.player.currentCharge=200
  for i=1,8 do local r=tick(f,high);check(r.rescue_attempts==0 and not r.press_z,'wait for actual charge reset') end
  f.world.player.currentCharge=0;check(tick(f,high).rescue_state=='charging','fresh reset now accepted')
end)
scenario('C2 releases promptly rather than improve seed shape',function()
  local f=fixture();start(f)
  f.obs.c2={has_ignition=true,timing={valid=true,improving=true},chain_score=999}
  f.world.player.currentCharge=200;local r=tick(f,high)
  check(r.phase=='release' and not r.press_z,'do not wait into C3 band')
end)
scenario('runtime gate can delay release without false success',function()
  local f=fixture();start(f);f.world.player.currentCharge=200;f.world.player.sensor.canCharge=false
  local r=tick(f,high);check(r.reason=='rescue_charge_gate' and r.rescue_releases==0 and not r.rescue_confirmed,'blocked release not counted')
  f.world.player.sensor.canCharge=true;release(f)
end)
scenario('stock loss below C1 cancels and above C1 exits safely',function()
  for _,charge in ipairs({60,120}) do
    local f=fixture();start(f);f.world.player.currentCharge=charge;f.world.player.currentChargeMax=150
    local r=tick(f,high);check(not r.press_z and r.rescue_state=='cooldown','lost real stock ends rescue')
    check((f.state.release_c1 or 0)==(charge>=100 and 1 or 0),'partial mature charge is C1, never fabricate C2')
  end
end)
scenario('stalled preparation has bounded timeout',function()
  local f=fixture();f.cfg.rescue_charge_timeout_frames=4;start(f)
  for i=1,3 do check(tick(f,high).rescue_state=='charging','before timeout') end
  local r=tick(f,high);check(r.rescue_state=='cooldown' and not r.press_z and r.reason=='rescue_cancel_charge_timeout','timeout cancels unmatured preparation')
end)
scenario('post-entry blocked charge stops holding after bounded timeout',function()
  for _,charge in ipairs({0,120,200}) do
    local f=fixture();f.cfg.rescue_charge_timeout_frames=4;start(f)
    f.world.player.currentCharge=charge;f.world.player.sensor.canCharge=false
    for i=1,3 do check(tick(f,high).press_z,'bounded charge gate wait') end
    local r=tick(f,high)
    check(not r.press_z and r.rescue_state=='cooldown' and r.reason=='rescue_stop_charge_gate_timeout','timeout can exit blocked branch')
    check(r.rescue_releases==0 and not r.rescue_confirmed and f.state.target_level==nil,'stop cannot claim confirmed harmless cancellation or C2 release')
  end
end)
scenario('protection tail uses same conservative whole-frame boundary as dodge',function()
  for _,frames in ipairs({1,1.5,2}) do
    local f=fixture();f.world.player.sensor.state=3;f.world.player.sensor.protectionFrames=frames
    local m=copy(low);m.rescue_routes_safe=0;m.rescue_known_ttc=5
    local r=tick(f,m)
    check((r.rescue_attempts==1)==(frames<2),'raw protection <=1 frame is not usable protection')
  end
end)
scenario('release requires observed reset and protection to confirm',function()
  local f=fixture();start(f);release(f)
  local r=tick(f,high);check(r.rescue_state=='await_confirm' and not r.rescue_confirmed,'stale full value is not a confirmation')
  f.world.player.currentCharge=0;r=tick(f,high);check(not r.rescue_confirmed,'reset alone does not grant invulnerability')
  confirm(f)
end)
scenario('unconfirmed release times out without spamming another C2',function()
  local f=fixture();start(f);release(f);f.world.player.currentCharge=0
  for i=1,8 do tick(f,high) end
  check(f.state.rescue_state=='cooldown' and not f.state.rescue_confirmed,'bounded confirmation timeout')
  for i=1,160 do tick(f,high) end
  check(f.state.rescue_attempts==1,'continuous low yield pressure cannot drain stock repeatedly')
end)
scenario('confirmed protection blocks reentry and stale pressure',function()
  local f=fixture();start(f);release(f);confirm(f);f.world.player.currentChargeMax=300
  for i=1,120 do check(tick(f,high).rescue_attempts==1,'protected phase cannot buy another rescue') end
  f.world.player.sensor.state=0;f.world.player.sensor.protectionFrames=0
  f.world.player.sensor.c1ActionActive=false;f.world.player.sensor.canCharge=true
  check(tick(f,high).rescue_pressure==0,'protection-exit frame cannot replay old feedback')
end)
scenario('low pressure after recovery rearms only after cooldown',function()
  local f=fixture();start(f);release(f);confirm(f)
  local s=f.world.player.sensor;s.state=0;s.protectionFrames=0;s.c1ActionActive=false;s.canCharge=true
  f.world.player.currentChargeMax=220
  for i=1,100 do tick(f,low) end
  check(f.state.rescue_attempts==1,'quiet recovery does not spend stock')
  start(f);check(f.state.rescue_attempts==2,'later real pressure can rescue again')
end)
scenario('confirmed full stock replacement supports continuing pressure',function()
  local f=fixture();start(f);release(f);confirm(f)
  local s=f.world.player.sensor;s.state=0;s.protectionFrames=0;s.c1ActionActive=false;s.canCharge=true
  f.world.player.currentChargeMax=250
  for i=1,100 do tick(f,high) end
  check(f.state.rescue_attempts==1,'partial recovery cannot spend another empty C2')
  f.world.player.currentChargeMax=300;check(tick(f,high).rescue_attempts==2,'observed full replacement and cooldown permit reentry')
end)
scenario('pause freezes charge plan but clears accumulated pre-pause danger',function()
  local f=fixture();tick(f,high);tick(f,high);f.world.player.sensor.cutIn=true
  check(tick(f,high).phase=='paused','cut-in pauses')
  f.world.player.sensor.cutIn=false;check(tick(f,high).rescue_attempts==0,'no stale trigger on resume')
  start(f);f.world.player.sensor.timeScale=0;local age=f.state.rescue_age
  for i=1,5 do check(tick(f,high).rescue_age==age,'time stop freezes timeout age') end
  f.world.player.sensor.timeScale=1;check(tick(f,low).rescue_state=='charging','owned C2 latch survives stop')
end)
scenario('hit and engine recovery interrupt without false confirmation',function()
  for _,mode in ipairs({'life','state'}) do
    local f=fixture();start(f);release(f)
    if mode=='life' then f.world.player.life=9 else f.world.player.sensor.state=2 end
    local r=tick(f,high);check(not r.rescue_confirmed and r.rescue_state=='cooldown','hit cannot count as C2 protection')
    check(f.state.target_level==nil and (f.state.rescue_pressure or 0)==0,'hit clears old charge and feedback')
  end
end)
scenario('round reset erases every rescue lock',function()
  local f=fixture();start(f);bloom.reset(f.state)
  check(next(f.state)==nil,'round reset clears rescue fields')
  check(tick(f,low).rescue_attempts==0,'new round inherits no pressure')
end)
scenario('poison alone adds no rescue trigger',function()
  local f=fixture();f.world.exAttacks={{type=5,x=0,y=320,radius=100}}
  for i=1,60 do check(tick(f,low).rescue_attempts==0,'poison presence is not a rescue pressure signal') end
end)
scenario('malformed extreme charge speed cannot overshoot into C3',function()
  local f=fixture();f.world.player.chargeSpeed=100
  for i=1,8 do check(tick(f,high).rescue_attempts==0,'unbounded per-update charge cannot start rescue') end
end)

if #failures>0 then error(table.concat(failures,'\n')) end
print(string.format('rescue_c2_test: PASS (%d scenarios, %d assertions)',cases,checks))
