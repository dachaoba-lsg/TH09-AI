-- Shape-timing policy regressions with explicit observed snapshots.
-- The tiny charge fixture only checks input edges/level boundaries; it does
-- not simulate character fields, enemy death, energy returns or live gameplay.
local bloom = dofile('bloom.lua')
local checks = 0
local function check(v,message) checks=checks+1; assert(v,message) end
local function copy(t)
  local out={}
  for k,v in pairs(t) do out[k]=type(v)=='table' and copy(v) or v end
  return out
end
local function config(overrides)
  local out=copy(bloom.defaults)
  for k,v in pairs(overrides or {}) do out[k]=v end
  return out
end
local function world(character)
  -- Generic timing fixtures omit damage proof; Reimu-specific proof and
  -- activation timing are exercised in reimu_c1_policy_test.lua.
  return {player={character=character or 1,x=0,y=320,life=10,spellPoint=0,combo=0,
    currentCharge=0,currentChargeMax=400,chargeSpeed=10,
    sensor={apiVersion=1,valid=true,state=0,canCharge=true,cutIn=false,timeScale=1,
      chargeWarmupFrames=0,chargeBlockFrames=0,protectionFrames=0}}}
end
local function timing(improving,urgent)
  return {valid=true,improving=improving==true,urgency=urgent==true,
    earliest_exit_frames=urgent and 2 or 120}
end
local function observation()
  return {valid=true,has_target=true,has_ignition=true,ignition_aligned=true,
    ignition_id=101,target_x=0,target_y=320,
    chain_ids={101,102,103,104},focus_chain_ids={101,102,103,104},
    chain_enemies=4,chain_fairies=2,chain_spirits=2,chain_activated=0,
    chain_score=8,chain_bullets=24,future_score=12,future_enemies=4,future_bullets=32,
    focus_value=0,chain_activated_gain=0,activated_gain=0,timing=timing(true,false),
    c2={has_ignition=true,future_has_ignition=true,seed_id=101,target_x=0,target_y=320,
      chain_ids={101,102,103,104},chain_enemies=4,chain_spirits=2,chain_activated=0,
      chain_score=8,chain_bullets=24,future_score=12,future_enemies=4,future_bullets=32,
      direct_bullets=0,contested_bullets=0,timing=timing(true,false)}}
end
local function focusObservation()
  local out=observation()
  out.focus_value,out.focus_x,out.focus_y=1.5,0,240
  return out
end
local function step(w,state,cfg,obs,actual_focus)
  local r=bloom.update(w,state,cfg,obs)
  check(r.target_level>=0 and r.target_level<=2,'target escaped C1/C2')
  check(r.intent.min_y==150,'timing branch lost existing height boundary')
  if actual_focus==nil then actual_focus=r.intent.focus end
  bloom.feedback(state,{focus=actual_focus,key=actual_focus and 4 or 0},cfg)
  return r
end
local function prepareCheck(r,message)
  check(r.phase=='prepare' and not r.press_z and r.target_level==0,message)
end
local function armedFixture(character,cfg)
  local w,state,obs=world(character),{},observation()
  local r=step(w,state,cfg,obs)
  check(r.press_z and r.target_level==2,'rich chain did not start C2 charge')
  w.player.currentCharge,w.player.currentChargeMax=200,200
  r=step(w,state,cfg,obs)
  check(r.phase=='armed' and r.press_z and r.release_c2==0,'improving funded C2 could not wait at level2')
  return w,state,obs,r
end

-- Preparing a selected spirit chain is a separate input stage. Newly seen
-- activation belongs to that chain; unrelated activation cannot finish it.
do
  for character=0,15 do
    local w,state,cfg,obs=world(character),{fast_frames=100},config(),focusObservation()
    for frame=1,12 do
      obs.activated_gain=frame==10 and 20 or 0
      local r=step(w,state,cfg,obs)
      prepareCheck(r,'selective focus ignited or ended on unrelated activation')
      check(r.intent.focus,'capture ended before its selected-chain feedback')
      check(state.prepare_ids and state.prepare_ids[101] and state.prepare_ids[104],
        'preparation lost original chain IDs')
      if frame==3 then
        obs.focus_chain_ids[#obs.focus_chain_ids+1]=999
        obs.chain_ids[#obs.chain_ids+1]=999
        obs.c2.chain_ids[#obs.c2.chain_ids+1]=999
        obs.chain_enemies,obs.c2.chain_enemies=5,5
      end
      check(not state.prepare_ids[999],'preparation lock migrated to a newly arriving node')
    end
    obs.chain_activated_gain,obs.chain_activated=1,1
    obs.c2.chain_activated=1
    local r=step(w,state,cfg,obs)
    check(not r.intent.focus,'selected-chain activation failed to end capture')
    for _=1,4 do
      if r.press_z then break end
      obs.chain_activated_gain=0
      r=step(w,state,cfg,obs)
    end
    check(r.press_z and r.target_level==2,'prepared chain did not proceed to charging')
    check(state.attack_ids and state.attack_ids[101] and state.attack_ids[104],
      'prepared original chain was discarded when attack started')
    check(not state.attack_ids[999],'attack lock replaced original preparation with the expanded component')
  end
end

-- Waiting for better overlap without any capture also has a finite limit;
-- a constantly improving forecast must eventually allow shot/C1 ignition.
do
  for _,energy in ipairs({0,100,400}) do
    local w,state,cfg,obs=world(),{},config(),observation()
    w.player.currentChargeMax=energy
    obs.c2={}
    local started
    for frame=1,cfg.prepare_max_frames+3 do
      if frame==3 then obs.chain_ids[#obs.chain_ids+1]=999 end
      local r=step(w,state,cfg,obs)
      check(not r.intent.focus,'overlap-only waiting invented a focus window')
      if r.press_z then started=frame;break end
    end
    check(started and started<=cfg.prepare_max_frames+2,'always-improving overlap caused indefinite waiting')
    check(state.attack_ids and state.attack_ids[101] and not state.attack_ids[999],
      'overlap expiry migrated original preparation to a newly joined node')
  end
end

-- Activation is a one-frame event. Remember an early event, but honor the
-- actual Shift minimum. Four requested-but-unperformed focus frames do not
-- count toward that minimum (dodge can override the preference).
do
  local w,state,cfg,obs=world(),{fast_frames=100},config(),focusObservation()
  for frame=1,4 do
    obs.chain_activated_gain=frame==3 and 1 or 0
    prepareCheck(step(w,state,cfg,obs,false),'early activation skipped actual focus dwell')
  end
  obs.chain_activated_gain=0
  for _=1,cfg.focus_min_frames do
    prepareCheck(step(w,state,cfg,obs,true),'requested focus was mistaken for actual focus feedback')
  end
  local r=step(w,state,cfg,obs)
  check(not r.intent.focus and r.phase~='prepare',
    'one-frame activation was lost before the actual minimum dwell completed')
end

-- No feedback/never-perfect future geometry cannot trap preparation or Shift
-- forever. The bounded stage must eventually hand control to an attack plan.
do
  local w,state,cfg,obs=world(),{fast_frames=100},config(),focusObservation()
  local longest,run,focused,started=0,0,0,nil
  for frame=1,cfg.prepare_max_frames+4 do
    local r=step(w,state,cfg,obs)
    run=r.intent.focus and run+1 or 0
    longest=math.max(longest,run)
    focused=focused+(r.intent.focus and 1 or 0)
    if r.phase=='prepare' then check(not r.press_z,'preparation simultaneously ignited the chain') end
    if r.press_z then started=frame;break end
  end
  check(started~=nil and started<=cfg.prepare_max_frames+2,'preparation waited without bound')
  check(longest<=cfg.focus_max_frames and focused<=cfg.focus_budget_frames,
    'preparation kept Shift past dwell/budget limits')
end

-- White resources about to leak override waiting for a prettier future and
-- can end capture before its minimum. This is shape urgency, never danger.
do
  local w,state,cfg,obs=world(),{fast_frames=100},config(),focusObservation()
  prepareCheck(step(w,state,cfg,obs),'urgency fixture did not begin capture')
  obs.chain_ids[#obs.chain_ids+1]=999
  obs.c2.chain_ids[#obs.c2.chain_ids+1]=999
  obs.timing,obs.c2.timing=timing(true,true),timing(true,true)
  local r=step(w,state,cfg,obs)
  check(not r.intent.focus and r.press_z and r.phase=='shot',
    'near-expiry chain stayed in capture or began a charge that cannot finish before exit')
  check(state.attack_ids and state.attack_ids[101] and not state.attack_ids[999],
    'urgent ignition migrated original preparation to a newly joined node')
  for _,energy in ipairs({0,100}) do
    w,state,obs=world(),{},observation()
    w.player.currentChargeMax=energy
    obs.c2={}
    obs.future_score=40
    obs.timing=timing(true,true)
    obs.timing.earliest_exit_frames=20 -- C1 can arrive; a shot is used without energy.
    r=step(w,state,cfg,obs)
    check(r.press_z and (energy==0 and r.phase=='shot' or energy==100 and r.target_level==1),
      'leaking shot/C1 resources waited for the higher future score')
  end
end

-- With enough room before C3, all characters may wait for improving geometry
-- at C2, without requiring a third energy bar. Once shape is ready/urgent or
-- the bounded wait expires, release. Missing timing retains the old release.
do
  for character=0,15 do
    local cfg=config()
    local w,state,obs=armedFixture(character,cfg)
    obs.c2.timing=timing(false,false)
    local r=step(w,state,cfg,obs)
    check(r.phase=='release' and not r.press_z and r.release_c2==1,'ready shape did not release C2')
    w,state,obs=armedFixture(character,cfg)
    obs.c2.timing=timing(true,true)
    r=step(w,state,cfg,obs)
    check(not r.press_z and r.release_c2==1,'leaking chain remained armed')
  end
  local cfg=config()
  local w,state,obs=armedFixture(0,cfg)
  local holds=1
  local r
  for _=1,cfg.armed_max_frames+2 do
    r=step(w,state,cfg,obs)
    if r.release_c2>0 then break end
    holds=holds+1
    check(r.press_z and r.phase=='armed','bounded C2 wait dropped held charge')
  end
  check(r.release_c2==1 and not r.press_z and holds<=cfg.armed_max_frames,
    'a 200-energy cap allowed unlimited armed waiting')
  w,state,obs=armedFixture(0,cfg)
  obs.c2.timing=nil
  r=step(w,state,cfg,obs)
  check(not r.press_z and r.release_c2==1,'missing timing extended a mature C2')
end

-- Safety must use the possible next charge, without assuming a currently low
-- cap remains low while a chain refills it. A potential C3 step always releases
-- first; raising the cap while armed may never slip into C3/C4.
do
  for _,speed in ipairs({0.5,1.75,10,33.3,99}) do
    for _,energy in ipairs({299,400}) do
      local cfg=config()
      local w,state,obs=armedFixture(0,cfg)
      w.player.chargeSpeed=speed
      w.player.currentCharge=300-speed
      w.player.currentChargeMax=math.max(energy,w.player.currentCharge)
      local r=step(w,state,cfg,obs)
      check(not r.press_z and r.release_c2==1 and r.release_c1==0,
        'potential next-step C3 was permitted at speed '..speed..' cap '..energy)
    end
  end
  local cfg=config()
  local w,state,obs=armedFixture(0,cfg)
  w.player.currentCharge,w.player.currentChargeMax=285,285
  local r=step(w,state,cfg,obs)
  check(r.press_z and r.phase=='armed','safe sub-C3 shape window was prematurely removed')
  -- Energy grows between observations; next observed charge is still C2.
  w.player.currentCharge,w.player.currentChargeMax=295,400
  r=step(w,state,cfg,obs)
  check(not r.press_z and r.release_c2==1,'new energy cap let the armed C2 enter C3')

  w,state,obs=world(),{},observation()
  obs.c2={}
  obs.future_score=obs.chain_score
  obs.timing=timing(false,false)
  step(w,state,cfg,obs)
  w.player.currentCharge=100
  obs.timing=timing(true,false)
  r=step(w,state,cfg,obs)
  check(r.press_z and r.phase=='armed' and r.target_level==1,'C1 could not wait for its valid shape')
  w.player.currentCharge=190
  r=step(w,state,cfg,obs)
  check(not r.press_z and r.release_c1==1 and r.release_c2==0,'shape-held C1 crossed into unintended C2')
end

-- Advance real level boundaries in a bounded charge reference, then raise
-- the meter while armed. Fractional/large increments and slower game time
-- must still produce exactly one C2 edge with a pre-release charge below300.
do
  for _,speed in ipairs({0.5,1.75,10,33.3,80,99}) do
    for _,scale in ipairs({1,0.25}) do
      local cfg=config()
      local w,state,obs=world(),{},observation()
      local p=w.player
      p.chargeSpeed,p.sensor.timeScale,p.currentChargeMax=speed,scale,200
      local armed,released=false,false
      local limit=math.ceil(200/(speed*scale))+cfg.armed_max_frames+5
      for _=1,limit do
        local before=p.currentCharge
        local r=step(w,state,cfg,obs)
        check(before<300,'reference charge entered C3 before a release decision')
        if r.phase=='armed' then armed=true;p.currentChargeMax=400 end
        if r.release_c2>0 then
          check(r.release_c2==1 and r.release_c1==0 and before>=200 and not r.press_z,
            'reference charge produced wrong/duplicate release level')
          released=true;break
        end
        if r.press_z then p.currentCharge=math.min(p.currentChargeMax,before+speed*scale)
        else p.currentCharge=0 end
      end
      check(armed and released,'funded improving C2 did not complete bounded armed cycle')
    end
  end
end

-- Deadline charging also preempts selective capture and shape waiting. It
-- cannot spend the final charge-ready frame waiting for another improvement.
do
  local w,state,cfg,obs=world(),{fast_frames=100},config(),focusObservation()
  prepareCheck(step(w,state,cfg,obs),'deadline fixture lacked preparation')
  state.since_c2=479
  local r=step(w,state,cfg,obs)
  check(r.press_z and r.target_level==2 and r.cadence_charge and not r.intent.focus,
    'independent deadline remained in capture')
  w.player.currentCharge=200
  r=step(w,state,cfg,obs)
  check(not r.press_z and r.release_c2==1 and r.since_c2==0,'deadline matured into extra shape waiting')
end

-- Closed action gates and cut-in/time-stop pauses cannot invent release
-- events or advance armed dwell. A hit clears stale preparation/charge plans.
do
  local cfg=config()
  local w,state,obs,r=armedFixture(0,cfg)
  w.player.sensor.canCharge=false
  for _=1,8 do
    r=step(w,state,cfg,obs)
    check(r.press_z and r.release_c2==0,'closed gate emitted a C2 release')
  end
  w.player.sensor.canCharge=true
  w.player.currentCharge=295
  r=step(w,state,cfg,obs)
  check(not r.press_z and r.release_c2==1,'reopened gate failed pre-C3 protection')
  for _,kind in ipairs({'cutIn','timeScale'}) do
    w,state,obs,r=armedFixture(0,cfg)
    local age,cadence=r.armed_age,r.since_c2
    if kind=='cutIn' then w.player.sensor.cutIn=true else w.player.sensor.timeScale=0 end
    for _=1,20 do
      r=step(w,state,cfg,obs)
      check(r.phase=='paused' and r.press_z and r.release_c2==0,'pause released armed input')
      check(r.armed_age==age and r.since_c2==cadence,'pause advanced armed or cadence timers')
    end
    w.player.sensor.cutIn,w.player.sensor.timeScale=false,1
    obs.c2.timing=timing(true,true)
    r=step(w,state,cfg,obs)
    check(not r.press_z and r.release_c2==1,'unpaused urgent shape failed to release')
  end
  w,state,obs=armedFixture(0,cfg)
  state.since_c2=500
  w.player.life,w.player.sensor.state,w.player.currentCharge=9,4,0
  r=step(w,state,cfg,obs)
  check(not r.press_z and r.target_level==0 and r.release_c2==0,'hit replayed old armed release')
  check(not r.prepare_locked and state.prepare_ids==nil,'hit retained original preparation')
  check(r.since_c2>=500,'hit discarded overdue C2 cadence')
  w.player.sensor.state=0
  r=step(w,state,cfg,obs)
  check(r.press_z and r.target_level==2 and r.cadence_charge,'recovery waited on shape despite overdue C2')
end

-- A short independent interval makes a sustained two-cycle integration test
-- practical. Shape-held C1s cannot reset the C2 clock. The explicit charge
-- edge model also checks every observed release stayed in its real level.
do
  local cfg=config({max_c_interval_frames=60})
  local w,state,obs=world(),{},observation()
  obs.c2={};obs.future_score=obs.chain_score
  local releases,previous_c2,previous_c1={},0,0
  local last_c2_age=0
  for frame=1,125 do
    local before=w.player.currentCharge
    obs.timing=timing(before>=100,false)
    local r=step(w,state,cfg,obs)
    if r.release_c1>previous_c1 then
      check(before>=100 and before<200 and not r.press_z,'C1 release label disagrees with charge')
      check(r.since_c2==last_c2_age+1,'C1 reset the independent C2 interval')
    end
    if r.release_c2>previous_c2 then
      check(before>=200 and before<300 and not r.press_z,'C2 release label disagrees with charge')
      releases[#releases+1]=frame
      check(r.since_c2==0,'C2 failed to reset its own clock')
    end
    previous_c1,previous_c2,last_c2_age=r.release_c1,r.release_c2,r.since_c2
    if r.press_z then w.player.currentCharge=math.min(w.player.currentChargeMax,before+w.player.chargeSpeed)
    else w.player.currentCharge=0 end
  end
  check(previous_c1>0 and #releases>=2,'shape-held C1 fixture starved its C2 cycles')
  check(releases[1]<=60 and releases[2]-releases[1]<=60,'shape waits postponed independent deadline')
end

print('bloom_timing_test: PASS ('..checks..' assertions; prepare/armed/resource expiry, no live-game claim)')
