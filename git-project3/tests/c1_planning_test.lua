-- Real observer/policy scheduling. These are bounded contact predictions,
-- not a simulation of real enemy death, energy return or game input.
local observer, bloom = dofile('bloom_observer.lua'), dofile('bloom.lua')
local checks = 0
local function check(value, message) checks=checks+1;assert(value,message) end
local function eq(a,b,message) check(a==b,message..': '..tostring(a)..' ~= '..tostring(b)) end
local function world()
  local w={player={x=0,y=320,life=10,currentCharge=0,currentChargeMax=100,chargeSpeed=10,
    sensor={followupApiVersion=1,timeScale=1,canCharge=true,canPressZ=true,state=0,chargeWarmupFrames=0,
      c1ActionActive=false,c1ActionAge=0,c1ActionDuration=30,commonWavesValid=true,commonWaves={},
      c1Profile={valid=true,limited=false,activeValid=true,activeShots={},shots={{supported=true,spawnTick=0,
        offsetX=0,offsetY=-100,width=20,height=20,speed=0,angle=0,type=3,damage=10}}}}},
    enemies={{id=1,enabled=true,x=0,y=220,vx=0,vy=0,isSpirit=false},
      {id=2,enabled=true,x=30,y=220,vx=0,vy=0,isSpirit=true,isActivatedSpirit=false}},bullets={}}
  for i=1,20 do w.bullets[i]={id=100+i,enabled=true,x=i%5,y=220,isErasable=true,vx=0,vy=0} end
  return w
end
local function step(w,s,os,cfg)
  os.lock_ids=s.target_level and s.attack_ids or s.prepare_ids
  os.c1_seed_ids=s.target_level==1 and not s.cadence_charge and s.c1_seed_ids or nil
  local o=observer.observe(w,os,cfg or {})
  local r=bloom.update(w,s,bloom.defaults,o)
  bloom.feedback(s,{focus=r.intent.focus},bloom.defaults)
  return r,o
end

-- A projectile spawned only after charging cannot hit a target which left its
-- lane before release, even though an immediately spawned one would hit now.
do
  local w=world();w.enemies[1].vx=3;w.enemies[2].vx=3
  check(observer.observe(w,{},{}).c1.has_ignition,'immediate-release positive control')
  local o=observer.observe(w,{}, {c1_release_delay_updates=10})
  check(not o.c1.has_ignition,'C1 ignored ten updates of pre-release target motion')
  w.enemies[1].vx,w.enemies[2].vx=0,0
  check(observer.observe(w,{}, {c1_release_delay_updates=10}).c1.has_ignition,
    'stationary reachable C1 was disabled by charge delay')
  check(not observer.observe(w,{}, {c1_release_delay_updates=181}).c1.has_ignition,
    'charge longer than the separate preparation horizon invented coverage')
  w.player.sensor.c1Profile.shots={}
  w.player.sensor.c1Profile.activeShots={{supported=true,damageReady=true,x=0,y=220,width=20,height=20,
    type=3,damage=10}}
  check(observer.observe(w,{}, {c1_release_delay_updates=1000000}).c1.has_ignition,
    'already-active geometry incorrectly waited for a fresh charge')
end

-- Revalidate a specific seed, not an arbitrary new fairy connected to an old
-- relay. Losing the selected seed below 100 still permits a real cancellation.
do
  local w,s,os=world(),{},{}
  local r=step(w,s,os)
  eq(r.target_level,1,'resource fixture must choose C1')
  check(s.c1_seed_ids[1] and not s.c1_seed_ids[2],'seed lock must not include non-ignitable relay')
  w.enemies[1].id=3;w.player.currentCharge=50
  local o;r,o=step(w,s,os)
  check(not o.c1.has_ignition,'old relay adopted an unrelated new C1 seed')
  eq(r.reason,'c1_seed_lost_cancel','lost immature C1 must cancel')
  check(not r.press_z and r.release_c1==0,'below-C1 cancellation became a release')
  check(s.c1_seed_ids==nil and s.target_level==nil,'cancelled seed plan was retained')
end

-- A mature charge cannot be cancelled, so a brief recovery window is bounded
-- both by time and by the real next-level charge ceiling.
for _,restore in ipairs({false,true}) do
  local w,s,os=world(),{},{}
  step(w,s,os);w.player.currentCharge=100;w.enemies={}
  local r=step(w,s,os)
  eq(r.reason,'wait_c1_seed','mature stale C1 must expose its bounded wait')
  check(r.press_z and r.release_c1==0,'stale C1 released before recovery opportunity')
  if restore then
    w.enemies=world().enemies
    r=step(w,s,os)
    check(not r.press_z and r.release_c1==1,'same original seed recovery did not release C1')
  else
    for _=2,8 do r=step(w,s,os) end
    eq(r.reason,'c1_seed_wait_limit','stale mature C1 did not terminate at bound')
    check(not r.press_z and r.release_c1==1 and r.release_c2==0,'stale exit changed C level')
  end
end
do
  local w,s,os=world(),{},{};step(w,s,os)
  w.player.currentCharge=190;w.enemies={}
  local r=step(w,s,os)
  eq(r.reason,'c1_seed_charge_ceiling','next update could reach 200 but C1 kept holding')
  check(not r.press_z and r.release_c1==1 and r.release_c2==0,'charge ceiling failed to keep C1 level')
end

-- Cadence is deliberately resource-independent, including promotion of a
-- previously resource-driven C1 when its ordinary deadline arrives.
for _,start_as_resource in ipairs({false,true}) do
  local w,s,os=world(),{},{}
  if start_as_resource then step(w,s,os) end
  s.since_c,s.since_c2=480,480;w.enemies={};w.bullets={}
  local r=step(w,s,os)
  check(r.press_z and s.cadence_charge,'deadline was incorrectly gated by a missing C1 seed')
  w.player.currentCharge=100;r=step(w,s,os)
  check(not r.press_z and r.release_c1==1,'deadline C1 did not release on an empty field')
end

-- Interrupted plans must not leave a stale original-seed lock or wait age in
-- the next round's observer/debug state, even if recovery did not cost HP.
for _,interruption in ipairs({'hit','recovery','energy'}) do
  local w,s,os=world(),{},{};step(w,s,os)
  check(s.c1_seed_ids~=nil,'interruption fixture lacks a seed lock')
  s.c1_lost_age=3;w.enemies={}
  if interruption=='hit' then w.player.life=9
  elseif interruption=='recovery' then w.player.sensor.state=1
  else w.player.currentChargeMax=0 end
  step(w,s,os)
  check(s.c1_seed_ids==nil and s.c1_lost_age==nil and not s.c1_resource_charge,
    interruption..' retained stale C1 plan diagnostics')
end

-- Real main wiring computes independent C1 ETA with timeScale, not its C2
-- forecast sample. Runtime settings/log output stay entirely in memory.
do
  HitType={Rect=0,Circle=1,RotatableRect=2};ChargeType={Slow=0,Charge=1};player_side=1
  local real_dofile,real_open,real_loadfile=dofile,io.open,loadfile
  local w=world();w.exAttacks={};w.chargeType=ChargeType.Slow
  local p=w.player;p.speedFast=4;p.speedSlow=2;p.hitBodyRect={width=4,height=4};p.hitBodyCircle={radius=2}
  local q=p.sensor;q.apiVersion=1;q.valid=true;q.baseScaleX=1;q.baseScaleY=1;q.moveScaleX=1;q.moveScaleY=1
  q.protectionFrames=0;q.chargeBlockFrames=0;q.poisonClouds={};q.chargeWarmupFrames=3;q.timeScale=.5
  local delay
  dofile=function(path)
    local m=real_dofile(path)
    if path=='config.lua' then m.debug_log=false end
    if path=='bloom_observer.lua' then
      local observe=m.observe
      m.observe=function(side,state,cfg) delay=cfg.c1_release_delay_updates;return observe(side,state,cfg) end
    end
    return m
  end
  io.open=function(path,...) if path=='runtime-settings.lua' then return nil end;return real_open(path,...) end
  game_sides={[1]=w};sendKeys=function(mask) check(math.floor(mask/2)%2==0,'C1 planning emitted X') end
  real_dofile('main.lua');main();eq(delay,26,'warm-up and charge ETA must round separate scaled updates')
  p.currentCharge=50;q.chargeWarmupFrames=0;main();eq(delay,10,'remaining C1 ETA must shorten during charging')
  p.currentCharge=100;main();eq(delay,0,'a mature C1 has no new charge delay')
  dofile,io.open,loadfile=real_dofile,real_open,real_loadfile
end
print('c1_planning_test: PASS ('..checks..' assertions; real observer/policy/main, no game process)')
