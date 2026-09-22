-- 3.3.0 shared-circle integration. The real main, observer, bloom, dodge and
-- geometry run together. Wrappers only capture arguments/results; I/O and key
-- output are in memory. No synthetic visibility or collision result is used.
HitType={Rect=0,Circle=1,RotatableRect=2}
ExAttackType={Medicine=16}
ChargeType={Slow=0,Charge=1}
player_side=2
local real_dofile,real_open,real_loadfile=dofile,io.open,loadfile
local checks,cases,failures=0,0,{}
local function check(v,m) checks=checks+1;assert(v,m) end
local function eq(a,b,m) check(a==b,m..': '..tostring(a)..' ~= '..tostring(b)) end
local function scenario(name,fn)
  cases=cases+1;local ok,err=pcall(fn)
  dofile,io.open,loadfile=real_dofile,real_open,real_loadfile
  if not ok then failures[#failures+1]=name..': '..tostring(err) end
end
local function copy(t)
  if type(t)~='table' then return t end
  local r={};for k,v in pairs(t)do r[k]=copy(v)end;return r
end
local function unchanged(a,b,path)
  check(type(a)==type(b),'native snapshot type changed at '..path)
  if type(a)~='table' then eq(a,b,'native snapshot value changed at '..path);return end
  for k,v in pairs(a)do unchanged(v,b[k],path..'.'..tostring(k))end
  for k in pairs(b)do check(a[k]~=nil,'native snapshot gained key '..path..'.'..tostring(k))end
end
local function split(line)
  local out={};for v in (line:gsub('[\r\n]','')..','):gmatch('(.-),')do out[#out+1]=v end;return out
end
local function circle(id,x,y,vx,vy,erasable)
  return {id=id,enabled=true,hittable=true,isErasable=erasable~=false,x=x,y=y,vx=vx or 0,vy=vy or 0,
    hitBody={type=HitType.Circle,x=x,y=y,radius=2}}
end
local function enemy(id,x,y)
  return {id=id,enabled=true,x=x,y=y,vx=0,vy=0,isSpirit=false,isActivatedSpirit=false,
    isBoss=false,isLily=false,isPseudoEnemy=false,
    hitBody={type=HitType.Circle,x=x,y=y,radius=4}}
end
local function beam(id,x)
  return {id=id,enabled=true,hittable=true,x=x,y=0,vx=0,vy=0,
    hitBody={type=HitType.RotatableRect,x=x,y=0,width=448,height=4,angle=math.pi/2}}
end
local function cloud(x,y,r)
  return {x=x,y=y,radius=r,age=100,active=true,framesLeft=200}
end
local function fixture(ai)
  local f={output={},sent={},sequence={}}
  local cfg=real_dofile('config.lua');cfg.debug_log,cfg.debug_log_interval_frames=true,1
  local p={x=0,y=320,character=0,life=10,spellPoint=0,combo=0,currentCharge=0,currentChargeMax=0,
    chargeSpeed=10,speedFast=4,speedSlow=2,
    hitBodyRect={type=HitType.Rect,x=0,y=320,width=4,height=4},
    hitBodyCircle={type=HitType.Circle,x=0,y=320,radius=2},
    sensor={apiVersion=1,valid=true,state=0,protectionFrames=0,canCharge=true,canPressZ=true,
      chargeBlockFrames=0,baseScaleX=1,baseScaleY=1,moveScaleX=1,moveScaleY=1,
      poisonClouds={},timeScale=1,cutIn=false,chargeWarmupFrames=0,
      c1ActionActive=false,commonWavesValid=true,commonWaves={},
      opponentApiVersion=1,opponent={valid=true,chargeCurrent=0,chargeMax=400,chargeSpeed=10,
        state=0,protectionFrames=0,life=10,spellPoint=0,combo=0}}}
  f.player=p;f.side={player=p,bullets={},enemies={},exAttacks={},items={},chargeType=0,metadata='native-preserved'}
  dofile=function(path)
    if path=='config.lua' then return cfg end
    local module=real_dofile(path)
    if path=='dodge.lua' then
      local perceive,choose=module.perceive,module.choose
      module.perceive=function(side,settings)
        f.sequence[#f.sequence+1]='perceive'
        local visible,stats=perceive(side,settings);f.perceived,f.vision=visible,stats;return visible,stats
      end
      module.choose=function(side,state,settings,intent)
        f.sequence[#f.sequence+1]='choose';f.dodge_side,f.state,f.settings=side,state,settings
        local r=choose(side,state,settings,intent);f.movement=r;return r
      end
    elseif path=='bloom_observer.lua' then
      local observe=module.observe
      module.observe=function(side,state,settings)
        f.sequence[#f.sequence+1]='observe';f.observer_side=side
        local r=observe(side,state,settings);f.obs=r;return r
      end
    elseif path=='bloom.lua' then
      local update=module.update
      module.update=function(side,state,settings,obs)
        f.sequence[#f.sequence+1]='bloom';f.bloom_side=side
        local r=update(side,state,settings,obs);f.plan=r;return r
      end
    end
    return module
  end
  io.open=function(path,mode)
    if path=='runtime-settings.lua' then return {close=function()end} end
    if mode=='r' then return nil end
    check(mode=='w' and path:match('^ai_debug_.+%.csv$')~=nil,'unexpected disk write')
    return {write=function(_,s)f.output[#f.output+1]=s end,flush=function()end,close=function()end}
  end
  loadfile=function(path)
    if path=='runtime-settings.lua' then return function()return {seconds=0,ai=ai or {}}end end
    return real_loadfile(path)
  end
  game_sides={[2]=f.side};sendKeys=function(mask)f.sent[#f.sent+1]=mask end
  local real_print=print;print=function()end
  local ok,err=pcall(real_dofile,'main.lua');print=real_print
  dofile,io.open,loadfile=real_dofile,real_open,real_loadfile
  if not ok then error(err)end
  f.main=main
  function f.step()
    f.sequence={};game_sides={[2]=f.side};sendKeys=function(mask)f.sent[#f.sent+1]=mask end
    f.main()
    eq(table.concat(f.sequence,','),'perceive,observe,bloom,choose','one shared perception precedes all planners')
    check(f.observer_side==f.perceived and f.bloom_side==f.perceived and f.dodge_side==f.perceived,
      'observer bloom and dodge must receive the identical filtered snapshot')
    check(math.floor(f.sent[#f.sent]/2)%2==0,'vision integration cannot emit X')
    local header,values,row=split(f.output[1]),split(f.output[#f.output]),{}
    eq(#header,162,'vision CSV width');eq(#values,#header,'CSV row width')
    for i,name in ipairs(header)do row[name]=values[i]end
    f.row=row;return row
  end
  return f
end
local function rich(f,anchor)
  anchor=anchor or 0
  f.player.x=anchor;f.player.hitBodyRect.x=anchor;f.player.hitBodyCircle.x=anchor
  f.player.currentChargeMax=400
  for i=1,4 do f.side.enemies[i]=enemy(i,anchor+(i%2)*12-6,100+(i-1)*45)end
  for i=1,20 do f.side.bullets[i]=circle(100+i,anchor+(i%5)*10-20,80+math.floor(i/5)*5)end
end
local function movePlayer(f,x,y)
  f.player.x,f.player.y=x,y
  f.player.hitBodyRect.x,f.player.hitBodyRect.y=x,y
  f.player.hitBodyCircle.x,f.player.hitBodyCircle.y=x,y
end

scenario('outside rich chain cannot fund C2 or target but a wider circle can',function()
  local small=fixture({difficulty='mech',vision_radius=50});rich(small);small.step()
  eq(#small.perceived.enemies,0,'all remote enemy seeds hidden');eq(#small.perceived.bullets,0,'remote white bullets hidden')
  eq(small.obs.counts.field_erasable,0,'hidden bullets cannot inflate resource pressure')
  check(small.obs.c2.has_ignition~=true and not small.obs.has_target,'hidden chain supplies neither C2 ignition nor target')
  check(small.plan.target_level~=2 and small.plan.press_z~=true,'hidden richness cannot initiate C2')
  eq(tonumber(small.row.bullets),20,'raw bullet count remains diagnostic only')
  eq(tonumber(small.row.vision_hidden_bullets),20,'CSV reports hidden resources')
  local large=fixture({difficulty='mech',vision_radius=640});rich(large);large.step()
  eq(#large.perceived.enemies,4,'wider view restores same real seeds')
  eq(large.obs.counts.field_erasable,20,'wider view restores actual pressure count')
  check(large.obs.c2.has_ignition and large.obs.c2.chain_bullets>=8,'real observer confirms profitable C2 chain')
  eq(large.plan.target_level,2,'same geometry now starts C2');check(large.plan.press_z,'C2 start holds Z')
end)
scenario('outside white density does not enter bloom',function()
  local small=fixture({difficulty='mech',vision_radius=50});small.player.currentChargeMax=200
  for i=1,220 do small.side.bullets[i]=circle(i,i%5,100)end
  small.step();eq(small.obs.counts.field_erasable,0,'no hidden field pressure')
  check(small.state.bloom.bloom_mode~=true,'hidden density cannot trigger bloom mode')
  local large=fixture({difficulty='mech',vision_radius=640});large.player.currentChargeMax=200
  large.side.bullets=copy(small.side.bullets);large.step()
  eq(large.obs.counts.field_erasable,220,'visible density reaches observer')
  check(large.state.bloom.bloom_mode==true,'visible density can trigger real bloom threshold')
end)
scenario('circle follows the player on each callback',function()
  local f=fixture({difficulty='mech',vision_radius=50});f.side.bullets={circle(1,0,200)}
  f.step();eq(f.obs.counts.field_erasable,0,'remote bullet starts hidden')
  movePlayer(f,0,240);f.step();eq(f.obs.counts.field_erasable,1,'same unmoved bullet enters moved player circle')
  movePlayer(f,0,320);f.step();eq(f.obs.counts.field_erasable,0,'moving back hides it immediately')
end)
scenario('leaving circle revokes attention between target-admission scans',function()
  local f=fixture({vision_radius=50,attention_capacity=10,attention_recovery_per_second=10,
    plan_interval=6,reflex_radius=0})
  local b=circle(202,0,300,0,1.5,false);f.side.bullets={b};f.step()
  eq(f.movement.attention_tracked,1,'visible urgent object acquired on first scan')
  b.x,b.hitBody.x,b.vx=100,100,-10;f.step()
  eq(f.movement.objects_seen,0,'currently hidden inbound object cannot be scored')
  eq(f.movement.attention_tracked,0,'tracked object drops on non-scan callback')
  check(next(f.state.attention_set)==nil and #f.state.attention_scored==0,'attention caches discard hidden identity')
  b.x,b.hitBody.x,b.vx=0,0,0;f.step()
  eq(f.movement.objects_seen,0,'reentry cannot restore an old identity for free between scans')
end)
scenario('leaving circle clears free laser history immediately',function()
  local f=fixture({vision_radius=50,plan_interval=6});local b=beam(50,0);f.side.bullets={b}
  f.step();check(f.state.laser_history[50]~=nil,'visible long beam acquires dynamic history')
  b.x,b.hitBody.x=80,80;f.step()
  eq(f.movement.laser_count,0,'free laser category cannot bypass sight')
  check(next(f.state.laser_history)==nil,'hidden beam cache cleared on non-scan callback')
  b.x,b.hitBody.x=0,0;f.step()
  eq(f.movement.laser_count,1,'beam visible again');eq(f.movement.tracked_lasers,0,'returning beam has no unseen history')
  eq(f.movement.dynamic_lasers,0,'returning beam cannot extrapolate hidden motion')
end)
scenario('circle filters native poison without mutating native snapshot',function()
  local f=fixture({difficulty='mech',vision_radius=50})
  f.side.bullets={circle(1,0,300),circle(2,100,300)}
  f.side.enemies={enemy(3,0,290),enemy(4,100,290)}
  f.side.exAttacks={circle(5,0,310),circle(6,100,310)}
  f.player.sensor.poisonClouds={cloud(0,320,10),cloud(200,320,10)}
  local raw=copy(f.side);local native_sensor,native_clouds=f.player.sensor,f.player.sensor.poisonClouds
  f.step()
  unchanged(raw,f.side,'side')
  check(f.side.player==f.player and f.player.sensor==native_sensor and native_sensor.poisonClouds==native_clouds,
    'native player sensor and poison list identities are preserved')
  check(f.perceived~=f.side and f.perceived.player~=f.player and f.perceived.player.sensor~=native_sensor,
    'perception owns separate lists player and sensor containers')
  eq(#f.perceived.player.sensor.poisonClouds,1,'only one native poison circle is visible')
  check(f.perceived.player.sensor.poisonClouds[1]==native_clouds[1],'visible native cloud retains its exact source identity')
  check(f.perceived.player.sensor.opponent==native_sensor.opponent and f.perceived.player.sensor.commonWaves==native_sensor.commonWaves,
    'read-only opponent and own-wave metadata are preserved')
  eq(f.movement.poison_clouds,1,'real movement model receives filtered native poison')
  eq(tonumber(f.row.vision_visible_poison),1,'CSV visible poison');eq(tonumber(f.row.vision_hidden_poison),1,'CSV hidden poison')
end)
scenario('mech and enabled false both remain bound by circle',function()
  for _,ai in ipairs({{difficulty='mech',vision_radius=16},{enabled=false,vision_radius=16}})do
    local f=fixture(ai);f.side.bullets={circle(1,0,290,0,3,false)};f.step()
    eq(f.settings.attention.enabled,false,'attention disabled');eq(f.movement.objects_seen,0,'disabled attention cannot recover hidden objects')
    eq(tonumber(f.row.vision_hidden_bullets),1,'hidden object remains recorded separately')
  end
end)
scenario('changing view radius changes real avoidance input',function()
  local small=fixture({difficulty='mech',vision_radius=16});small.side.bullets={circle(1,0,290,0,3,false)};small.step()
  local large=fixture({difficulty='mech',vision_radius=50});large.side.bullets={circle(1,0,290,0,3,false)};large.step()
  eq(small.movement.objects_seen,0,'small circle hides current body despite its future approach')
  eq(large.movement.objects_seen,1,'large circle scores the real hazard')
  check(small.movement.key~=large.movement.key,'real geometry must produce a different avoidance decision')
  check(large.movement.trajectory_tests>0,'visible hazard actually ran trajectory tests')
end)
scenario('moving outside a locked chain cannot reuse observer position resources',function()
  local f=fixture({difficulty='mech',vision_radius=260});rich(f,-100);f.step()
  eq(f.plan.target_level,2,'fixture first locks a real profitable C2')
  check(f.obs.c2_position.has_ignition,'fixture has a usable cached release site')
  f.player.currentCharge=50;movePlayer(f,136,432);f.step()
  eq(#f.perceived.enemies,0,'all old locked chain nodes now outside circle')
  check(f.obs.c2.has_ignition~=true and f.obs.c2_position.has_ignition~=true,'neither actual nor cached site may borrow hidden nodes')
  eq(f.obs.counts.field_erasable,0,'hidden old white bullets cannot fund the old lock')
  check(f.plan.target_level~=2 and not f.plan.press_z,'old C2 cancels after its visible chain disappears')
end)

dofile,io.open,loadfile=real_dofile,real_open,real_loadfile
for _,m in ipairs(failures)do print('FAIL '..m)end
assert(#failures==0,string.format('vision integration: %d/%d scenarios failed',#failures,cases))
print(string.format('vision integration PASS: %d scenarios, %d assertions',cases,checks))
