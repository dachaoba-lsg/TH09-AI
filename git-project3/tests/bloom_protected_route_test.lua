-- Confirmed post-C2 intent: real protection, bounded expiry endpoint checks.
-- No game process, input, predicted cancellation, or native state changes.
HitType={Rect=0,Circle=1,RotatableRect=2};ExAttackType={Medicine=16}
local dodge=dofile('dodge.lua')
local checks=0
local function check(v,m) checks=checks+1;assert(v,m) end
local function near(a,b,m) check(math.abs(a-b)<1e-7,(m or 'value')..': '..tostring(a)..' vs '..tostring(b)) end
local function cfg() return dofile('config.lua').dodge end
local function copy(t) local r={} for k,v in pairs(t) do r[k]=v end return r end
local function sensor(frames)
 return {apiVersion=1,valid=true,state=3,protectionFrames=frames or 48,
  moveScaleX=1,moveScaleY=1,baseScaleX=1,baseScaleY=1,poisonClouds={},
  cutIn=false,timeScale=1,movementEnabled=true}
end
local function world(objects,s,y)
 return {player={x=0,y=y or 320,speedFast=4,speedSlow=2,sensor=s or sensor(),
  hitBodyRect={type=0,width=4,height=4},hitBodyCircle={type=1,radius=2}},
  bullets=objects or {},enemies={},exAttacks={}}
end
local function bullet(x,y,vx,vy,w,h)
 return {isErasable=true,vx=vx or 0,vy=vy or 0,
  hitBody={type=0,x=x,y=y,width=w or 4,height=h or 4}}
end
local function laser(x,y,length,height,angle,id)
 return {id=id or 91,enabled=true,vx=0,vy=0,
  hitBody={type=2,x=x,y=y,width=length,height=height,angle=angle or 0}}
end
local function intent(flag,x,y)
 return {protected_followup=flag,min_y=150,focus=false,target_x=x or 100,target_y=y or 320,
  position_weight=.002,focus_mismatch_cost=8}
end
local function choose(w,flag,state,i) return dodge.choose(w,state or {},cfg(),i or intent(flag)) end
local function trajectory(r,h)
 local tail=r.segments[#r.segments]
 near(tail.start+tail.duration,h or 12,'movement forecast was lengthened')
 near(r.terminal_x,tail.x+tail.vx*tail.duration,'movement endpoint x changed')
 near(r.terminal_y,tail.y+tail.vy*tail.duration,'movement endpoint y changed')
end
local function same(a,b,label)
 for _,k in ipairs({'key','vx','vy','danger','cost','collides','terminal_x','terminal_y','terrain_cost'}) do
  check(a[k]==b[k],label..' changed '..k)
 end
end

-- Keep useful movement during protection, then reserve its actual 12-update
-- endpoint. Never run the nominal direction for the whole protection period.
do
 local w=world()
 local old=choose(w,false)
 local r=choose(w,true)
 check(r.protected_route_checked and r.protected_route_safe,'empty-field protection route missing')
 check(r.protected_route_horizon==51,'wrong conservative expiry plus four-update margin')
 check(r.name=='fast-right' and r.terminal_x==48,'long shield became a long constant-direction path')
 same(r,old,'safe route')
 trajectory(r)
end

-- This bullet is far outside the short forecast and reaches the intended
-- endpoint as protection expires. The flag must reject that endpoint, while
-- staying inside the original collision-free/terrain/soft-risk candidate set.
do
 local w=world({bullet(48,224,0,2)})
 local old=choose(w,false)
 local r=choose(w,true)
 check(old.name=='fast-right' and not old.collides,'late-arrival fixture malformed')
 check(r.protected_route_checked and r.protected_route_safe,'failed to find a protected exit')
 check(r.name~='fast-right' and r.protected_route_rejected>0,'late-arrival endpoint kept')
 check(not r.collides and r.danger<=old.danger+5.6,'future exit bought current danger')
 check(r.terrain_cost<=old.terrain_cost+1e-9,'future exit bought wall exposure')
 trajectory(r)
 -- Safety does not depend on whether the resource observer calls it white.
 w.bullets[1].isErasable=false
 same(choose(w,true),r,'nonerasable bullet')
end

-- Real persistent lasers and damaging EX remain after protection ends.
-- Crossing them while protected can be legal; ending inside cannot win when
-- a same-risk reachable endpoint outside them exists.
do
 for kind=1,2 do
  local w=world()
  if kind==1 then w.bullets={laser(-136,320,272,8)}
  else w.exAttacks={{type=99,hittable=true,vx=0,vy=0,
    hitBody={type=1,x=0,y=320,radius=16}}} end
  local r=choose(w,true)
  check(r.protected_route_checked and r.protected_route_safe,'persistent hazard exit unavailable')
  check(not r.collides and r.protected_route_rejected>0,'persistent hazard ignored')
  if kind==1 then check(math.abs(r.terminal_y-320)>6,'laser endpoint remains inside')
  else check(r.terminal_x^2+(r.terminal_y-320)^2>18^2,'EX endpoint remains inside') end
 end
 -- No resource reward can invent a safe destination when all are covered.
 local w=world({bullet(0,320,0,0,500,500)})
 local geometric=dodge.choose(w,{},cfg())
 local r=choose(w,true)
 check(r.protected_route_checked and not r.protected_route_safe and r.protected_route_collides,
  'all-blocked endpoint was advertised safe')
 check(r.key==geometric.key and r.intent_cost==0,'resources replaced immediate escape on all-blocked endpoints')
end

-- Continuous measured laser translation is reused from the same prior
-- snapshot. The extra pass must not consume history twice or use stale motion.
do
 local a,b={frame=1},{frame=1}
 choose(world({laser(97,200,240,4,math.pi/2)}),false,a)
 choose(world({laser(97,200,240,4,math.pi/2)}),true,b)
 a.frame,b.frame=2,2
 local w=world({laser(96,200,240,4,math.pi/2)})
 local old=choose(w,false,a)
 local r=choose(w,true,b)
 check(old.name=='fast-right' and not old.collides,'moving-laser fixture malformed')
 check(r.name~='fast-right' and r.protected_route_safe,'moving laser absent from expiry check')
 check(r.dynamic_lasers==1 and b.laser_history[91].frame==2,'extra check mutated laser history')
 trajectory(r)
end

-- Warning lasers keep their soft warning throughout the extra tail, even
-- when their passage would finish before the real protection timer expires.
-- Hard collision tangency AT expiry remains inclusive after broad-phase cull.
do
 local beam=laser(-136,200,272,0);beam.vy=4
 local w=world({beam});w.player.speedFast,w.player.speedSlow=0,0
 local r=choose(w,true)
 check(r.protected_route_checked and r.protected_route_safe and not r.protected_route_collides,
  'warning acquired hard collision')
 check(r.protected_route_danger>0,'protection silently removed future laser warning')
 w=world({bullet(0,230,0,2)},sensor(48));w.player.speedFast,w.player.speedSlow=0,0
 r=choose(w,true)
 check(r.protected_route_collides and not r.protected_route_safe,'expiry tangency omitted')
 w.player.sensor.protectionFrames=48.9
 check(choose(w,true).protected_route_collides,'fractional timer granted an extra update')
 w.player.sensor.protectionFrames=49
 r=choose(w,true)
 check(r.protected_route_safe and not r.protected_route_collides,'fully protected earlier passage remained hard')
 w=world(nil,sensor(57))
 r=choose(w,true)
 check(r.protected_route_checked and r.protected_route_horizon==60,'supported horizon limit omitted')
 w.player.sensor.protectionFrames=58
 check(not choose(w,true).protected_route_checked,'extension exceeded bounded horizon')
end

-- Poison determines the real short endpoint. An incoming bullet at the
-- slowed endpoint cannot be evaded using a fictitious full-speed endpoint.
do
 local s=sensor();s.moveScaleX,s.moveScaleY=.4,.4
 s.poisonClouds={{x=0,y=320,radius=64,age=100,framesLeft=200,active=true}}
 local w=world({bullet(19.2,224,0,2)},s)
 local old=choose(w,false)
 near(old.terminal_x,19.2,'poison fixture endpoint')
 local r=choose(w,true)
 check(r.protected_route_safe and r.name~='fast-right','nominal endpoint hid poisoned expiry hazard')
 check(r.poison_clouds==1 and math.abs(r.vx)<=1.6+1e-9,'protection removed poison')
 trajectory(r)
end

-- No time window comes from a requested C2 or a fabricated circle. Invalid,
-- missing, non-state3, expired, fractional-time and over-bound inputs preserve
-- the old movement result. Last raw timer units cannot grant extra protection.
do
 local variants={}
 local s=sensor();s.valid=false;variants[#variants+1]=s
 s=sensor();s.apiVersion=2;variants[#variants+1]=s
 s=sensor();s.state=4;variants[#variants+1]=s
 s=sensor(0);variants[#variants+1]=s
 s=sensor(1);variants[#variants+1]=s
 s=sensor(1.5);variants[#variants+1]=s
 s=sensor();s.cutIn=true;variants[#variants+1]=s
 s=sensor();s.timeScale=0;variants[#variants+1]=s
 s=sensor();s.timeScale=.5;variants[#variants+1]=s
 s=sensor();s.movementEnabled=false;variants[#variants+1]=s
 s=sensor(100);variants[#variants+1]=s
 for n,v in ipairs(variants) do
  local w=world({bullet(48,224,0,2)},v)
  local r=choose(w,true)
  same(r,choose(w,false),'invalid/inapplicable protection '..n)
  check(not r.protected_route_checked and not r.protected_route_safe,'inapplicable window claimed safe')
 end
 local w=world();w.player.sensor=nil
 same(choose(w,true),choose(w,false),'missing sensor')
 s=sensor(13);w=world({bullet(0,320,0,0,500,500)},s)
 local r=choose(w,true)
 check(r.collides and not r.protected_route_safe,'expiry at normal horizon ceased to be a collision')
end

-- Height remains a next-real-update policy limit, not a new physical wall.
-- Above the line, retain the existing gradual descent instead of demanding
-- an endpoint that cannot be reached within one short forecast.
do
 for _,y in ipairs({150,151,153}) do
  local w=world(nil,nil,y)
  local r=choose(w,true,nil,intent(true,100,16))
  check(y+r.vy>=150-1e-9,'protected followup crossed the hard height line')
  check(r.height_limited,'missing height limit')
  trajectory(r)
 end
 local w=world(nil,nil,100)
 local old=choose(w,false,nil,intent(false,100,16))
 local r=choose(w,true,nil,intent(true,100,16))
 check(r.vy>0 and not r.protected_route_checked,'expiry endpoint prevented height recovery')
 same(r,old,'above-line recovery')
end

-- Outside the opted-in real protection window, preserve all old decision
-- outputs across distinct geometry, speeds, heights and movement history.
do
 local seed=25801
 local function rand(n) seed=(seed*48271)%2147483647;return seed%n end
 for scene=1,180 do
  local s=sensor();s.state=0;s.protectionFrames=0
  local w=world({},s,150+rand(251))
  w.player.x=rand(201)-100
  for i=1,12 do w.bullets[i]=bullet(rand(273)-136,rand(449),rand(11)-5,rand(9)-2) end
  local st={last_move_key=({0,16,32,64,128})[1+rand(5)]}
  local i=intent(true,rand(241)-120,150+rand(251))
  local j=copy(i);j.protected_followup=nil
  same(choose(w,true,copy(st),i),choose(w,false,copy(st),j),'legacy scene '..scene)
  -- A nil intent must remain independent of the new feature entirely.
  local a=dodge.choose(w,copy(st),cfg())
  check(not a.protected_route_checked and not a.protected_route_safe,'nil intent activated route planning')
 end
end
print('bloom_protected_route_test: PASS '..checks..' assertions')
