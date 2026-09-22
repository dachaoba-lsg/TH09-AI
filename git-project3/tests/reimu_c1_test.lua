-- Verified Reimu selector-1 contract only. Bounded homing and synthetic current
-- HP/AABBs do not make returned energy or future enemy protection certain.
local observer,bloom=dofile('bloom_observer.lua'),dofile('bloom.lua')
local checks=0
local function check(v,m) checks=checks+1;assert(v,m) end
local function eq(a,b,m) check(a==b,m..': '..tostring(a)..' ~= '..tostring(b)) end
local function enemy(id,x,y,hp,spirit,activated)
  return {id=id,enabled=true,x=x,y=y,vx=0,vy=0,isSpirit=spirit==true,isActivatedSpirit=activated==true,
    isBoss=false,isLily=false,isPseudoEnemy=false,
    combat={apiVersion=1,valid=true,id=id,side=1,slotIndex=id,hp=hp,x=x,y=y,width=20,height=20,
      blocksShots=true,damageable=true,shotCanIgnite=not spirit or activated==true,
      secondaryBlocksShots=false,secondaryWidth=0,secondaryHeight=0,
      shotDamageDivisor=spirit and (activated and 2 or 4) or 1}}
end
local function shot(index,x,y,speed)
  return {supported=true,templateIndex=index,spawnTick=0,offsetX=x or 0,offsetY=y or -100,
    width=48,height=48,speed=speed or 0,angle=-math.pi/2,type=0,damage=30,linearUntilTick=40}
end
local function world(hp,spirit,activated,shots)
  local w={player={x=0,y=320,character=0,life=10,currentCharge=0,currentChargeMax=100,chargeSpeed=10,
    sensor={followupApiVersion=1,timeScale=1,canCharge=true,state=0,chargeWarmupFrames=0,
      c1ActionActive=false,c1ActionAge=0,c1ActionDuration=50,commonWavesValid=true,commonWaves={},
      c1Profile={valid=true,limited=false,activeValid=true,activeShots={},character=0,damageModelVersion=1,
        actionDuration=50,shots=shots or {shot(1)}}}},
    enemies={enemy(1,0,220,hp or 20,spirit,activated),enemy(2,50,220,20,true,false)},bullets={}}
  for i=1,20 do w.bullets[i]={id=100+i,enabled=true,x=i%5,y=220,vx=0,vy=0,isErasable=true} end
  return w
end
local function observe(w,cfg,state) return observer.observe(w,state or {},cfg or {}) end
local function policy(w,o) return bloom.update(w,{},bloom.defaults,o) end

do
  local w=world(31);local o=observe(w)
  check(o.c1.kill_model and o.c1.combat_valid,'known Reimu/Enemy contract not selected')
  check(not o.c1.has_ignition and o.c1.hp_rejected==1,'one damage-30 shot invented an HP31 kill')
  w.player.sensor.c1Profile.limited=true
  eq(policy(w,observe(w)).target_level,0,'limited flag let legacy C1 bypass a known insufficient-damage result')
  w.player.sensor.c1Profile.shots[2]=shot(2)
  o=observe(w)
  check(o.c1.has_ignition and o.c1.hit_count==1,'independent overlapping projectiles were deduplicated')
  eq(policy(w,o).target_level,1,'sufficient known Reimu C1 was disabled')
  w.enemies[1].combat.hp=61
  check(not observe(w).c1.has_ignition,'two damage-30 shots invented an HP61 kill')
end

do
  local w=world(20,true,true);local o=observe(w)
  check(not o.c1.has_ignition and o.c1.hp_rejected==1,'activated spirit did not halve ordinary shot damage')
  w.player.sensor.c1Profile.shots[2]=shot(2)
  check(observe(w).c1.has_ignition,'two confirmed hits could not defeat activated HP20 spirit')
  w.enemies[1].isActivatedSpirit=false
  w.enemies[1].combat.shotCanIgnite=false;w.enemies[1].combat.shotDamageDivisor=4;w.enemies[1].combat.hp=1
  o=observe(w)
  check(not o.c1.has_ignition and o.c1.blocked_shots==2,'unactivated spirit became a seed merely because HP was low')
  check(o.capture.has_target and o.c2.has_ignition,'Reimu restrictions erased independent capture/C2 opportunities')
  -- Only the same actual enemy activation changes eligibility; pressing Shift
  -- or inventing a duration in the planner never edits these read-only fields.
  w.enemies[1].isActivatedSpirit=true;w.enemies[1].combat.shotCanIgnite=true
  w.enemies[1].combat.shotDamageDivisor=2;w.enemies[1].combat.hp=20
  check(observe(w).c1.has_ignition,'actual same-ID activation failed to restore a sufficient C1')
end

do
  local w=world(20,false,false,{shot(1),shot(2)});local os,s={},{}
  local o=observe(w,{},os);local r=bloom.update(w,s,bloom.defaults,o)
  eq(r.target_level,1,'HP revalidation setup did not start C1')
  w.player.currentCharge=50;w.enemies[1].combat.hp=100
  os.lock_ids=s.attack_ids;os.c1_seed_ids=s.c1_seed_ids
  o=observe(w,{},os);r=bloom.update(w,s,bloom.defaults,o)
  eq(r.reason,'c1_seed_lost_cancel','new insufficient-HP evidence did not cancel immature C1')
end

-- Requested Shift is not observed activation or actual delivered Shift.
-- Existing safety overrides and the original actual-focus budget remain in force.
do
  local w=world(20,true,false,{shot(1),shot(2)});local os,s={},{fast_frames=100}
  local function step(actual_focus)
    os.lock_ids=s.target_level and s.attack_ids or s.prepare_ids
    os.c1_seed_ids=s.c1_seed_ids
    local o=observe(w,{},os);local r=bloom.update(w,s,bloom.defaults,o)
    bloom.feedback(s,{focus=actual_focus},bloom.defaults)
    return r
  end
  for _=1,10 do
    local r=step(false)
    check(r.intent.focus and not r.press_z and r.target_level==0,'unactivated target skipped real capture preparation')
  end
  eq(s.prepare_focus_frames,0,'requested Shift was counted despite actual safety override')
  for _=1,8 do step(true) end
  eq(s.prepare_activated,0,'delivered Shift alone fabricated spirit activation')
  local r=step(true)
  check(not r.press_z and r.target_level==0,'C1 released without same-ID activation feedback')
  w.enemies[1].isActivatedSpirit=true;w.enemies[1].combat.shotCanIgnite=true;w.enemies[1].combat.shotDamageDivisor=2
  r=step(true)
  eq(r.target_level,1,'confirmed activation and sufficient damage did not allow resource C1')
end

-- First contact consumes each non-piercing projectile, even when that target
-- cannot start the desired explosion. Collision uses both complete AABBs.
for _,kind in ipairs({'unactivated','protected','high_hp','boss'}) do
  local w=world(20,false,false,{shot(1,0,0,4)})
  local front=enemy(3,0,280,1000,kind=='unactivated',false)
  if kind=='protected' then front.combat.damageable=false end
  if kind=='boss' then front.isBoss=true;front.combat.shotCanIgnite=false end
  w.enemies[#w.enemies+1]=front
  local o=observe(w)
  check(not o.c1.has_ignition,'non-piercing C1 passed through '..kind..' blocker')
  front.combat.blocksShots=false
  check(observe(w).c1.has_ignition,'non-scanned '..kind..' object falsely consumed a shot')
end
do
  local w=world(20);w.enemies[1].x=33;w.enemies[1].combat.x=33
  check(observe(w).c1.has_ignition,'known enemy half-width was omitted from Reimu AABB collision')
  w.enemies[1].x=35;w.enemies[1].combat.x=35
  check(not observe(w).c1.has_ignition,'full widths were incorrectly treated as half-widths')
end

-- No straight-line continuation through the first homing update is budgeted.
do
  local w=world(20,false,false,{shot(1,0,0,4)})
  w.enemies[1].y=130;w.enemies[1].combat.y=130 -- first touch: (320-130-34)/4 = 39
  check(observe(w).c1.has_ignition,'last known pre-homing contact was lost')
  w.enemies[1].y=126;w.enemies[1].combat.y=126 -- first touch at age 40
  check(not observe(w).c1.has_ignition,'age-40 homing was fabricated as a linear hit')
  w.player.sensor.c1Profile.shots[1].supported=false
  local o=observe(w)
  eq(policy(w,o).target_level,0,'unsupported Reimu callback bypassed the kill model via legacy C1')
end

-- The full verified movement contract supports normal C1 ranges after its
-- slow initial segment. The preparation delay has its own bound and must not
-- consume the post-launch flight window.
do
  local templates={shot(1,8,0,.5),shot(2,-8,0,.5),shot(3,16,0,.5),shot(4,-16,0,.5)}
  local angles={-1.39626336098,-1.74532926083,-1.22173047066,-1.91986215115}
  for i,angle in ipairs(angles) do templates[i].angle=angle;templates[i].movementModelVersion=1 end
  for _,distance in ipairs({60,100,149}) do
    local w=world(20,false,false,templates)
    for _,e in ipairs(w.enemies) do e.y=320-distance;e.combat.y=e.y end
    local o=observe(w,{c1_release_delay_updates=30})
    check(o.c1.has_ignition,'verified homing could not reach normal C1 range '..distance)
    check(o.stats.c1_motion_steps>4*40,'far-range positive control did not exercise homing updates')
  end
end

-- An unknown visible blocker must not vanish from prediction and expose a
-- funded target behind it. Invalid combat data affects only C1 estimation.
for _,fault in ipairs({'missing','invalid','identity','side','hp','shape','divisor','version'}) do
  local w=world(20);local q=w.enemies[2].combat
  if fault=='missing' then w.enemies[2].combat=nil
  elseif fault=='invalid' then q.valid=false
  elseif fault=='identity' then q.id=999
  elseif fault=='side' then q.side=3
  elseif fault=='hp' then q.hp=0/0
  elseif fault=='shape' then q.width=-1
  elseif fault=='divisor' then q.shotDamageDivisor=0
  elseif fault=='version' then q.apiVersion=2 end
  local o=observe(w)
  check(o.valid and not o.c1.combat_valid and not o.c1.has_ignition,'unknown combat was trusted: '..fault)
  eq(policy(w,o).target_level,0,'unknown combat escaped to legacy C1: '..fault)
end
do
  local w=world(20);w.player.sensor.c1Profile.damageModelVersion=2
  check(not observe(w).c1.has_ignition,'unknown precise model version was accepted')
  w.player.sensor.c1Profile.character=-1;w.player.sensor.c1Profile.damageModelVersion=0
  eq(policy(w,observe(w)).target_level,0,'unknown native character bypassed the Reimu guard')
  w.player.sensor.c1Profile.character=1;w.player.sensor.c1Profile.damageModelVersion=nil
  w.enemies[1].combat=nil;w.enemies[2].combat=nil
  check(observe(w).c1.has_ignition,'Reimu-only metadata requirement leaked into other characters')
end

do
  local w=world(20,false,false,{shot(1,0,0,4)});local q=enemy(3,40,280,20).combat
  local blocker=enemy(3,40,280,20);blocker.combat=q;q.width=2;q.height=2
  q.secondaryBlocksShots=true;q.secondaryWidth=100;q.secondaryHeight=20;q.damageable=false
  w.enemies[#w.enemies+1]=blocker
  check(not observe(w).c1.has_ignition,'secondary non-damaging box did not consume the projectile')
  q.secondaryBlocksShots=false
  check(observe(w).c1.has_ignition,'disabled secondary box remained a phantom blocker')
end

-- Same discrete contact: the native enemy slot order decides consumption,
-- not the arbitrary order of the exported enemies array.
do
  local w=world(20);local blocker=enemy(3,0,220,1,true,false)
  w.enemies[1].combat.slotIndex=10;w.enemies[#w.enemies+1]=blocker
  check(not observe(w).c1.has_ignition,'equal-tick blocker lost native slot priority')
end

-- Real four-template workload bound. Analytic interval tests avoid a hidden
-- 40-tick enumeration factor; this remains native64 synthetic timing, not FPS.
do
  local w=world(20);w.enemies={};w.bullets={}
  w.player.sensor.c1Profile.shots={shot(1,8,0,.5),shot(2,-8,0,.5),shot(3,16,0,.5),shot(4,-16,0,.5)}
  local angles={-1.39626336098,-1.74532926083,-1.22173047066,-1.91986215115}
  for i,angle in ipairs(angles) do
    w.player.sensor.c1Profile.shots[i].angle=angle;w.player.sensor.c1Profile.shots[i].movementModelVersion=1
  end
  for i=1,128 do w.enemies[i]=enemy(i,(i*29)%260-130,170+(i*23)%120,20,i%5==0,i%10==0) end
  for i=1,2000 do w.bullets[i]={id=1000+i,enabled=true,x=(i*37)%272-136,y=170+(i*17)%120,
    vx=0,vy=.5,isErasable=true} end
  local state={};local clock=perf_now or os.clock;local started=clock();local o
  local baseline=type(C1_BASELINE_OBSERVER)=='string' and dofile(C1_BASELINE_OBSERVER) or nil
  local function compareBaseline(label,iterations,current_ms)
    if not baseline then return end
    local function copy(value)
      if type(value)~='table' then return value end
      local out={};for k,v in pairs(value) do out[k]=copy(v) end;return out
    end
    local old=copy(w)
    old.player.sensor.c1Profile.limited=true
    old.player.sensor.c1Profile.character=nil;old.player.sensor.c1Profile.damageModelVersion=nil
    for _,v in ipairs(old.player.sensor.c1Profile.shots) do
      v.supported=false;v.movementModelVersion=nil;v.linearUntilTick=nil;v.templateIndex=nil
    end
    for _,e in ipairs(old.enemies) do e.combat=nil end
    local old_state={};local start=clock()
    for _=1,iterations do baseline.observe(old,old_state,{}) end
    local old_ms=(clock()-start)*1000/iterations
    print(string.format('reimu_c1_compare,scene=%s,baseline_3_4_ms=%.3f,current_ms=%.3f,delta_ms=%.3f',
      label,old_ms,current_ms,current_ms-old_ms))
  end
  for _=1,12 do
    o=observe(w,{},state)
    check(o.c1.combat_valid,'dense Reimu fixture did not exercise valid combat metadata')
    check(o.stats.c1_position_evaluations<=4,'Reimu site count escaped its fixed bound')
    check(o.stats.c1_motion_steps<=4*90*4,'Reimu motion work exceeded templates*updates*sites')
    check(o.stats.c1_hit_tests<=4*128*90*4,'Reimu contact work exceeded templates*targets*updates*sites')
  end
  local ms=(clock()-started)*1000/12
  check(ms<1500,'dense Reimu workload expanded pathologically')
  print(string.format('reimu_c1_perf,templates=4,enemies=128,bullets=2000,mean_ms=%.3f,contact_tests=%d',ms,o.stats.c1_hit_tests))
  compareBaseline('dense',12,ms)
  -- Keep every possible target near the far visible edge so all four shots
  -- must survive into homing; dense early blockers cannot make this test cheap.
  for i,e in ipairs(w.enemies) do
    e.x,e.y=(i*7)%19-9,171+i%7;e.combat.x,e.combat.y=e.x,e.y
  end
  state={};started=clock()
  for _=1,8 do
    o=observe(w,{},state)
    check(o.stats.c1_motion_steps>=4*40,'far dense workload skipped the homing phase')
    check(o.stats.c1_motion_steps<=4*90*4 and o.stats.c1_hit_tests<=4*128*90*4,
      'far dense workload exceeded bounded trajectory/collision work')
  end
  ms=(clock()-started)*1000/8
  check(ms<1500,'far dense Reimu workload expanded pathologically')
  print(string.format('reimu_c1_far_perf,templates=4,enemies=128,bullets=2000,mean_ms=%.3f,motion_steps=%d,contact_tests=%d',
    ms,o.stats.c1_motion_steps,o.stats.c1_hit_tests))
  compareBaseline('far',8,ms)
end
print('reimu_c1_test: PASS ('..checks..' assertions; conservative verified Reimu contract only)')
