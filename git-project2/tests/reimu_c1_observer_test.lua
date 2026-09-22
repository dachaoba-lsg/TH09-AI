-- Native-field synthetic fixtures: verified damage is a forecast, not a live kill.
local observer=dofile('bloom_observer.lua')
local checks=0
local function check(v,m) checks=checks+1;assert(v,m) end
local function enemy(id,x,y,hp,spirit,activated)
 return {id=id,enabled=true,x=x,y=y,vx=0,vy=0,isSpirit=spirit==true,isActivatedSpirit=activated==true,
  isBoss=false,isLily=false,isPseudoEnemy=false,sensor={apiVersion=1,valid=true,health=hp,
   shotCollisionEnabled=true,shotDamageable=true,shotDamageDivisor=1,hitX=x,hitY=y,hitWidth=8,hitHeight=8}}
end
local function world(target)
 local shots={}
 for i,v in ipairs({{8,-80},{-8,-100},{16,-70},{-16,-110}}) do
  shots[i]={supported=false,motionModel='reimu_c1_homing',spawnTick=0,offsetX=v[1],offsetY=0,
   width=48,height=48,angle=v[2]*math.pi/180,speed=.5,damage=30,type=0}
 end
 return {player={character=0,x=0,y=320,speedFast=4,currentCharge=100,chargeSpeed=5,
  sensor={followupApiVersion=1,timeScale=1,chargeWarmupFrames=0,c1ActionDuration=40,c1ActionActive=false,
   c1Profile={valid=true,limited=true,activeValid=true,shots=shots,activeShots={},
    homingStateValid=true,homingTargetValid=true,homingTargetX=target.sensor.hitX,homingTargetY=target.sensor.hitY}}},enemies={target},bullets={}}
end
local function observe(w,state,cfg) return observer.observe(w,state or {},cfg or {prediction_frames=20}) end
local function whites(w,x,y)
 for i=1,20 do w.bullets[i]={id=i,enabled=true,x=x+i%3,y=y+i%4,vx=0,vy=0,isErasable=true} end
end
do
 local target=enemy('a',0,160,30)
 local w=world(target);whites(w,0,160)
 local r=observe(w)
 check(r.c1.damage_model_valid and r.c1.has_ignition and r.c1.kill_count==1,'Reimu homing did not reach a funded kill')
 check(r.c1.kill_delay>=40,'distant target was hit before the real homing delay')
 check(r.c1.chain_bullets==20,'verified seed did not propagate its chain resources')
 check(r.c1.timing.at_impact,'resource timing was not identified as hit-time geometry')
 for _,b in ipairs(w.bullets) do b.vy=5 end
 r=observe(w)
 check(r.c1.has_ignition and r.c1.chain_bullets==0,'already departed whites were credited at delayed impact')
 for _,b in ipairs(w.bullets) do b.vy=nil end
 check(observe(w).c1.chain_bullets==0,'unknown bullet velocity promised future whites')
 for _,b in ipairs(w.bullets) do b.vy=0 end
 target.sensor.health=121
 r=observe(w)
 check(r.c1.damage_model_valid and not r.c1.has_ignition and r.c1.kill_count==0,'four 30-damage cards killed 121 HP')
 check(r.c1.contact_count>0 and r.c1.chain_bullets==0,'coverage was still budgeted as a kill')
 target.sensor.health=30;target.sensor.shotDamageDivisor=9
 check(not observe(w).c1.has_ignition,'damage resistance was ignored')
 target.sensor.shotDamageDivisor=1;target.sensor.shotDamageable=false
 check(not observe(w).c1.has_ignition,'protected enemy was credited as a kill')
 target.sensor.shotDamageable=true;target.sensor.valid=false
 check(not observe(w).c1.damage_model_valid and not observe(w).c1.has_ignition,'invalid enemy sensor invented damage')
 target.sensor.valid=true;target.sensor.health=nil
 check(not observe(w).c1.has_ignition,'missing HP became a one-hit target')
 target.sensor.health=30;target.sensor.damageModelLimited=true
 check(not observe(w).c1.has_ignition,'unmodeled secondary damage geometry became a guaranteed kill')
end
do
 local target=enemy('s',0,200,15,true,false)
 local w=world(target);whites(w,0,200)
 local r=observe(w)
 check(not r.c1.has_ignition and r.capture.has_target and r.capture.preferred,'unactivated spirit became direct C1 seed')
 target.isActivatedSpirit=true;target.sensor.shotDamageDivisor=2
 r=observe(w)
 check(r.c1.has_ignition and r.c1.kill_count==1,'activated spirit did not become damage-qualified seed')
 target.sensor.shotDamageDivisor=4;target.sensor.health=31
 check(not observe(w).c1.has_ignition,'four cards invented enough reduced damage')
end
do
 local target=enemy('target',0,160,30)
 local w=world(target)
 local blocker=enemy('boss',0,280,9999);blocker.isBoss=true;blocker.sensor.shotDamageable=false
 w.enemies[2]=blocker
 check(not observe(w).c1.has_ignition,'non-resource protected boss did not consume non-piercing cards')
 w.enemies[2]=nil
 w.player.sensor.c1Profile.homingTargetX=100
 check(not observe(w).c1.has_ignition,'unmatched native homing target was silently replaced')
 w.player.sensor.c1Profile.homingTargetX=0;w.player.sensor.timeScale=0
 check(not observe(w).c1.has_ignition,'time-stop was projected as normal homing')
 w.player.sensor.timeScale=1;target.x=10
 check(observe(w).c1.has_ignition,'homing goal was matched to sprite rather than primary hitbox centre')
 w.player.sensor.c1Profile.homingStateValid=false
 check(not observe(w).c1.has_ignition,'invalid homing state invented a trajectory')
end
do
 local target=enemy('active',0,240,61)
 local w=world(target)
 w.player.sensor.c1ActionActive=true;w.player.sensor.c1ActionAge=15
 local profile=w.player.sensor.c1Profile
 profile.activeShots={{slotId=1,supported=true,damageReady=true,type=0,damage=30,x=0,y=240,width=48,height=48},
  {slotId=2,supported=true,damageReady=true,type=0,damage=30,x=0,y=240,width=48,height=48}}
 local r=observe(w)
 check(r.c1.remaining_only and not r.c1.has_ignition,'active contact with insufficient total damage became a kill')
 target.sensor.health=60
 r=observe(w)
 check(r.c1.has_ignition and r.c1.kill_count==1,'simultaneous active card damage was not aggregated')
 check(not r.c1.future_has_ignition,'already spawned cards were replayed as future attacks')
 profile.activeShots[2].slotId=1
 check(not observe(w).c1.has_ignition,'duplicate native slot was counted twice')
 profile.activeShots[2].slotId=nil
 check(not observe(w).c1.has_ignition,'missing native slot invented a second card')
 profile.activeShots[2].slotId=2
 target.sensor.shotDamageDivisor=9;target.sensor.health=6
 check(observe(w).c1.has_ignition,'simultaneous damage was divided per-card rather than as total')
 target.sensor.shotDamageDivisor=1;target.sensor.health=60
 profile.activeShots[2].damageReady=false
 check(not observe(w).c1.has_ignition,'damage-disabled card was included')
end
do
 local target=enemy('moving',0,160,30)
 local w=world(target);target.vy=-5
 w.player.currentCharge=0;w.player.chargeSpeed=1
 check(not observe(w).c1.has_ignition,'unbounded charge lead was ignored')
 w.player.currentCharge=100;target.vy=0
 w.player.sensor.c1Profile.shots[1].motionModel=nil
 w.player.sensor.c1Profile.shots[2].motionModel=nil
 w.player.sensor.c1Profile.shots[3].motionModel=nil
 w.player.sensor.c1Profile.shots[4].motionModel=nil
 check(not observe(w).c1.has_ignition,'unrecognized custom callback acquired Reimu projection')
end
do
 local target=enemy('seed',0,160,30)
 local w=world(target)
 local relay=enemy('relay',55,160,999,true,false);relay.vx=3
 w.enemies[2]=relay;whites(w,95,160)
 local r=observe(w)
 check(r.c1.has_ignition and r.c1.chain_enemies==1 and r.c1.chain_bullets==0,
  'relay that left before impact still propagated the chain')
 relay.x=110;relay.sensor.hitX=110;relay.vx=-.6
 r=observe(w)
 check(r.c1.chain_enemies==1,'newly arriving relay enlarged an original-chain promise')
 -- Identical template records represent two emitted cards, not duplicate geometry.
 w.enemies[2]=nil;target.sensor.health=60
 local shots=w.player.sensor.c1Profile.shots
 shots[2]={};for k,v in pairs(shots[1]) do shots[2][k]=v end
 shots[3],shots[4]=nil,nil
 check(observe(w).c1.has_ignition,'identical independent template cards were merged')
 -- Warm-up/charge lead is an integer update count included in impact delay.
 w.player.currentCharge=98;w.player.chargeSpeed=3
 local delayed=observe(w)
 w.player.currentCharge=100
 check(delayed.c1.kill_delay==observe(w).c1.kill_delay+1,'fractional charge lead was not rounded to a full update')
end
-- Independent attacks in one update aggregate before integer resistance;
-- attacks in different updates must each undergo that reduction.
do
 local target=enemy('rounding',0,240,15,true,true)
 target.sensor.shotDamageDivisor=4
 local w=world(target)
 local function card(tick)
  return {supported=false,motionModel='reimu_c1_homing',spawnTick=tick,offsetX=0,offsetY=-80,
   width=4,height=4,angle=0,speed=0,damage=30,type=0}
 end
 local q=w.player.sensor.c1Profile
 q.homingTargetValid=false;q.shots={card(0),card(1)}
 check(not observe(w).c1.has_ignition,'damage was aggregated across different game updates before resistance')
 q.shots[2].spawnTick=0
 check(observe(w).c1.has_ignition,'same-update damage was not aggregated before resistance')
end

-- Once an early seed consumes its connected component, another planned
-- direct hit on a member cannot explode that same member again for late whites.
do
 local early,late=enemy('early',-30,240,30),enemy('late',30,240,30)
 local w=world(early);w.enemies[2]=late
 local q=w.player.sensor.c1Profile;q.homingTargetValid=false
 local function card(x,tick)
  return {supported=false,motionModel='reimu_c1_homing',spawnTick=tick,offsetX=x,offsetY=-80,
   width=4,height=4,angle=0,speed=0,damage=30,type=0}
 end
 q.shots={card(-30,0),card(30,20)}
 w.bullets={{id=1,enabled=true,x=0,y=160,vx=0,vy=4,isErasable=true}}
 local r=observe(w).c1
 check(r.has_ignition and r.chain_enemies==2 and r.kill_count==1,
  'a component member already consumed by the first chain was used as another independent seed')
 check(r.chain_bullets==0,'late white was credited to a second explosion of an already consumed chain')
end

-- Current damage-ready geometry needs no future homing state. Unknown
-- active callbacks and unknown native slot identities still earn no credit.
do
 local target=enemy('now',0,240,30)
 local w=world(target);local q=w.player.sensor.c1Profile
 q.homingStateValid=false
 q.activeShots={{slotId=1,supported=false,damageReady=true,type=0,damage=999,
  x=0,y=240,width=48,height=48}}
 check(not observe(w).c1.has_ignition,'unknown active callback earned direct damage credit')
 q.activeShots[2]={slotId=2,supported=true,damageReady=true,type=0,damage=30,
  x=0,y=240,width=48,height=48}
 local r=observe(w).c1
 check(r.has_ignition and r.remaining_only and r.contact_count==1,
  'known current card was lost with future homing state or the unknown card was included')
end

-- The delayed alternative cannot replace the current seed's original chain
-- with a disconnected group which arrives in the same firing lane later.
do
 local original,new,relay=enemy('original',0,240,30),enemy('new',90,240,30),enemy('relay2',120,240,30)
 original.vx,new.vx,relay.vx=-4,-4,-4
 local w=world(original);w.enemies={original,new,relay}
 local q=w.player.sensor.c1Profile;q.homingTargetValid=false
 q.shots={{supported=false,motionModel='reimu_c1_homing',spawnTick=0,offsetX=0,offsetY=-80,
  width=4,height=4,angle=0,speed=0,damage=30,type=0}}
 w.bullets={{id=1,enabled=true,x=70,y=240,vx=0,vy=0,isErasable=true}}
 local r=observe(w).c1
 check(r.has_ignition and r.chain_enemies==1 and r.chain_bullets==0,'original-chain fixture did not isolate current A')
 check(not r.future_has_ignition and r.future_enemies==0 and r.future_bullets==0,
  'delayed C1 alternative borrowed unrelated incoming B/C chain')
end
-- Compare the broad-phase bins against a reference that puts EVERY enemy in
-- the existing exact-scan fallback. This isolates filtering correctness from
-- the separately checked trajectory/damage model; no production source edit.
do
 local file=assert(io.open('bloom_observer.lua','r'));local source=file:read('*a');file:close()
 local full_source,replacements=source:gsub('if %(x2%-x1%+1%)%*%(y2%-y1%+1%)>128 then','if true then',1)
 check(replacements==1,'full-scan reference did not replace the expected spatial cutoff')
 local fullscan=assert(loadstring(full_source,'reimu-grid-fullscan-reference'))()
 for scene=1,18 do
  local anchor=enemy('anchor',(scene*13)%140-70,170,30)
  local w=world(anchor)
  for i=1,31 do
   local e=enemy(i,(i*31+scene*7)%320-160,20+(i*23+scene*11)%420,i%7==0 and 30 or 9999,
    i%4==0,i%8==0)
   e.vx,e.vy=i%9-4,i%7-3
   if scene%3==0 and i%5==0 then e.vx,e.vy=100,-100 end
   e.sensor.shotCollisionEnabled=i%6~=0;e.sensor.hitWidth,e.sensor.hitHeight=4+i%5,4+i%7
   w.enemies[#w.enemies+1]=e
  end
  for i=1,80 do w.bullets[i]={id=i,enabled=true,x=(i*37)%272-136,y=20+(i*17)%380,
   vx=i%3-1,vy=.5,isErasable=true} end
  local a,b=observe(w),fullscan.observe(w,{}, {prediction_frames=20})
  for _,section in ipairs({'c1','c1_position'}) do
   for _,field in ipairs({'damage_model_valid','has_ignition','kill_count','contact_count','kill_delay',
     'chain_enemies','chain_bullets','future_has_ignition','future_enemies','future_bullets'}) do
    check(a[section][field]==b[section][field],
     'spatial filter disagrees with full scan scene '..scene..' '..section..'.'..field)
   end
  end
 end
 -- A fast diagonal target spans more than 128 cells and crosses the card in
 -- one update. Negative/positive adjacent cells also keep expanded hitboxes.
 for _,case in ipairs({{100,140,-100,100,0},{63,240,0,0,65},{-63,240,0,0,-65}}) do
  local target=enemy('crossing',case[1],case[2],30);target.vx,target.vy=case[3],case[4]
  local w=world(target);w.player.x=case[5]
  local q=w.player.sensor.c1Profile;q.homingTargetValid=false
  q.shots={{supported=false,motionModel='reimu_c1_homing',spawnTick=0,offsetX=0,offsetY=-80,
   width=4,height=4,angle=0,speed=0,damage=30,type=0}}
  local a,b=observe(w).c1,fullscan.observe(w,{}, {prediction_frames=20}).c1
  check(a.has_ignition and a.kill_count==1 and a.kill_count==b.kill_count,
   'wide/adjacent-cell target escaped conservative broad-phase bounds')
 end
end
print('reimu_c1_observer_test: PASS ('..checks..' assertions; damage/trajectory fixtures, no live-game claim)')
