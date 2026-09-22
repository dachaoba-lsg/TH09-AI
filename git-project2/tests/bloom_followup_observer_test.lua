-- Read-only synthetic followup observations, not a game/damage simulator.
local observer=dofile('bloom_observer.lua')
local checks=0
local function check(v,m) checks=checks+1;assert(v,m) end
local function enemy(id,x,y,spirit,active,vx,vy)
 return {id=id,enabled=true,x=x,y=y,vx=vx or 0,vy=vy or 0,isSpirit=spirit==true,isActivatedSpirit=active==true,
  isBoss=false,isLily=false,isPseudoEnemy=false}
end
local function bullet(id,x,y,vx,vy)
 return {id=id,enabled=true,x=x,y=y,vx=vx or 0,vy=vy or 0,isErasable=true}
end
local function world(enemies,bullets)
 return {player={x=80,y=320,character=1,speedFast=4,sensor={followupApiVersion=1,timeScale=1,
  moveScaleX=1,moveScaleY=1,c1ActionActive=false,c1ActionAge=0,c1ActionDuration=30,
  commonWavesValid=true,commonWaves={}}},enemies=enemies or {},bullets=bullets or {}}
end
local function observe(w,state,cfg)return observer.observe(w,state or {},cfg or {prediction_frames=20})end
local function profile(shots,active)
 return {valid=true,limited=false,shots=shots or {},activeValid=true,activeShots=active or {}}
end
local function shot(x,y,w,h,tick,speed,angle,kind)
 return {supported=true,spawnTick=tick or 0,offsetX=x,offsetY=y,width=w,height=h,
  speed=speed or 0,angle=angle or 0,type=kind or 3,damage=10,piercing=(kind or 3)>=2}
end
local function active(x,y,w,h,kind)
 return {supported=true,currentGeometryOnly=true,x=x,y=y,width=w,height=h,vx=0,vy=0,
  type=kind or 3,damage=10,piercing=(kind or 3)>=2,damageReady=true}
end
local function contains(list,value)for _,v in ipairs(list)do if v==value then return true end end return false end
do
 local w=world({enemy('fairy',0,240),enemy('spirit',-50,240,true)}, {bullet('white',0,240)})
 w.player.x=0
 local r=observe(w)
 check(r.capture.preferred and r.capture.target_x<0,'A1 same-chain left capture lost to its own ordinary ignition')
end
-- Pure spirits carry spatial bullet value, even though ordinary shots cannot
-- ignite them. Leftward approach is proposed before narrow shot alignment.
do
 local w=world({enemy('left1',-100,240,true),enemy('left2',-70,230,true),enemy('right',80,235)})
 for i=1,30 do w.bullets[i]=bullet(i,-90+i%4,235+i%5) end
 local r=observe(w)
 check(r.capture.valid and r.capture.has_target and r.capture.preferred,'left spirit resources did not compete independently')
 check(r.capture.target_x<0 and r.capture.target_y>=150,'capture proposal lost leftward/height bounds')
 check(r.capture.chain_bullets==30 and r.capture.future_bullets==30,'pure-spirit white-bullet value missing')
 check(r.capture.chain_score>r.chain_score and r.capture.focus_value==2,'capture score still zero or on a different scale')
 check(r.followup.has_target and r.followup.kind=='capture' and r.followup.travel_updates>0,'followup approach missing')
 local fast=r.followup.travel_updates
 w.player.sensor.moveScaleX=.4
 r=observe(w)
 check(r.followup.travel_updates>fast,'poison multiplier did not affect followup travel estimate')
 w.player.sensor.timeScale=0
 check(observe(w).followup.travel_updates==nil,'time stop promised a reachable approach')
 w.enemies={enemy('spirit',-90,240,true)}
 r=observe(w)
 check(not r.has_ignition and r.chain_score==0 and r.capture.chain_bullets==30,'new capture output changed ordinary ignition semantics')
end
-- New future arrivals may join a group, but cannot manufacture retained-chain
-- capture value. Locks cannot migrate after all original nodes disappear.
do
 local w=world({enemy('original',-60,240,true),enemy('arrival',60,240,true,false,-4,0)}, {bullet('new',20,240)})
 local r=observe(w,{lock_ids={original=true}})
 check(r.capture.has_target and r.capture.future_bullets==0,'capture borrowed a new future member neighborhood')
 check(not contains(r.capture.chain_ids,'arrival'),'current original set unexpectedly contains remote newcomer')
 w.enemies={enemy('arrival',-60,240,true)}
 r=observe(w,{lock_ids={original=true}})
 check(not r.capture.has_target and not r.c1.has_ignition,'original capture lock migrated')
 local state={lock_ids={spirit=true}}
 w.enemies={enemy('spirit',-60,240,true)}
 observe(w,state)
 w.enemies[1].isActivatedSpirit=true
 r=observe(w,state)
 check(r.capture.chain_activated_gain==1,'last spirit activation feedback was lost when capture completed')
end
-- Coverage is SHT selector-1 geometry, independent of ordinary shot x alignment.
-- Multiple seeds/groups share one union of white-bullet cells.
do
 local w=world({enemy('offaxis',-80,220)}, {bullet('b',-80,220)})
 w.player.x=0
 w.player.sensor.c1Profile=profile({shot(-80,-100,20,20)})
 local r=observe(w)
 check(not r.ignition_aligned and r.c1.valid and r.c1.has_ignition,'C1 inherited ordinary shot alignment')
 check(r.c1.hit_count==1 and r.c1.chain_bullets==1,'independent C1 coverage missing')
 w.enemies={enemy('left',-40,220),enemy('right',40,220)};w.bullets={bullet('shared',0,220)}
 w.player.sensor.c1Profile=profile({shot(0,-100,140,20)})
 r=observe(w,{}, {link_radius=20,prediction_frames=20})
 check(r.c1.hit_count==2 and r.c1.chain_enemies==2 and r.c1.chain_bullets==1,'multi-seed C1 double-counted shared white bullets')
 check(r.c1.future_bullets==1,'future C1 union double-counted shared white bullets')
 -- Non-piercing shots cannot be budgeted as independently hitting every seed.
 w.player.sensor.c1Profile=profile({shot(0,-100,140,20,0,0,0,0)})
 r=observe(w,{}, {link_radius=20,prediction_frames=20})
 check(r.c1.hit_count==1 and r.c1.chain_enemies==1,'one non-piercing shot became multiple independent seeds')
end
-- C1 position proposals never mutate current-position coverage and cannot move
-- already existing shot AABBs with the player.
do
 local w=world({enemy('left',-80,220)}, {bullet('b',-80,220)})
 w.player.sensor.c1Profile=profile({shot(0,-100,20,20)})
 local r=observe(w)
 check(not r.c1.has_ignition and r.c1_position.has_ignition and r.c1_position.target_x<0,'C1 site failed to stay separate from actual coverage')
 check(r.c1.chain_bullets==0 and r.c1_position.chain_bullets==1,'candidate C1 yield leaked into actual point')
 w.player.sensor.c1Profile=profile({}, {active(-80,220,20,20)})
 r=observe(w)
 check(r.c1.has_ignition and r.c1.active_hit_count==1 and not r.c1.future_has_ignition,'current-only shot geometry was projected into future')
 check(r.c1.remaining_only and not r.c1.action_active,'lingering actual C1 shot was budgeted as a fresh action')
 w.player.sensor.c1Profile.activeShots[1].damageReady=false
 check(not observe(w).c1.has_ignition,'odd type-2 damage tick counted as current coverage')
 w.player.sensor.c1Profile={valid=false,limited=true,activeValid=false,shots={shot(0,-100,500,500)}}
 r=observe(w)
 check(not r.c1.valid and r.c1.model_limited and not r.c1.has_ignition,'invalid profile became known coverage')
 w.player.sensor.c1Profile=profile({shot(0,-100,500,500)})
 w.player.sensor.c1Profile.shots[1].supported=false
 r=observe(w)
 check(r.c1.model_limited and not r.c1.has_ignition,'unknown callback acquired generic geometry')
end
-- The ongoing type-1 action owns its already spawned entries. Repressing Z
-- does not budget the entire action again; only future entries/current AABBs.
do
 local w=world({enemy('past',-80,220),enemy('future',80,220)})
 w.player.x=0;w.player.sensor.c1ActionActive=true;w.player.sensor.c1ActionAge=10
 w.player.sensor.c1Profile=profile({shot(-80,-100,20,20,0),shot(-80,-100,20,20,10),shot(80,-100,20,20,20)})
 local r=observe(w,{}, {link_radius=20,prediction_frames=20})
 check(r.c1.action_active and r.c1.remaining_only and r.c1.hit_count==1,'ongoing action replayed spawned entries')
 check(contains(r.c1.seed_ids,'future') and not contains(r.c1.seed_ids,'past'),'past entry became remaining C1 resource')
 w.player.sensor.c1ActionAge=20
 check(not observe(w).c1.has_ignition,'current-age entry was counted again as not-yet-spawned')
end
-- Actual common-wave yield exclusion has a fixed centre and update-count life,
-- independent of state3 protection. It applies to capture/C1/C2 exactly once.
do
 local w=world({enemy('s',-80,220,true),enemy('f',-60,220)}, {bullet('b',-80,220)})
 w.player.sensor.c1Profile=profile({shot(-150,-100,80,20)})
 w.player.sensor.commonWaves={{type=1,enabled=true,listed=true,x=-80,y=220,radius=4,growth=4,life=10,delay=0}}
 local r=observe(w)
 check(r.followup.excluded_bullets==1 and r.capture.chain_bullets==0 and r.c1.chain_bullets==0,'actual direct clear was reused for followup energy')
 w.player.x=120
 check(observe(w).followup.excluded_bullets==1,'wave centre followed moving player')
 w.player.sensor.protectionFrames=0;w.player.sensor.state=0
 check(observe(w).followup.excluded_bullets==1,'wave life incorrectly ended with protection')
 w.player.sensor.commonWaves[1].life=0;w.player.sensor.protectionFrames=48;w.player.sensor.state=3
 r=observe(w)
 check(r.followup.excluded_bullets==0 and r.capture.chain_bullets==1,'protection invented a still-active common wave')
 w.player.sensor.commonWaves[1].life=10;w.player.sensor.commonWaves[1].type=4
 check(observe(w).followup.excluded_bullets==0,'enemy-damage wave treated as bullet clearing')
 w.player.sensor.commonWaves[1].type=1;w.player.sensor.commonWaves[1].listed=false
 check(observe(w).followup.excluded_bullets==0,'unlisted object treated as currently colliding wave')
 w.player.sensor.commonWaves[1].listed=true;w.player.sensor.commonWaves[1].delay=2
 check(observe(w).followup.excluded_bullets==0,'delayed wave treated as already colliding')
 w.player.sensor.commonWaves[1].delay=0;w.player.sensor.commonWavesValid=false
 check(observe(w).followup.excluded_bullets==0,'invalid wave snapshot altered resource budget')
end
-- A valuable currently covered C1 chain should not lose to capture merely
-- because the latter is a valid leftward opportunity.
do
 local w=world({enemy('s',-80,230,true),enemy('fairy1',50,220),enemy('fairy2',80,220)}, {bullet(1,-80,230)})
 w.player.x=0
 for i=2,25 do w.bullets[i]=bullet(i,70,220) end
 w.player.sensor.c1Profile=profile({shot(65,-100,80,20)})
 local r=observe(w)
 check(r.capture.has_target and r.c1.has_ignition and r.c1.value>r.capture.value and not r.capture.preferred,'capture displaced higher-value immediate C1')
end
do
 local w=world({enemy('edge',11,220)}, {bullet('b',11,220)})
 w.player.x=0;w.player.sensor.c1Profile=profile({shot(0,-100,20,40,0,0,math.pi/2)})
 check(not observe(w).c1.has_ignition,'shot full width was treated as a radius or rotated by motion angle')
 local template=shot(0,0,16,48,0,.5,-1.396263,2);template.supported=false
 w.player.sensor.c1Profile=profile({template},{active(0,160,24,320,2)})
 w.player.sensor.c1Profile.limited=true
 local r=observe(w)
 check(r.c1.has_ignition and r.c1.model_limited and not r.c1.future_has_ignition,'Marisa current AABB became a fabricated future laser model')
 w.player.sensor.c1Profile.activeShots[1].damageReady=false
 check(not observe(w).c1.has_ignition,'Marisa odd damage tick used current AABB yield')
 w.player.sensor.c1Profile=profile({shot(11,-100,20,20,30)})
 check(not observe(w).c1.has_ignition,'shot scheduled after action duration was counted')
 w.enemies={enemy('blocker',0,280),enemy('locked',0,180)};w.bullets={}
 w.player.sensor.c1Profile=profile({shot(0,0,20,20,0,4,-math.pi/2,0)})
 check(not observe(w,{lock_ids={locked=true}},{link_radius=20}).c1.has_ignition,'non-piercing ray skipped an unrelated blocker to satisfy lock')
 local state={};w.enemies={enemy('left',-80,220)};w.bullets={bullet(1,-80,220)}
 w.player.sensor.c1Profile=profile({shot(0,-100,20,20)})
 r=observe(w,state)
 check(r.c1_position.chain_bullets==1,'C1 cache setup failed')
 w.bullets={};r=observe(w,state)
 check(r.c1_position.chain_bullets==0,'C1 cache reused stale white-bullet yield')
 w.enemies={enemy('new',-120,220)};r=observe(w,state)
 check(r.c1_position.has_ignition and r.c1_position.target_x==-120,'failed cached C1 coverage did not search new coordinates')
end
do
 local w=world({enemy('seed',0,220),enemy('relay',0,160),enemy('top',0,100),enemy('spirit',-50,180,true)}, {bullet(1,0,75)})
 w.player.x=0;w.player.speedFast=nil
 local before=observe(w)
 w.player.speedFast=4
 local r=observe(w)
 check(r.c2.has_ignition and r.followup.joint_compared,'pre-C2 followup comparison missing')
 check(r.c2.chain_bullets==before.c2.chain_bullets and r.c2.chain_score==before.c2.chain_score,'followup borrowed resources into actual C2')
 check(r.c2_position.target_x==before.c2_position.target_x and r.c2_position.target_y==before.c2_position.target_y or
  r.c2_position.target_x==w.player.x and r.c2_position.target_y==w.player.y,'followup invented an unassessed C2 release point')
end
-- Spatial wave lookup must agree with a separate full union scan.
do
 local function brute(b,waves,scale)
  for _,v in ipairs(waves)do
   if v.type==1 and v.enabled and v.listed and v.delay==0 and v.life>0 then
    local n=v.life-1;local radius=v.radius+v.growth*n
    local dx,dy=b.x-v.x,b.y-v.y;local sx,sy=b.vx*scale*n,b.vy*scale*n
    local d=sx*sx+sy*sy
    if d>0 then local t=math.max(0,math.min(1,-(dx*sx+dy*sy)/d));dx,dy=dx+sx*t,dy+sy*t end
    if dx*dx+dy*dy<=radius*radius then return true end
   end
  end
  return false
 end
 for scene=1,24 do
  local w=world({enemy('f',0,200)})
  w.player.sensor.timeScale=scene%2==0 and .25 or 1
  for i=1,12 do w.player.sensor.commonWaves[i]={type=i%4==0 and 4 or 1,enabled=true,listed=i%5~=0,
   x=(i*47+scene*13)%500-250,y=(i*31+scene*17)%550-50,radius=i%7,growth=i%5,
   life=i*3,delay=i%6==0 and 2 or 0}end
  local expected=0
  for i=1,80 do
   local b=bullet(i,(i*37+scene)%272-136,(i*53+scene)%440,(i%7)-3,(i%9)-4)
   w.bullets[i]=b
   if brute(b,w.player.sensor.commonWaves,w.player.sensor.timeScale)then expected=expected+1 end
  end
  check(observe(w).followup.excluded_bullets==expected,'wave spatial lookup disagrees with independent union scan '..scene)
 end
end
-- Bounded repeated actual/cached-site evaluations with maximum profile arrays.
-- These snapshots are a workload probe, not real shots or a frame-rate promise.
local clock=perf_now or os.clock
for _,size in ipairs({{16,200},{128,2000}}) do
 local w=world();w.player.x=0
 for i=1,size[1]do w.enemies[i]=enemy(i,(i*31)%240-120,120+(i*23)%160,i%5==0)end
 for i=1,size[2]do w.bullets[i]=bullet(i,(i*37)%272-136,20+(i*17)%380,0,.5)end
 local templates,shots={},{ }
 for i=1,128 do
  templates[i]=shot((i%16)*14-110,-20-math.floor((i-1)/16)*18,8,16,i%24,1,-math.pi/2)
  shots[i]=active((i*19)%260-130,30+(i*17)%350,8,16)
 end
 w.player.sensor.c1Profile=profile(templates,shots)
 w.player.sensor.c1ActionActive=true;w.player.sensor.c1ActionAge=0
 -- All 512 reported circles are valid but small, keeping the fixture demanding.
 for i=1,512 do w.player.sensor.commonWaves[i]={type=1,enabled=true,listed=true,x=(i%32)*9-140,y=20+math.floor((i-1)/32)*26,
  radius=1,growth=0,life=1,delay=0}end
 local state={};local start=clock();local r
 for _=1,8 do r=observe(w,state)end
 local ms=(clock()-start)*1000/8
 check(r.stats.c1_position_evaluations<=4,'C1 site evaluations exceeded bound')
 check(r.c1.action_active and r.c1.remaining_only and r.stats.c1_hit_tests>0,'max profile did not exercise ongoing C1 coverage')
 check(r.stats.common_wave_tests<=size[2]*512,'actual-wave work escaped fixed bound')
 check(ms<1500,'followup observation pathological expansion')
 print(string.format('followup_observer_perf,enemies=%d,bullets=%d,templates=128,active=128,waves=512,mean_ms=%.3f,c1_tests=%d,wave_tests=%d',size[1],size[2],ms,r.stats.c1_hit_tests,r.stats.common_wave_tests))
end
print('bloom_followup_observer_test: PASS ('..checks..' checks; synthetic native64 Lua, no live damage/FPS claim)')
