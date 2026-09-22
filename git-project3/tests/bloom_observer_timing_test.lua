-- Selected-original-chain overlap timing; no game process or physics changes.
local observer=dofile('bloom_observer.lua')
local checks=0
local function check(v,message) checks=checks+1;assert(v,message) end
local function enemy(id,x,y,vx,vy,spirit,activated)
  return {id=id,x=x,y=y,vx=vx or 0,vy=vy or 0,enabled=true,
    isSpirit=spirit or false,isActivatedSpirit=activated or false,
    isBoss=false,isLily=false,isPseudoEnemy=false}
end
local function bullet(id,x,y,vx,vy)
  return {id=id,x=x,y=y,vx=vx or 0,vy=vy or 0,enabled=true,isErasable=true}
end
local function world(enemies,bullets)
  return {player={x=0,y=320,character=0},enemies=enemies or {},bullets=bullets or {}}
end
local function observe(w,state,cfg) return observer.observe(w,state or {},cfg or {prediction_frames=20}) end
local function contains(ids,id) for _,v in ipairs(ids) do if v==id then return true end end return false end

do
  local w=world({enemy('a',0,200)}, {
    bullet('leaves',0,200,0,4),bullet('arrives',0,120,0,4),bullet('stays',0,200),
    bullet('leaves',0,200,0,4)})
  local r=observe(w)
  check(r.timing.valid and r.timing.window_frames==20,'selected chain has no timing')
  check(r.timing.current_bullets==2 and r.timing.future_bullets==2,'stable bullet IDs were double-counted')
  check(r.timing.leaving_bullets==1 and r.timing.arriving_bullets==1,'equal totals hid bullet replacement')
  check(r.timing.urgency and not r.timing.improving,'loss masked by an equal number of arriving bullets')
  w.bullets={bullet('stays',0,200),bullet(1,0,120,0,4),bullet('1',0,120,0,4),bullet(nil,0,120,0,4)}
  r=observe(w)
  check(r.timing.current_bullets==1 and r.timing.future_bullets==4,'numeric/string/absent IDs collapsed')
  check(r.timing.improving and not r.timing.urgency,'clean future gain not recognized')
  check(r.timing.earliest_exit_frames==nil,'invented an exit without a leaving bullet')
  r=observe(w,{}, {prediction_frames=20,timing_min_gain=4})
  check(not r.timing.improving,'configurable minimum gain ignored')
  r=observe(w,{}, {prediction_frames=20,timing_gain_ratio=5})
  check(not r.timing.improving,'configurable gain ratio ignored')
end
do
  local w=world({enemy('a',0,200)},{bullet('a',8,224,0,2)})
  local r=observe(w)
  local exit=(math.sqrt(48*48-8*8)-24)/2
  check(r.timing.urgency and math.abs(r.timing.earliest_exit_frames-exit)<1e-8,
    'known one-node relative motion did not report its heuristic circle exit')
  w.enemies[1].vx=nil
  r=observe(w)
  check(r.timing.earliest_exit_frames==nil,'unknown node velocity advertised precise exit')
  w.enemies[1].vx=0;w.bullets[1].vx=nil
  r=observe(w)
  check(r.timing.earliest_exit_frames==nil,'unknown bullet velocity advertised precise exit')
  w.bullets[1].vx=0;w.enemies[2]=enemy('b',10,200)
  r=observe(w)
  check(r.timing.urgency and r.timing.earliest_exit_frames==nil,'multi-node union invented exact propagation timing')
end
do
  -- A future merge adds a new node and its nearby bullets to future_score,
  -- but it must not justify holding a charge for the original selected chain.
  local w=world({enemy('a',0,200),enemy('b',120,200,-4,0)},{bullet('outside',80,200)})
  local r=observe(w,{bloom_observer_lock_id='a'})
  check(r.has_ignition and r.future_enemies==2 and r.future_bullets==1,'future-merge fixture malformed')
  check(r.timing.current_bullets==0 and r.timing.future_bullets==0 and not r.timing.improving,
    'future timing borrowed neighborhood from a newly joined enemy')
  -- Split-away original nodes no longer belong to the selected ignition group.
  w=world({enemy('a',0,200),enemy('b',50,200,4,0)},{bullet('follows-b',50,200,4,0)})
  r=observe(w,{bloom_observer_lock_id='a'})
  check(r.chain_enemies==2 and r.future_enemies==1,'split fixture malformed')
  check(r.timing.current_bullets==1 and r.timing.future_bullets==0 and r.timing.urgency,
    'disconnected original node retained borrowed future coverage')
  check(r.timing.earliest_exit_frames==nil,'topology loss invented precise bullet exit')
  -- A saved lock excludes resources around later additions to the same group.
  w=world({enemy('a',0,200),enemy('b',50,200)},{bullet('outside-a',80,200)})
  r=observe(w,{lock_ids={a=true}})
  check(r.chain_enemies==2 and r.chain_bullets==1,'locked-subset fixture malformed')
  check(r.timing.current_bullets==0 and r.timing.future_bullets==0,'lock admitted a newly attached neighborhood')
end
do
  local w=world({enemy('seed',0,220),enemy('relay',0,160),enemy('top',0,100)}, {
    bullet('net',0,75),bullet('contest',0,215),bullet('direct',130,315)})
  local r=observe(w)
  check(r.c2.has_ignition and r.c2.chain_bullets==1,'C2 net fixture malformed')
  check(r.c2.timing.valid and r.c2.timing.current_bullets==1 and r.c2.timing.future_bullets==1,
    'C2 timing credited direct or contested circle erasures')
  check(r.c2.direct_bullets+r.c2.contested_bullets==2,'C2 exposure fixture malformed')
  w.bullets[1].vy=4
  r=observe(w)
  check(r.c2.timing.current_bullets==0 and r.c2.timing.future_bullets==0,
    'current circle-exterior bullet crossing the 48-update envelope counted as net')
  w.bullets={bullet('leaving-net',0,75,4,0)}
  r=observe(w)
  check(r.c2.timing.current_bullets==1 and r.c2.timing.future_bullets==0 and r.c2.timing.urgency,
    'outward moving net bullet lost no urgency')
  -- A lower recommendation can gain net bullets, but the actual release timing
  -- remains empty until the player physically moves there.
  w=world({enemy('a',0,140),enemy('b',0,200),enemy('c',0,260)},{bullet('b',0,160)})
  r=observe(w)
  check(r.c2_position.chain_bullets==1 and r.c2.chain_bullets==0,'actual/planned fixture malformed')
  check(r.c2.timing.current_bullets==0 and r.c2.timing.future_bullets==0,
    'planned lower release yield leaked into actual timing')
end
do
  local w=world({enemy('s',-100,200,0,0,true,false),enemy('other',100,250),
    enemy('t',100,200,0,0,true,false)},{bullet('near-s',-100,200)})
  local state={lock_ids={s=true}}
  local r=observe(w,state)
  check(r.has_target and not r.has_ignition and r.ignition_x==nil,'pure focus lock became ordinary ignition')
  check(r.focus_value>0 and #r.chain_ids==0 and contains(r.focus_chain_ids,'s'),
    'unrelated ordinary target displaced the locked pure-spirit preparation')
  check(r.timing.valid and r.timing.current_bullets==1,'focus-only same-chain shape is unavailable')
  w.enemies[1].isActivatedSpirit=true;w.enemies[3].isActivatedSpirit=true
  r=observe(w,state)
  check(r.activated_gain==2 and r.chain_activated_gain==1,'unrelated activation ended selected-chain preparation')
  check(r.has_ignition and r.chain_activated==1,'activation did not enable the original spirit')
  r=observe(w,state)
  check(r.chain_activated_gain==0,'existing activation counted on every frame')
  -- An activated new arrival attached to the chain is not a false->true sample.
  w.enemies[4]=enemy('new',-80,200,0,0,true,true)
  r=observe(w,state)
  check(r.chain_activated==2 and r.chain_activated_gain==0,'new already-activated arrival invented a focus gain')
  state.lock_ids={missing=true}
  r=observe(w,state)
  check(not r.has_target and not r.timing.valid and not r.c2.has_ignition and not r.c2.timing.valid,
    'disappeared preparation borrowed unrelated chain timing')
  state.lock_ids={}
  r=observe(w,state)
  check(not r.has_target and not r.timing.valid,'empty lock reused old timing')
end
do
  local w=world({enemy('a',0,200)},{bullet('good',0,200),bullet('disabled',0,200),
    bullet('not-white',0,200),bullet('nan',0/0,200)})
  w.bullets[2].enabled=false;w.bullets[3].isErasable=false
  local r=observe(w)
  check(r.timing.current_bullets==1 and r.timing.future_bullets==1,'invalid/disabled/nonerasable bullet counted')
  r=observe(w,{}, {prediction_frames=0})
  check(r.timing.valid and r.timing.window_frames==0 and not r.timing.urgency and not r.timing.improving,
    'zero prediction horizon invented change')
  r=observe(w,{}, {prediction_frames=999})
  check(r.timing.window_frames==60,'timing exceeded bounded forecast horizon')
  r=observe({player={x=0/0,y=200}})
  check(not r.timing.valid and not r.c2.timing.valid and r.chain_activated_gain==0,
    'invalid observation retained valid timing')
  r=observe(world({}, {bullet('alone',0,200)}))
  check(not r.timing.valid and not r.c2.timing.valid,'pure bullets invented a chain timing source')
end
do
  -- Position cache persists, but timing is rebuilt from current IDs and motion.
  local w=world({enemy('a',0,220),enemy('b',0,160),enemy('c',0,100)},{bullet('old',0,75)})
  local state={}
  local first=observe(w,state)
  w.bullets={bullet('fresh',0,75,4,0),bullet('incoming',-80,100,4,0)}
  local second=observe(w,state)
  check(first.stats.c2_position_full_search and not second.stats.c2_position_full_search,
    'cache fixture did not use cached position')
  check(first.c2.timing.current_bullets==1 and not first.c2.timing.urgency,
    'later observation mutated earlier timing snapshot')
  check(second.c2.timing.current_bullets==1 and second.c2.timing.future_bullets==1
    and second.c2.timing.leaving_bullets==1 and second.c2.timing.arriving_bullets==1,
    'cached position reused stale bullet identity or velocity')
  for character=0,15 do
    w.player.character=character
    local r=observe(w,state)
    check(r.timing.valid and r.c2.timing.valid and r.c2.timing.urgency,'character branch disabled timing')
  end
end
do
  local w=world()
  for i=1,128 do w.enemies[i]=enemy(i,(i%8)*10-40,180+math.floor(i/8)*4) end
  for i=1,2000 do w.bullets[i]=bullet(i,(i%32)*8-128,70+(i%35)*8,0,0.5) end
  local state={lock_ids={[1]=true}}
  local r=observe(w,state)
  check(r.stats.timing_bullet_tests<=4000,'timing rescanned bullets per node instead of per selected chain')
  check(r.stats.timing_grid_queries<=4*128*49,'timing subset coverage exceeded the bounded node/bin pass')
end
print(string.format('bloom_observer_timing_test: PASS (%d checks)',checks))
