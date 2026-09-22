-- Low release preferences are read-only estimates, not game/path simulation.
local observer = dofile('bloom_observer.lua')
local checks = 0
local function check(v, message) checks=checks+1; assert(v,message) end
local function enemy(id,x,y,vx,vy)
  return {id=id,x=x,y=y,vx=vx or 0,vy=vy or 0,enabled=true,
    isSpirit=true,isActivatedSpirit=false,isBoss=false,isLily=false,isPseudoEnemy=false}
end
local function bullet(x,y,vx,vy)
  return {x=x,y=y,vx=vx or 0,vy=vy or 0,enabled=true,isErasable=true}
end
local function world(y,enemies,bullets)
  return {player={x=0,y=y,character=0},enemies=enemies or {},bullets=bullets or {}}
end
local function observe(w,state,cfg) return observer.observe(w,state or {},cfg) end
local function exposure(c) return c.direct_bullets+c.contested_bullets end

do
  local w=world(320,{enemy(1,0,140),enemy(2,0,200),enemy(3,0,260)})
  for i=1,50 do w.bullets[i]=bullet(i%4,160) end
  local r=observe(w)
  check(r.c2.has_ignition and r.c2_position.has_ignition,'lost current/planned ignition')
  check(r.c2_position.target_y>320 and exposure(r.c2_position)<exposure(r.c2),
    'lower circle did not preserve more chain bullets')
  check(r.c2.chain_bullets==0 and r.c2_position.chain_bullets==50,'planned yield leaked into actual release')
  check(r.c2.target_x==0 and r.c2.target_y==320,'actual C2 centre replaced by preferred centre')
  check(r.c2_position.improvement>0 and not r.c2_position.at_target,'preference metadata incorrect')
  check(r.c2.value==nil and r.c2.at_target==nil,'position metadata mutated actual assessment')
  local actual_before=r.c2.chain_bullets
  w.player.x,w.player.y=r.c2_position.target_x,r.c2_position.target_y
  local arrived=observe(w)
  check(arrived.c2.chain_bullets==50 and actual_before==0,'arrival did not re-evaluate actual release')
end
do
  local r=observe(world(320,{enemy(1,0,140)},{bullet(0,140)}))
  check(r.c2.has_ignition and r.c2_position.has_ignition,'reachable seed disappeared')
  check(r.c2_position.target_y==320,'preferred empty lower corner after losing the only seed')
  check(r.c2_position.at_target,'current point metadata incorrect')
  r=observe(world(320,{enemy(1,0,40)},{bullet(0,40)}))
  check(not r.c2.has_ignition and not r.c2_position.has_ignition,'unreachable seed attracted release movement')
  check(r.c2_position.target_x==nil and r.c2_position.target_y==nil,'empty site invented movement target')
end
do
  local r=observe(world(320,{}, {bullet(0,400)}))
  check(r.counts.erasable==0 and r.c2.direct_bullets==1,'C2 ignored bullets below the ordinary observation strip')
  check(not r.c2_position.has_ignition,'pure bullets attracted an empty-corner escape plan')
  local w=world(320)
  for i=1,2000 do w.bullets[i]=bullet(i%8,300,0,1) end
  r=observe(w)
  check(r.c2.direct_bullets==2000 and r.stats.c2_bullet_tests<=4000,
    'no-seed alternatives rescanned the complete bullet field')
  w.enemies={enemy(1,0,20)}
  r=observe(w)
  check(not r.c2_position.has_ignition and r.stats.c2_bullet_tests<=4000,
    'unreachable-seed alternatives rescanned the complete bullet field')
end
do
  local w=world(400,{enemy(1,0,250),enemy(2,0,200),enemy(3,0,150),enemy(4,0,100),enemy(5,0,50)})
  for i=1,12 do w.bullets[i]=bullet(i%3,20) end
  local r=observe(w)
  check(r.c2.has_ignition and r.c2.chain_enemies==5 and r.c2.chain_bullets==12,
    '250-pixel near-field cutoff severed the high part of a C2 propagation chain')
  check(r.counts.spirits==3 and r.counts.erasable==0,'full C2 window changed ordinary near-field counts')
  check(#r.c2.chain_ids==5,'high relay nodes omitted from C2 lock IDs')
end
do
  local w=world(100,{enemy(1,0,20)},{bullet(0,20)})
  local r=observe(w)
  check(r.c2.target_y==100 and r.c2.has_ignition,'actual illegal-height snapshot was rewritten')
  check(r.c2_position.has_ignition and r.c2_position.target_y>=150,'planner proposed release above the limit')
  w.player.x,w.player.y=135,431
  w.enemies={enemy(2,120,300)}
  r=observe(w)
  check(r.c2.target_x==135 and r.c2.target_y==431,'actual wall-side centre was clamped')
  check(r.c2_position.target_y>=431 and r.c2_position.target_x<=136,'wall margin forced an upward release preference')
  check(r.c2_position.candidate_count<=9,'clamped candidates were not bounded')
end
do
  local w=world(432,{enemy(1,0,270)},{bullet(0,230)})
  w.player.x=130
  -- At the physical side/bottom wall use a nearby seed that remains reachable.
  w.enemies={enemy(1,120,270)};w.bullets={bullet(120,230)}
  local r=observe(w)
  check(r.c2_position.has_ignition and r.c2_position.target_x==130 and r.c2_position.target_y==432,
    'legal current point was replaced by an upward/clamped release centre')
  check(r.c2_position.at_target and r.c2_position.candidate_count<=9,'current boundary candidate not bounded/preserved')
  check(r.c2_position.chain_bullets==1,'bottom release lost its circle-exterior resource')
end
do
  local w=world(320,{enemy(1,0,260),enemy(2,0,200),enemy(3,0,140)},{bullet(0,160,0,4)})
  local r=observe(w)
  check(r.c2_position.has_ignition and r.c2_position.chain_bullets==0,
    'lower release counted a bullet that later crosses its full C2 envelope')
  w.bullets={bullet(0,160,0,-1)}
  r=observe(w)
  check(r.c2_position.chain_bullets==1,'outward-moving net bullet excluded at every lower site')
end
do
  local w=world(320,{enemy('left',-100,260),enemy('right',100,260)})
  for i=1,20 do w.bullets[i]=bullet(100,220) end
  local r=observe(w,{lock_ids={left=true}})
  check(r.c2_position.has_ignition and r.c2_position.chain_enemies==1
    and r.c2_position.chain_ids[1]=='left','preferred site borrowed an unrelated unlocked group')
  check(not observe(w,{lock_ids={}}).c2_position.has_ignition,'empty group lock became an unlocked position search')
  w.enemies[1].enabled=false
  check(not observe(w,{lock_ids={left=true}}).c2_position.has_ignition,'lost lock jumped to a replacement chain')
end
do
  for _,e in ipairs({enemy(1,145,300),enemy(2,0,449),enemy(3,0,-1)}) do
    local r=observe(world(320,{e}))
    check(not r.c2.has_ignition and not r.c2_position.has_ignition,'off-field group entered C2 assessment')
  end
  local w=world(320,{enemy(1,0,260)},{bullet(0,250)})
  local baseline=observe(w)
  for id=0,15 do
    w.player.character=id
    local r=observe(w)
    check(r.c2_position.target_x==baseline.c2_position.target_x
      and r.c2_position.target_y==baseline.c2_position.target_y,'character-specific position disablement')
  end
  local r=observe(w,nil,{release_min_y=0,release_max_y=999,release_side_limit=999,
    release_step=0/0,swallow_weight=0/0,travel_weight=math.huge})
  check(r.c2_position.has_ignition and r.c2_position.target_y>=150
    and r.c2_position.target_y<=420 and math.abs(r.c2_position.target_x)<=124,'malformed config bypassed bounds')
end

-- Reused coordinates must never reuse yields, seed objects or eligibility.
do
  local w=world(320,{enemy(1,0,140),enemy(2,0,200),enemy(3,0,260)})
  for i=1,50 do w.bullets[i]=bullet(i%4,160) end
  local state={}
  local first=observe(w,state)
  check(first.stats.c2_position_full_search,'first resources did not trigger full search')
  local cache_x,cache_y=state.bloom_observer_position_x,state.bloom_observer_position_y
  check(cache_y>320,'cache fixture failed to select a lower site')
  for tick=2,7 do
    w.bullets[#w.bullets+1]=bullet(0,160)
    local r=observe(w,state,{prediction_frames=10+tick})
    check(r.stats.c2_position_full_search==(tick==7),'dynamic prediction ETA broke six-observation search cadence')
    check(r.c2.chain_bullets==0 and r.c2.contested_bullets==#w.bullets,'actual yield was cached')
    check(r.c2_position.chain_bullets==#w.bullets,'preferred-site yield was cached')
    if tick<7 then check(r.stats.c2_position_evaluations<=2,'intermediate frame assessed more than current/cached points') end
  end
  -- Swallowing near the cached lower site makes current better. Keep the old
  -- coordinates for the next comparison, without forcing a full search now.
  w.bullets={}
  for i=1,100 do w.bullets[i]=bullet(140,445) end
  local r=observe(w,state)
  check(not r.stats.c2_position_full_search and r.c2_position.at_target,
    'worse cached merit did not select actual or caused an immediate full search')
  check(state.bloom_observer_position_x==cache_x and state.bloom_observer_position_y==cache_y,
    'losing one comparison discarded cached coordinates and search cadence')
  r=observe(w,state,{release_min_y=390})
  check(r.stats.c2_position_full_search and r.c2_position.target_y>=390,'new height config reused illegal cached point')
  r=observe(w,state,{release_min_y=390,position_search_interval=1})
  check(r.stats.c2_position_full_search,'interval=1 did not force full search')
  r=observe(w,state,{release_min_y=390,position_search_interval=1})
  check(r.stats.c2_position_full_search,'interval=1 skipped a repeated search')
end
do
  local w=world(320,{enemy('left',-100,260),enemy('right',100,260)})
  local state={lock_ids={left=true}}
  observe(w,state)
  state.lock_ids={right=true}
  local r=observe(w,state)
  check(r.c2_position.has_ignition and #r.c2_position.chain_ids==1 and r.c2_position.chain_ids[1]=='right',
    'new lock borrowed the cached previous chain')
  state.lock_ids={}
  r=observe(w,state)
  check(not r.c2.has_ignition and not r.c2_position.has_ignition,'empty lock reused cached ignition/yield')
  check(state.bloom_observer_position_x==nil,'ineligible cached coordinates were not cleared')
  state.lock_ids=nil
  r=observe(w,state)
  check(r.stats.c2_position_full_search and r.c2_position.has_ignition,'resources becoming eligible waited for the periodic tick')
  w.enemies[1].enabled,w.enemies[2].enabled=false,false
  r=observe(w,state)
  check(not r.c2_position.has_ignition and r.c2_position.chain_bullets==0,'disabled seeds reused old resources')
  w.enemies={enemy('fresh',0,250)}
  r=observe(w,state)
  check(r.stats.c2_position_full_search and r.c2_position.has_ignition,'fresh arrival failed to trigger immediate search')
  w.player.character=7
  check(observe(w,state).stats.c2_position_full_search,'character/config identity change retained the old search')
end
do
  local w,state=world(320),{}
  for i=1,2000 do w.bullets[i]=bullet(i%8,300,0,1) end
  for tick=1,8 do
    local r=observe(w,state)
    check(not r.stats.c2_position_full_search and r.stats.c2_position_evaluations==1
      and r.stats.c2_bullet_tests<=4000,'pure-bullet scene repeated candidate scans')
  end
  w.enemies={enemy(1,0,250)}
  check(observe(w,state).stats.c2_position_full_search,'first enemy after empty scene waited six frames')
end

-- Test the scene-size bound, not a machine-specific timing pass/fail threshold.
local clock=perf_now or os.clock
for _,dense in ipairs({false,true}) do
  local w=world(400)
  for i=1,140 do w.enemies[i]=enemy(i,dense and i%8 or i%16*16-128,dense and 270+i%4 or 20+i%8*50) end
  for i=1,2000 do w.bullets[i]=bullet(dense and i%10 or i%32*8-128,
    dense and 270+i%10 or 16+i%416,(i%7-3)*.2,.5+i%5*.2) end
  local count,state,result=BENCH_NEW_ITERATIONS or 20,{},nil
  collectgarbage('collect')
  local started=clock()
  for i=1,count do result=observe(w,state) end
  local ms=(clock()-started)*1000/count
  check(result.stats.truncated,'enemy-slot cap did not report truncation')
  check(result.stats.bullets_seen==2000,'bounded evaluation silently dropped bullets')
  check(result.c2.chain_enemies<=128 and result.c2_position.chain_enemies<=128,'C2 enemy cap exceeded')
  check(result.stats.c2_position_candidates<=9 and result.stats.c2_bullet_tests<=2000*2*10,
    'position search exceeded ten centres/two snapshots per bullet')
  check(result.stats.enemy_pair_tests+result.stats.c2_enemy_pair_tests<=2*128*127,
    'position candidates rebuilt enemy graphs')
  print(string.format('position_perf,%s,enemies=140(capped128),bullets=2000,ms=%.3f,candidates=%d,bullet_tests=%d',
    dense and 'dense' or 'spread',ms,result.stats.c2_position_candidates,result.stats.c2_bullet_tests))
end
print('bloom_position_test: PASS ('..checks..' assertions); native64 synthetic timing, not live FPS')
