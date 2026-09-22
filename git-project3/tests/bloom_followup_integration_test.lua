-- Real observer -> policy -> dodge regression for the user's left-capture
-- feedback. No game process and no claim of simulated return/energy physics.
HitType={Rect=0,Circle=1,RotatableRect=2}; ExAttackType={Medicine=16}
local observer,bloom,dodge=dofile('bloom_observer.lua'),dofile('bloom.lua'),dofile('dodge.lua')
local cfg=dofile('config.lua');local checks=0
local function check(ok,msg) checks=checks+1;assert(ok,msg) end
local function enemy(id,x,y,spirit)
 return {id=id,x=x,y=y,vx=0,vy=0,enabled=true,isSpirit=spirit==true,
  isActivatedSpirit=false,isBoss=false,isLily=false,isPseudoEnemy=false}
end
local function bullet(id,x,y,vx,vy)
 return {id=id,x=x,y=y,vx=vx or 0,vy=vy or 0,enabled=true,isErasable=true}
end
local function world(es,bs,energy)
 return {player={x=0,y=320,life=5,currentCharge=0,currentChargeMax=energy or 0,
  chargeSpeed=10,speedFast=4,speedSlow=2,
  sensor={apiVersion=1,valid=true,state=0,timeScale=1,canCharge=true,chargeWarmupFrames=11,
   protectionFrames=0,baseScaleX=1,baseScaleY=1,moveScaleX=1,moveScaleY=1,poisonClouds={}},
  hitBodyRect={type=HitType.Rect,width=4,height=4},hitBodyCircle={type=HitType.Circle,radius=2}},
  enemies=es or {},bullets=bs or {},exAttacks={}}
end
local function step(w,s,os,ds)
 os.lock_ids=(s.target_level or (s.shot_remaining or 0)>0) and s.attack_ids or s.prepare_ids
 local oc={};for k,v in pairs(cfg.bloom.observer) do oc[k]=v end
 oc.prediction_frames=31;oc.release_min_y=150
 local o=observer.observe(w,os,oc)
 local p=bloom.update(w,s,cfg.bloom,o)
 local d=dodge.choose(w,ds,cfg.dodge,p.intent)
 bloom.feedback(s,d,cfg.bloom)
 check(p.target_level>=0 and p.target_level<=2,'selected unsupported C level')
 return o,p,d
end
for role=0,15 do
 local w=world({enemy('fairy',0,240),enemy('spirit',-50,240,true)},{bullet('white',0,240)},0)
 w.player.character=role
 local s,os,ds={fast_frames=100},{},{}
 local o,p,d=step(w,s,os,ds)
 check(o.capture.preferred and p.reason=='approach_capture','still fires before lateral capture approach')
 check(d.vx<0 and not d.focus and not p.press_z,'safe fast approach not executed')
 w.player.x=-10
 o,p,d=step(w,s,os,ds)
 check(p.intent.focus and not p.press_z and d.vx<0,'existing preparation lock blocked aligned capture')
end
-- C2 energy cannot steal a valuable capture goal when actual C2 yield is poor.
for _,energy in ipairs({0,200,400}) do
 local w=world({enemy('spirit',-80,220,true)},{},energy)
 local o,p,d=step(w,{fast_frames=100},{},{})
 check(p.intent.target_x==-80 and d.vx<0 and p.target_level==0,'energy displaced capture with unqualified C2')
end
-- Forty whites around the pure-spirit group now increase its opportunity
-- value, even with an ordinary shootable fairy competing on the right.
do
 local w=world({enemy('fairy',50,230),enemy('s1',-90,230,true),
  enemy('s2',-90,250,true),enemy('s3',-90,210,true)},{},0)
 local o1=observer.observe(w,{},cfg.bloom.observer)
 for i=1,40 do w.bullets[#w.bullets+1]=bullet(i,-90,230) end
 local o2,p,d=step(w,{fast_frames=100},{},{})
 check(o2.capture.value>o1.capture.value,'pure spirits still ignore white overlap')
 check(p.intent.target_x<0 and d.vx<0 and not p.press_z,'valuable left group loses to right ordinary target')
end
-- A vanished locked capture group is not replenished by unrelated newly
-- arriving spirits. Old resource IDs must be retired before a fresh plan.
do
 local w=world({enemy('old',-80,220,true)},{},0)
 local s,os,ds={fast_frames=100},{},{}
 step(w,s,os,ds)
 w.enemies={enemy('new',80,220,true)}
 local o,p=step(w,s,os,ds)
 check(not o.capture.has_target,'locked capture migrated to unrelated nodes')
 check(not p.press_z,'lost chain invented an ignition')
end
-- A verified wide C1 can ignite more than the local capture group. The old
-- ordinary-focus fallback must honor the observer's explicit C1 preference.
do
 local w=world({enemy('a',0,240),enemy('s',0,240,true),enemy('b',90,240),enemy('c',100,240)},{},100)
 for i=1,30 do w.bullets[i]=bullet(i,i<=20 and 0 or 100,240) end
 local q=w.player.sensor
 q.followupApiVersion=1;q.canPressZ=true;q.c1ActionActive=false;q.c1ActionAge=0;q.c1ActionDuration=30
 q.c1Profile={valid=true,limited=false,activeValid=true,activeShots={},actionDuration=30,
  shots={{supported=true,spawnTick=0,offsetX=0,offsetY=-80,width=220,height=60,
   angle=0,speed=0,type=3,damage=1}}}
 local o,p=step(w,{fast_frames=100},{},{})
 check(not o.capture.preferred and o.c1.value>o.capture.value,'wide C1 fixture did not favor immediate attack')
 check(p.target_level==1 and p.press_z and not p.intent.focus,'legacy focus stole independently preferred C1')
 w.player.currentChargeMax=0;w.enemies[2].x=-50
 o,p=step(w,{fast_frames=100},{},{})
 check(o.capture.preferred_before_c1 and p.reason=='approach_capture' and p.intent.target_x<0,
  'unfunded C1 opportunity displaced viable lateral capture')
end
print('bloom_followup_integration_test: PASS ('..checks..' assertions; actual observer-policy-dodge, 16 roles)')
