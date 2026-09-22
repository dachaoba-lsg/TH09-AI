-- Input sequencing and capture scheduling, not a simulation of enemy kills.
local bloom=dofile('bloom.lua')
local checks=0
local function check(ok,msg) checks=checks+1; assert(ok,msg) end
local function world()
 return {player={x=0,y=320,life=10,currentCharge=0,currentChargeMax=100,chargeSpeed=10,
  sensor={apiVersion=1,valid=true,state=0,timeScale=1,canCharge=true,cutIn=false,
   chargeWarmupFrames=0,protectionFrames=0,followupApiVersion=1,canPressZ=true,
   c1ActionActive=false,c1ActionAge=0,commonWavesValid=true,commonWaves={}}}}
end
local function obs()
 return {valid=true,has_target=true,has_ignition=true,ignition_aligned=true,
  target_x=0,target_y=320,ignition_id=1,chain_ids={1,2},chain_score=4,
  chain_enemies=2,chain_bullets=12,future_score=4,focus_value=0,
  timing={valid=true,improving=false,urgency=false},c2={},
  c1={valid=true,has_ignition=true,chain_score=4,chain_enemies=2,chain_bullets=12,
   chain_ids={1,2},model_limited=false,hit_count=2,damage_model_valid=true,kill_count=1},
  capture={valid=true,has_target=false}}
end
local function step(w,s,o)
 local r=bloom.update(w,s,bloom.defaults,o)
 check(r.target_level<=2 and r.target_level>=0,'escaped C1/C2')
 check(r.intent.min_y==150,'lost height boundary')
 bloom.feedback(s,{focus=r.intent.focus},bloom.defaults)
 return r
end
local function released(w,s,o)
 w.player.currentCharge=200;w.player.currentChargeMax=300
 s.target_level=2;s.fresh_charge=true
 local r=step(w,s,o)
 check(not r.press_z and r.release_c2==1,'must emit C2 release first')
 w.player.currentCharge=0;w.player.currentChargeMax=100
 return r
end
local function liveC2(w)
 local q=w.player.sensor
 q.state=3;q.protectionFrames=48;q.c1ActionActive=true;q.c1ActionAge=0
 q.canCharge=false
 q.commonWaves={{slotId=7,type=1,x=0,y=320,radius=4,growth=4,life=47,delay=0,enabled=true,listed=true}}
end
-- User operation: release C2, then press Z even while its role action gates
-- normal charging. Warm up the NEXT planned C1, without counting an extra one.
for role=0,15 do
 local w,s,o=world(),{},obs();w.player.character=role
 released(w,s,o);liveC2(w)
 local r=step(w,s,o)
 check(r.press_z and r.reason=='post_c2_z_prewarm','action gate swallowed follow-up Z')
 check(r.followup_z_requests==1 and r.release_c1==0,'follow-up falsely counted a charged C1')
 check(r.intent.protected_followup and r.followup_protection==47,'actual protection not used')
 for tick=1,5 do
  w.player.sensor.protectionFrames=48-tick
  w.player.sensor.c1ActionAge=tick
  r=step(w,s,o)
  check(r.press_z and r.followup_z_requests==1,'prewarm interrupted or repeated edge count')
 end
 w.player.sensor.canCharge=true
 w.player.currentCharge=100
 r=step(w,s,o)
 check(not r.press_z and r.release_c1==1 and r.release_c2==1,'fresh C1 did not release')
 check(r.since_c2>0,'C1 reset independent C2 clock')
end
-- A release request, old protection or stale charge alone grants no window.
for _,case in ipairs({'no_effect','old_protection','stale_charge','invalid_extension','blocked_input'}) do
 local w,s,o=world(),{},obs()
 if case=='old_protection' then
  w.player.sensor.state=3;w.player.sensor.protectionFrames=48
  w.player.sensor.c1ActionActive=true;w.player.sensor.c1ActionAge=5
 end
 released(w,s,o)
 if case=='old_protection' then
  w.player.sensor.protectionFrames=47;w.player.sensor.c1ActionAge=6
 elseif case~='no_effect' then liveC2(w) end
 if case=='stale_charge' then w.player.currentCharge=200 end
 if case=='invalid_extension' then w.player.sensor.followupApiVersion=nil end
 if case=='blocked_input' then w.player.sensor.canPressZ=false end
 local r=step(w,s,o)
 check(r.followup_z_requests==0,'unconfirmed/blocked release issued special Z: '..case)
 if case~='blocked_input' then check(not r.followup_confirmed,'invented C2 association: '..case) end
end
-- An observed wave can identify a refreshed C2 during existing protection;
-- its fixed release center need not equal the player's current position.
do
 local w,s,o=world(),{},obs()
 w.player.sensor.state=3;w.player.sensor.protectionFrames=80
 w.player.sensor.c1ActionActive=true;w.player.sensor.c1ActionAge=4
 released(w,s,o);liveC2(w);w.player.x=-12
 local r=step(w,s,o)
 check(r.followup_confirmed,'fixed release wave was incorrectly moved with player')
 w.player.sensor.protectionFrames=1
 r=step(w,s,o)
 check(not r.followup_confirmed and not r.intent.protected_followup,'used expired protection')
end
-- Pure follow-up edge with insufficient charge energy remains distinct from
-- a new normal C1 charge and is bounded to one request per confirmed C2.
do
 local w,s,o=world(),{},obs();released(w,s,o);liveC2(w)
 w.player.currentChargeMax=0
 local r=step(w,s,o)
 check(r.press_z and r.phase=='followup','missing immediate non-charge edge')
 r=step(w,s,o)
 check(not r.press_z and r.followup_z_requests==1 and r.release_c1==0,'edge repeated or counted as release')
end
-- A running role attack's remaining coverage may motivate the follow-up Z,
-- but may not be spent a second time to budget a newly charged C1.
do
 local w,s,o=world(),{},obs();released(w,s,o);liveC2(w)
 o.c1.remaining_only=true;o.c1.action_active=true
 local r=step(w,s,o)
 check(r.press_z and r.target_level==0 and r.phase=='followup',
  'running C1 remainder was duplicated as a new charge plan')
end
-- Approach left in high speed; once aligned, Shift is allowed despite an
-- existing chain wait lock. Energy alone must not replace capture with C2.
do
 local w,s,o=world(),{fast_frames=100},obs()
 w.player.currentChargeMax=200
 o.capture={valid=true,has_target=true,preferred=true,focus_x=-80,focus_y=240,
  focus_value=2,chain_ids={1,2},chain_score=6,chain_bullets=30,
  timing={valid=true,improving=true,urgency=false}}
 o.c2_position={has_ignition=true,target_x=0,target_y=400}
 local r=step(w,s,o)
 check(r.phase=='approach' and not r.press_z and not r.intent.focus,'failed fast pre-capture travel')
 check(r.intent.target_x==-80 and s.prepare_ids[1],'unfunded C2 stole capture goal/lock')
 w.player.x=-45
 r=step(w,s,o)
 check(r.intent.focus and r.phase=='prepare' and not r.press_z,'preparation lock blocked Shift')
 o.capture.timing.urgency=true;o.capture.timing.improving=false
 r=step(w,s,o)
 check(not r.intent.focus and r.reason~='capture_chain','capture-specific leakage ignored during preparation')
end
-- A blocked capture path does not indefinitely prevent ordinary attacks.
do
 for _,protected in ipairs({false,true}) do
  local w,s,o=world(),{},obs()
  if protected then released(w,s,o);liveC2(w) end
  s.fast_frames=24
  o.capture={valid=true,has_target=true,preferred=true,focus_x=-20,focus_y=240,
   focus_value=2,chain_ids={1,2},timing={valid=true,improving=false,urgency=false}}
  local r=step(w,s,o)
  check(r.intent.focus==protected,'protection-specific short capture opportunity lost/leaked outside window')
  if protected then
   check(s.prepare_ids and s.prepare_ids[1] and r.phase=='prepare',
    'closed charge gate prevented protection-window capture lock')
  end
 end
 local w,s,o=world(),{},obs();released(w,s,o);liveC2(w)
 s.fast_frames=24;s.focus_used=40
 o.capture={valid=true,has_target=true,preferred=true,focus_x=-20,focus_y=240,focus_value=2,chain_ids={1,2}}
 local r=step(w,s,o)
 check(not r.intent.focus,'protection bypassed actual Shift supply budget')
end
-- A blocked capture path does not indefinitely prevent ordinary attacks.
do
 local w,s,o=world(),{fast_frames=100},obs()
 o.capture={valid=true,has_target=true,preferred=true,focus_x=-80,focus_y=240,
  focus_value=2,chain_ids={1,2},timing={valid=true,improving=false,urgency=false}}
 local first
 for i=1,65 do local r=step(w,s,o);if r.press_z then first=i;break end end
 check(first and first<=61,'blocked lateral route held fire forever')
end
-- Independent character coverage can choose C1 without normal-shot alignment.
do
 local w,s,o=world(),{},obs()
 o.has_ignition=false;o.ignition_aligned=false;o.has_target=false
 local r=step(w,s,o)
 check(r.press_z and r.target_level==1 and s.c1_profile_charge,'C1 inherited normal-shot alignment')
end
-- A materially better C1 return beats an early swallowing C2, but never its
-- independently due cadence. No danger score or 500000-point branch exists.
do
 for _,due in ipairs({false,true}) do
  local w,s,o=world(),{since_c2=due and 480 or 0},obs()
  w.player.currentChargeMax=400;w.player.spellPoint=999990
  o.c1.chain_bullets=40
  o.c2={has_ignition=true,chain_score=6,chain_enemies=3,chain_bullets=10,
   future_has_ignition=true,future_score=6,future_enemies=3,future_bullets=10,
   chain_ids={1,2,3},direct_bullets=10,contested_bullets=0}
  local r=step(w,s,o)
  check(r.target_level==(due and 2 or 1),'C1 comparison broke yield or independent C2 deadline')
 end
end
print('bloom_followup_policy_test: PASS ('..checks..' assertions; 16-role input sequencing, capture, C1 choice, real protection)')
