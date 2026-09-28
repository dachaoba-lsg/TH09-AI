-- v2.0.8 direction-only poison preference. Synthetic snapshots only.
-- The collision oracle remains the existing swept geometry; poison is terrain.
HitType={Rect=0,Circle=1,RotatableRect=2}; ExAttackType={Medicine=16,Eiki=19}
local dodge=dofile('dodge.lua')
local checks=0
local function check(v,m) checks=checks+1;assert(v,m) end
local function near(a,b,m) check(type(a)=='number' and math.abs(a-b)<1e-7,
 (m or 'value')..': '..tostring(a)..' vs '..tostring(b)) end
local function copy(t) local r={} for k,v in pairs(t) do r[k]=v end return r end
local function config(enabled)
 local c=dofile('config.lua').dodge;c.poison_escape_enabled=enabled~=false;return c
end
local function cloud(x,y,age)
 age=age or 100
 return {x=x or 0,y=y or 320,radius=64,age=age,ageInt=math.floor(age),
  active=math.floor(age)>20 and math.floor(age)<300,framesLeft=math.max(0,300-age)}
end
local function snapshot(clouds,scale)
 return {apiVersion=1,valid=true,state=0,protectionFrames=0,cutIn=false,
  timeScale=1,movementEnabled=true,baseScaleX=1,baseScaleY=1,
  moveScaleX=scale or .4,moveScaleY=scale or .4,poisonClouds=clouds or {cloud(20)}}
end
local function world(s,x,y,bullets)
 return {player={x=x or 0,y=y or 320,speedFast=4,speedSlow=2,sensor=s,
  hitBodyRect={type=0,width=4,height=4},hitBodyCircle={type=1,radius=2}},
  bullets=bullets or {},enemies={},exAttacks={}}
end
local function bullet(x,y,vx,vy,w,h)
 return {vx=vx or 0,vy=vy or 0,hitBody={type=0,x=x,y=y,width=w or 4,height=h or 4}}
end
local function intent(focus,x,y,protected)
 return {focus=focus==true,focus_mismatch_cost=8,target_x=x or 100,target_y=y or 320,
  position_weight=.002,min_y=150,protected_followup=protected==true}
end
local function choose(w,enabled,i,st,cfg)
 return dodge.choose(w,st or {},cfg or config(enabled),i)
end
local function same(a,b,label)
 for _,k in ipairs({'name','key','focus','collides','danger','cost','vx','vy',
  'terminal_x','terminal_y','terrain_cost','position_cost','intent_cost',
  'protected_route_checked','protected_route_safe','protected_route_collides'}) do
  check(a[k]==b[k],label..' changed '..k..': '..tostring(a[k])..' vs '..tostring(b[k]))
 end
end
local function safe(w,i,st)
 local baseline=choose(w,false,nil,copy(st or {}))
 local original=choose(w,false,i,copy(st or {}))
 local r=choose(w,true,i,copy(st or {}))
 check(r.focus==original.focus,'poison changed the original final Shift decision')
 if not original.collides then
  check(not r.collides,'low concentration bought a collision')
  check(r.danger<=baseline.danger+5.6+1e-7,'poison stacked another soft-risk budget')
  check(r.terrain_cost<=baseline.terrain_cost+1e-7,'low concentration bought wall exposure')
 else same(r,original,'all candidates collide') end
 if original.protected_route_checked then
  if original.protected_route_safe then check(r.protected_route_safe,'poison lost a proven protection-expiry exit')
  else same(r,original,'no proven protection-expiry exit') end
 end
 return r,original,baseline
end

-- A valid active cloud can alter direction but must retain the exact focus
-- state selected by the existing bloom/dodge policy, including slow capture.
do
 local w=world(snapshot())
 for _,focus in ipairs({false,true}) do
  local r,old=safe(w,intent(focus))
  check(old.terminal_x>0,'clear resource-alignment fixture changed')
  check(r.poison_preference and r.poison_escape_changed,'deep-cloud preference did not engage')
  check(r.terminal_x<0,'did not head toward the nearest active-cloud boundary')
  check(r.poison_layers_now==1 and r.poison_layers_end==1,'deep-cloud layer count changed')
  near(r.poison_exposure,1,'deep-cloud mean layers')
  check(r.poison_depth<44,'same-layer depth failed to guide a short route')
 end
 -- Nil bloom intent still benefits from the terrain preference.
 local r=safe(w)
 check(r.terminal_x<0 and not r.focus,'nil-intent poison escape missing')
end

-- Less poison means fewer strict-radius active-cloud overlaps. Escape one
-- layer of a stack even when the limited forecast cannot leave all layers.
do
 local r=safe(world(snapshot({cloud(60)},.4)),intent(false))
 check(r.poison_layers_end==0 and r.poison_exposure<1 and r.terminal_x<-30,
  'edge route did not leave poison and regain real speed')
 local stack=world(snapshot({cloud(0),cloud(60)},.16))
 r=safe(stack,intent(false))
 check(r.poison_layers_now==2 and r.poison_layers_end==1 and r.poison_exposure<2,
  'did not descend from two cloud layers to one')
 check(r.terminal_x<0,'stack escape moved into thicker poison')
 -- Do not use a fixed 0.25px improvement threshold: six layers can move less
 -- than that during the entire forecast, but still need an escape direction.
 local clouds={} for i=1,6 do clouds[i]=cloud(20) end
 r=safe(world(snapshot(clouds,.4^6)),intent(false))
 check(r.terminal_x<0 and math.abs(r.terminal_x)<.25,
  'very thick poison lost its subpixel boundary direction')
 check(r.poison_layers_now==6 and r.poison_layers_end==6,'six-layer count mismatch')
end

-- Current native activation is authoritative. Entering future/nearby fog
-- alone does not turn this optimization into a general positional rewrite.
do
 local variants={
  {label='no sensor'},
  {label='empty',s=snapshot({},1)},
  {label='outside strict radius',s=snapshot({cloud(64)},1)},
  {label='young cloud',s=snapshot({cloud(0,320,0)},1)},
  {label='age twenty',s=snapshot({cloud(0,320,20)},1)},
  {label='expired',s=snapshot({cloud(0,320,300)},1)},
  {label='native inactive',s=snapshot({cloud(0)},1)},
 }
 variants[#variants].s.poisonClouds[1].active=false
 local mutations={
  {'invalid sensor','valid',false},{'unknown API','apiVersion',2},
  {'cut-in','cutIn',true},{'stopped time','timeScale',0},
  {'fractional time','timeScale',.5},{'unavailable time','timeScale',false},
  {'movement disabled','movementEnabled',false},
 }
 for _,v in ipairs(mutations) do
  local s=snapshot();s[v[2]]=v[3];variants[#variants+1]={label=v[1],s=s}
 end
 for _,v in ipairs(variants) do
  local w=world(v.s)
  local r=choose(w,true,intent(false))
  same(r,choose(w,false,intent(false)),v.label)
  check(not r.poison_preference and not r.poison_escape_changed,v.label..' activated preference')
 end
 -- A malformed future record cannot invent a gradient or crash evaluation.
 for _,bad in ipairs({{x=0/0,y=320,radius=64,framesLeft=100,active=true},
  {x=0,y=320,radius=math.huge,framesLeft=100,active=true},
  {x=0,y=320,radius=64,framesLeft=-1,active=true}}) do
  local w=world(snapshot({bad},1))
  same(choose(w,true,intent(false)),choose(w,false,intent(false)),'invalid cloud')
 end
end

-- The first update and every endpoint still use native current factors,
-- lifetimes and real wall clipping. Protection does not remove poison.
do
 local s=snapshot({cloud(20,320,299)},.4)
 local r=safe(world(s),intent(false))
 check(r.poison_layers_end==0,'expired cloud persisted at the route endpoint')
 near(r.poison_exposure,1/12,'last update of poison lifetime')
 near(math.sqrt(r.vx*r.vx+r.vy*r.vy),1.6,'first-update native slowdown')
 s=snapshot({cloud(20)},.4);s.state,s.protectionFrames=3,48
 r=safe(world(s),intent(false,100,320,true))
 check(r.poison_preference and r.poison_layers_now==1 and r.protected_route_safe,
  'real C2 protection removed poison or its safe endpoint check')
 near(math.sqrt(r.vx*r.vx+r.vy*r.vy),1.6,'protected poison speed')
end

-- Real bullets, other EX and expiry hazards always win over a lower-poison
-- destination. Poison itself keeps its non-damaging compatibility semantics.
do
 local w=world(snapshot(),0,320,{bullet(-10,320,0,0,4,400)})
 local r=safe(w,intent(false))
 check(not r.collides and r.terminal_x>=-6-1e-7,'escaped poison through a damaging wall')
 w=world(snapshot(),0,320,{bullet(0,320,0,0,500,500)})
 r=safe(w,intent(false))
 check(r.collides and not r.poison_preference,'all-collision escape ranking replaced')
 w=world(snapshot());w.exAttacks={{type=ExAttackType.Medicine,hittable=true,
  hitBody={type=1,x=0,y=320,radius=64}}}
 r=safe(w,intent(false));check(not r.collides,'Medicine terrain became a hit')
 w.exAttacks[1].type=ExAttackType.Eiki
 r=safe(w,intent(false));check(r.collides,'Eiki EX lost its real hitbox')
 local s=snapshot();s.state,s.protectionFrames=3,48
 w=world(s,0,320,{bullet(0,320,0,0,500,500)})
 r=safe(w,intent(false,100,320,true))
 check(r.protected_route_checked and not r.protected_route_safe and not r.poison_preference,
  'failed protection-expiry search acquired a low-poison safe claim')
 -- Preferred negative-X endpoint is covered as actual protection expires.
 w=world(s,0,320,{bullet(-19.2,224,0,2)})
 r=safe(w,intent(false,100,320,true))
 check(r.protected_route_safe and r.name~='fast-left','low-poison endpoint ignored expiry bullet')
end

-- Height policy is unchanged even if upward or wallward is the shortest way
-- out. A sensor cannot create movement through the physical field boundary.
do
 for _,y in ipairs({150,151,100}) do
  local w=world(snapshot({cloud(0,y+20)},.4),0,y)
  local r=safe(w,intent(false,0,100))
  check(y+r.vy>=math.min(y,150)-1e-7,'poison violated next-input height policy')
 end
 local w=world(snapshot({cloud(-100)},.4),-132,320)
 local r=safe(w,intent(false,-130))
 check(r.terminal_x>=-136 and r.terminal_x<=136,'escape crossed physical X wall')
 for _,part in ipairs(r.segments) do
  check(part.x>=-136 and part.x+part.vx*part.duration>=-136-1e-7,'trajectory tunneled through X wall')
 end
end

-- Deterministic varied hazards: a new terrain preference may change a route,
-- but never its original final Shift state, hard safety or single soft budget.
do
 local seed=20809
 local function rand(n) seed=(seed*48271)%2147483647;return seed%n end
 for scene=1,240 do
  local x,y=rand(201)-100,155+rand(235)
  local clouds={cloud(x+rand(61)-30,y+rand(61)-30)}
  if scene%3==0 then clouds[2]=cloud(x+rand(81)-40,y+rand(81)-40) end
  local s=snapshot(clouds,.4^#clouds)
  if scene%5==0 then s.state,s.protectionFrames=3,48 end
  local objects={} for n=1,9 do objects[n]=bullet(x+rand(121)-60,y+rand(121)-60,rand(9)-4,rand(9)-3) end
  local w=world(s,x,y,objects)
  local i=intent(scene%2==0,rand(241)-120,150+rand(251),scene%5==0)
  local st={last_move_key=({0,16,32,64,128})[1+rand(5)]}
  local r=safe(w,i,st)
  check(r.cost==r.cost and r.poison_exposure==r.poison_exposure,'nonfinite poison score')
  check(r.movement_segments<=18*14,'poison preference altered bounded movement integration')
  -- Disable/empty snapshots exercise zero-poison behavior across the same
  -- hazard scene, input history and bloom target without golden key fixtures.
  w.player.sensor=snapshot({},1)
  same(choose(w,true,i,copy(st)),choose(w,false,i,copy(st)),'zero-poison scene '..scene)
 end
end
print('poison_preference_test: PASS '..checks..' assertions')
