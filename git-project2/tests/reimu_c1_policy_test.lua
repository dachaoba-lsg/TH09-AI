-- Reimu-specific resource qualification and preparation. Observer/native
-- damage tests establish the proof fields; these checks exercise input policy.
local bloom=dofile('bloom.lua')
local checks=0
local function check(v,msg) checks=checks+1;assert(v,msg) end
local function world(role)
 return {player={character=role or 0,x=0,y=320,life=5,currentCharge=0,currentChargeMax=100,
  chargeSpeed=10,sensor={state=0,timeScale=1,canCharge=true,canPressZ=true,
   chargeWarmupFrames=0,followupApiVersion=1,commonWavesValid=true,commonWaves={}}}}
end
local function observation()
 return {valid=true,has_target=true,has_ignition=true,ignition_aligned=true,
  target_x=0,target_y=320,ignition_id=1,chain_ids={1,2},chain_score=5,chain_enemies=2,
  chain_bullets=20,focus_value=0,timing={valid=true,improving=false,urgency=false},
  c2={},capture={valid=true,has_target=false},
  c1={valid=true,has_ignition=true,damage_model_valid=true,kill_count=1,
   chain_ids={1,2},chain_enemies=2,chain_score=5,chain_bullets=20,value=5,
   model_limited=false,timing={valid=true,improving=false,urgency=false}}}
end
local function step(w,s,o,actual_focus)
 local r=bloom.update(w,s,bloom.defaults,o)
 check(r.target_level>=0 and r.target_level<=2,'escaped C1/C2')
 check(r.intent.min_y==150,'lost bloom height boundary')
 if actual_focus==nil then actual_focus=r.intent.focus end
 bloom.feedback(s,{focus=actual_focus},bloom.defaults)
 return r
end
local function capture(o)
 o.capture={valid=true,has_target=true,preferred=false,preferred_before_c1=true,
  focus_x=0,focus_y=240,focus_value=2,chain_ids={1,2},focus_chain_ids={1,2},
  value=4,chain_score=4,chain_enemies=2,chain_bullets=20,
  timing={valid=true,improving=false,urgency=false}}
end

-- An unsupported/limited C1 cannot use the ordinary-shot score as a proxy.
-- Preserve ordinary shooting as an available way to kill/soften a fairy.
do
 local w,s,o=world(),{},observation()
 o.c1={valid=true,has_ignition=false,model_limited=true,damage_model_valid=false,kill_count=0}
 local r=step(w,s,o)
 check(r.target_level==0 and r.phase=='shot','unsupported Reimu C1 escaped through legacy fallback')
 for _,case in ipairs({'invalid_model','zero_kills','missing_proof','malformed_kills'}) do
  o=observation()
  if case=='invalid_model' then o.c1.damage_model_valid=false
  elseif case=='zero_kills' then o.c1.kill_count=0
  elseif case=='missing_proof' then o.c1.damage_model_valid=nil;o.c1.kill_count=nil
  else o.c1.kill_count=0/0 end
  check(step(w,{},o).target_level==0,'unverified C1 became a Reimu attack: '..case)
 end
end

-- A proved first kill can seed the linked group. Other roles retain their
-- existing coverage/legacy choices; they do not need Reimu-only proof fields.
do
 local w,s,o=world(),{},observation()
 local r=step(w,s,o)
 check(r.target_level==1 and r.press_z and s.c1_profile_charge,'proved Reimu seed did not allow C1')
 for role=1,15 do
  w=world(role);o=observation();o.c1.damage_model_valid=nil;o.c1.kill_count=nil
  check(step(w,{},o).target_level==1,'new proof gate leaked into role '..role)
  o.c1={valid=true,has_ignition=false,model_limited=true}
  check(step(w,{},o).target_level==1,'legacy fallback changed for role '..role)
 end
end

-- A falsely high C1 coverage value cannot steal a viable same-chain capture.
-- Actual Shift alone is not activation; wait for that original spirit's
-- observed transition before the proof-backed C1 may replace preparation.
do
 local w,s,o=world(),{fast_frames=100},observation()
 capture(o);o.c1.damage_model_valid=true;o.c1.kill_count=0;o.c1.value=100
 local r=step(w,s,o)
 check(r.intent.focus and r.phase=='prepare' and not r.press_z,'false C1 yield displaced pre-capture Shift')
 for _=1,8 do r=step(w,s,o) end
 check(r.phase=='prepare' and not r.press_z and s.prepare_focus_frames>=8,
  'Shift duration alone was treated as spirit activation')
 o.capture.has_target=false;o.capture.focus_value=0;o.capture.chain_activated_gain=1
 o.c1.kill_count=1
 r=step(w,s,o)
 check(r.target_level==1 and r.press_z and not r.intent.focus,'observed activated kill seed did not unlock C1')
end
do
 local w,s,o=world(),{fast_frames=100},observation()
 capture(o);o.c1.kill_count=0
 local r
 for _=1,12 do r=step(w,s,o,false) end
 check((s.prepare_focus_frames or 0)==0 and r.target_level==0,
  'requested Shift was counted as actual capture despite dodge choosing fast movement')
 s.focus_used=40;r=step(w,s,o)
 check(not r.intent.focus,'Reimu capture bypassed existing Shift budget')
end

-- Lost proof can cancel below 100, and the next update can return to capture.
-- Once 100 is observed, releasing is unavoidable; never wait into C2/C3.
do
 local w,s,o=world(),{fast_frames=100},observation()
 step(w,s,o);w.player.currentCharge=50;o.c1.kill_count=0
 local r=step(w,s,o)
 check(not r.press_z and r.target_level==0 and r.reason=='reimu_c1_seed_lost'
  and r.release_c1==0,'lost seed did not cancel below C1')
 w.player.currentCharge=0;capture(o)
 r=step(w,s,o)
 check(r.intent.focus and r.phase=='prepare','cancelled C1 could not return to capture')
 w,s,o=world(),{},observation();step(w,s,o)
 w.player.currentCharge=100;o.c1.kill_count=0;o.c1.timing.improving=true
 r=step(w,s,o)
 check(not r.press_z and r.release_c1==1 and r.release_c2==0,
  'mature C1 with lost proof stalled or crossed the next level')
end

-- Impact resources have already been projected through charge + warm-up +
-- the delayed homing flight. Differences between two impact scenes are not
-- a second current-time expiry; generic current-time urgency stays unchanged.
do
 local w,s,o=world(),{},observation()
 o.c1.kill_delay=70
 o.c1.timing={valid=true,at_impact=true,urgency=true,earliest_exit_frames=2,
  improving=false,leaving_bullets=2,arriving_bullets=8}
 local r=step(w,s,o)
 check(r.target_level==1 and r.press_z,'charge delay was charged twice against impact-timed resources')
 w.player.currentCharge=100;o.c1.timing.improving=true
 r=step(w,s,o)
 check(r.phase=='armed' and r.press_z,'comparative impact leakage became an immediate release deadline')
 w.player.currentCharge=190
 r=step(w,s,o)
 check(r.release_c1==1 and not r.press_z,'impact-timed waiting bypassed the C1 charge ceiling')
 w,s,o=world(),{},observation();o.c1.damage_model_valid=false
 o.c1.timing={valid=true,at_impact=true,urgency=true,earliest_exit_frames=2}
 check(step(w,s,o).target_level==0,'impact timing invented an unproved Reimu kill')
 w,s,o=world(1),{},observation()
 o.c1.timing={valid=true,urgency=true,earliest_exit_frames=2}
 check(step(w,s,o).target_level==0,'generic C1 no longer respects current-time expiry')
 w,s,o=world(1),{},observation();step(w,s,o)
 w.player.currentCharge=100
 o.c1.timing={valid=true,urgency=true,improving=true,earliest_exit_frames=2}
 r=step(w,s,o)
 check(r.release_c1==1 and not r.press_z and r.reason=='intercept_c1',
  'generic urgency stopped ending an armed C1 wait')
end

-- Cadence remains an explicit bounded exception rather than fabricated
-- chain profit: low energy can request C1, and an overdue C2 wins capture.
do
 local w,s,o=world(),{since_c=480,since_c2=480},observation()
 o.c1.kill_count=0;capture(o);s.fast_frames=100
 local r=step(w,s,o)
 check(r.target_level==1 and r.reason=='cadence_c1' and not r.intent.focus,
  'Reimu proof gate suppressed low-energy C cadence')
 w,s,o=world(),{since_c2=480,fast_frames=100},observation()
 w.player.currentChargeMax=200;o.c1.kill_count=0;capture(o)
 r=step(w,s,o)
 check(r.target_level==2 and r.reason=='cadence_c2','capture/proof gate postponed due C2')
 w,s,o=world(),{},observation();step(w,s,o)
 w.player.currentCharge=50;w.player.currentChargeMax=200;s.since_c2=480;o.c1.kill_count=0
 r=step(w,s,o)
 check(r.target_level==2 and r.press_z and r.cadence_charge,'lost C1 cancelled an already due C2 promotion')
end
print('reimu_c1_policy_test: PASS ('..checks..' assertions; proof-backed C1, selective capture, bounded input and cadence)')
