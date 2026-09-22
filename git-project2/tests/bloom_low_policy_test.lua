-- Behavioral regressions for lower bloom positioning and erasure efficiency.
local bloom = dofile('bloom.lua')
local cfg = dofile('config.lua').bloom
local function world()
  return {player={x=0,y=320,life=10,currentCharge=0,currentChargeMax=400,
    chargeSpeed=10,sensor={state=0,canCharge=true,timeScale=1,chargeWarmupFrames=0}}}
end
local function observation()
  return {valid=true,has_target=true,has_ignition=true,ignition_aligned=true,
    target_x=0,target_y=110,chain_score=8,chain_enemies=4,chain_bullets=30,
    future_score=8,ignition_id=1,chain_ids={1,2,3,4},
    c2={has_ignition=true,future_has_ignition=true,target_x=0,target_y=320,
      chain_score=8,chain_enemies=4,chain_bullets=30,chain_ids={1,2,3,4},
      future_score=8,future_enemies=4,future_bullets=30,
      direct_bullets=0,contested_bullets=0},
    c2_position={has_ignition=true,target_x=48,target_y=416,
      chain_bullets=40,direct_bullets=0,contested_bullets=0,improvement=2}}
end
local function step(w,s,o) return bloom.update(w,s,cfg,o) end
for id=0,15 do
  local w,s,o=world(),{},observation(); w.player.character=id
  local r=step(w,s,o)
  assert(r.target_level==2 and r.intent.target_y==416 and r.intent.target_x==48)
  assert(r.intent.min_y==150)
  w.player.currentCharge=200
  r=step(w,s,o)
  assert(r.phase=='release' and r.release_c2==1 and not r.press_z,
    'full C2 waited for an unreachable prettier release point')
  assert(r.intent.target_y==416, 'release frame lost the lower position intent')
end
do
  local w,o=world(),observation()
  o.c2.direct_bullets,o.c2.contested_bullets=100,100
  local r=step(w,{},o)
  assert(r.target_level==1 and r.intent.target_y==320,
    'erasure-dominated early C2 displaced a useful C1 or pulled it upward')
  w.player.currentChargeMax=0
  r=step(w,{},o)
  assert(r.phase=='shot' and r.intent.target_y==320,
    'ordinary firing chased a high ignition target')
end
do
  local w,o,s=world(),observation(),{since_c2=479,since_c=0}
  o.c2.direct_bullets=10000
  local r=step(w,s,o)
  assert(r.target_level==2 and r.cadence_charge,
    'swallow avoidance postponed the independent C2 deadline')
  w.player.currentCharge=200
  r=step(w,s,o)
  assert(r.release_c2==1 and r.since_c2==0 and not r.press_z)
end
do
  local w,o=world(),observation()
  o.has_target,o.has_ignition=false,false
  o.c2.has_ignition=false
  local r=step(w,{},o)
  assert(r.target_level==0 and not r.press_z and r.intent.target_y==416,
    'a suggested remote point funded an attack at the actual empty point')
  o.c2_position.target_y=20
  r=step(w,{},o)
  assert(r.intent.target_y==150, 'suggested release target escaped height ceiling')
end
do
  local w,o,s=world(),observation(),{fast_frames=100}
  w.player.y=160
  o.c2={}; o.c2_position=nil
  o.has_target,o.has_ignition=false,false
  o.focus_x,o.focus_y,o.focus_value=0,0,1
  local r=step(w,s,o)
  assert(r.intent.focus and r.intent.min_y==150 and r.intent.target_y>=150)
  w.player.sensor.cutIn=true
  r=step(w,s,o)
  assert(r.phase=='paused' and r.intent.min_y==150, 'pause lost ceiling')
end
print('bloom_low_policy_test: PASS (16 characters; shot/C1 height, C2 net share, separate positioning, deadline, release, focus/pause)')
