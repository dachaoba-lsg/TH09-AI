-- Spatial resource policy tests; no game process or game physics changes.
local observer = dofile("bloom_observer.lua")
local floor = math.floor
local checks = 0
local function check(v, message) checks = checks + 1; assert(v, message) end
local function enemy(id, x, y, spirit, activated, vx, vy)
  return { id = id, enabled = true, x = x, y = y, vx = vx or 0, vy = vy or 0,
    isSpirit = spirit or false, isActivatedSpirit = activated or false,
    isBoss = false, isLily = false, isPseudoEnemy = false }
end
local function bullet(x, y, vx, vy)
  return { enabled = true, x = x, y = y, vx = vx or 0, vy = vy or 0, isErasable = true }
end
local function world(enemies, bullets)
  return { player = { x = 0, y = 320, character = 0 }, enemies = enemies or {}, bullets = bullets or {} }
end
local function observe(w, cfg, state) return observer.observe(w, state or {}, cfg) end

do
  local r = observe(world())
  check(r.valid and not r.has_target and r.chain_score == 0, "empty scene invented a target")
  check(not observe({}).valid, "missing player accepted")
  check(not observe({ player = { x = 0/0, y = 1 } }).valid, "NaN player accepted")
  check(not observe(false).valid, "non-table scene accepted")
end
do
  local bullets = {}
  for i = 1, 100 do bullets[i] = bullet(i % 10, 210 + i % 5) end
  local r = observe(world({}, bullets))
  check(r.counts.erasable == 100 and not r.has_target, "pure bullets became an ignition source")
  check(r.chain_score == 0 and r.chain_bullets == 0 and r.future_score == 0,
    "pure bullets invented a propagating chain")
end
do
  local clustered, scattered = world(), world()
  for i = 1, 5 do
    clustered.enemies[i] = enemy(i, (i - 3) * 15, 220)
    scattered.enemies[i] = enemy(i, (i - 3) * 100, 220)
  end
  for i = 1, 60 do
    clustered.bullets[i] = bullet(i % 20 - 10, 210 + i % 20)
    scattered.bullets[i] = bullet(250, 80 + i)
  end
  local a, b = observe(clustered), observe(scattered)
  check(a.counts.fairies == b.counts.fairies and a.counts.erasable == b.counts.erasable,
    "distribution fixture counts differ")
  check(a.chain_enemies == 5 and b.chain_enemies == 1, "spatial enemy connectivity ignored")
  check(a.chain_bullets == 60 and b.chain_bullets == 0, "distant bullets counted as useful")
  check(a.chain_score > b.chain_score + 4, "equal totals yielded equal chain assessment")
end
do
  -- Two fairies, an activated spirit and another fairy form a connected chain.
  -- Unactivated spirits relay blasts too, but cannot be a direct ignition.
  local w = world({ enemy(1,-75,230), enemy(2,-25,230), enemy(3,25,230,true,true),
    enemy(4,75,230), enemy(5,30,210,true,false) })
  local r = observe(w)
  check(r.chain_enemies == 5 and r.counts.fairies == 3 and r.counts.activated == 1,
    "fairies and activated spirits did not connect")
  check(r.chain_fairies == 3 and r.chain_activated == 1 and r.chain_spirits == 1,
    "component enemy kinds missing")
  check(r.counts.spirits == 1 and r.focus_value > 0, "unactivated spirit opportunity lost")
  w.enemies[3].isActivatedSpirit = false
  local next = observe(w)
  check(next.chain_enemies == 5 and next.chain_spirits == 2 and next.counts.activated == 0
    and next.counts.spirits == 2, "unactivated spirit failed to relay the blast")
  check(next.ignition_id ~= 3 and next.ignition_id ~= 5,
    "unactivated spirit was selected as a directly shootable ignition")
end
do
  local w = world({enemy("fairy-left",-60,220), enemy("relay",0,220,true,false), enemy("fairy-right",60,220)})
  local r = observe(w)
  check(r.has_ignition and r.chain_enemies == 3 and r.chain_fairies == 2 and r.chain_spirits == 1,
    "fairy to unactivated spirit to distant fairy did not connect")
  check(r.ignition_id ~= "relay" and #r.chain_ids == 3, "relay became ignition or was omitted from lock IDs")
  w.enemies[1].enabled, w.enemies[3].enabled = false, false
  r = observe(w)
  check(r.has_target and r.focus_value > 0 and not r.has_ignition and r.ignition_x == nil,
    "pure unactivated relay was incorrectly considered directly ignitable")
end
do
  local w, state = world({ enemy("spirit-one",0,220,true,false) }), {}
  check(observe(w,nil,state).activated_gain == 0, "initial spirit counted as focus feedback")
  w.enemies[1].isActivatedSpirit = true
  local r = observe(w,nil,state)
  check(r.activated_gain == 1 and r.ignition_id == "spirit-one", "stable string ID or activation feedback lost")
  check(observe(w,nil,state).activated_gain == 0, "one activation counted repeatedly")
  w.enemies[2] = enemy("new-already-activated",10,220,true,true)
  check(observe(w,nil,state).activated_gain == 0, "arrival mistaken for observed activation")
end
do
  local w, state = world({enemy("left",-100,230),enemy("right",100,230)}), {}
  for i=1,30 do w.bullets[i]=bullet(100+i%3,230) end
  check(observe(w,nil,state).target_id == "right", "strong disconnected fixture not selected")
  state.bloom_observer_lock_id = "left"
  local r = observe(w,nil,state)
  check(r.target_id == "left" and r.chain_bullets == 0, "locked chain borrowed another target's resources")
  w.enemies[1].enabled = false
  check(not observe(w,nil,state).has_target, "disappeared lock silently switched to another target")
  state.bloom_observer_lock_id = nil
  check(observe(w,nil,state).target_id == "right", "cleared target lock did not restore target selection")
end
do
  local w, state = world({enemy("a",-100,230),enemy("b",-70,230),enemy("relay",-40,230,true,false)}), {}
  local initial = observe(w,nil,state)
  state.lock_ids = {}
  for _, id in ipairs(initial.chain_ids) do state.lock_ids[id] = true end
  check(state.lock_ids.a and state.lock_ids.b and state.lock_ids.relay,
    "original chain set omitted ordinary or unactivated nodes")
  w.enemies[4],w.enemies[5],w.enemies[6] = enemy("new-a",100,230),enemy("new-b",125,230),enemy("new-c",145,230)
  for i=1,30 do w.bullets[i]=bullet(120+i%3,230) end
  state.bloom_observer_lock_id = "new-a"
  local r = observe(w,nil,state)
  check(r.has_ignition and r.chain_enemies == 3 and r.chain_bullets == 0 and r.ignition_x < 0,
    "set lock lost priority or borrowed the stronger unrelated replacement chain")
  w.enemies[1].enabled = false
  r = observe(w,nil,state)
  check(r.has_ignition and r.ignition_id == "b" and r.chain_spirits == 1 and #r.chain_ids == 2,
    "death of first fairy discarded surviving original chain nodes")
  w.enemies[2].enabled = false
  r = observe(w,nil,state)
  check(not r.has_ignition, "pure surviving unactivated spirit satisfied ignition gate")
  w.enemies[7] = enemy("joining-fairy",0,230)
  r = observe(w,nil,state)
  check(r.has_ignition and r.ignition_id == "joining-fairy" and r.chain_spirits == 1,
    "surviving original spirit did not anchor its newly connected ignitable group")
  w.enemies[3].enabled = false
  r = observe(w,nil,state)
  check(not r.has_target and not r.has_ignition and #r.chain_ids == 0,
    "all original nodes lost but unrelated replacement still satisfied set lock")
  state.lock_ids = {}
  check(not observe(w,nil,state).has_ignition, "empty set was treated as unlocked")
  state.lock_ids = nil
  check(observe(w,nil,state).ignition_id == "new-a", "nil set did not restore legacy single-ID behavior")
  state.bloom_observer_lock_id = nil
  check(observe(w,nil,state).has_ignition, "cleared locks did not restore ordinary selection")
end
do
  local w = world({ enemy(1,-100,230), enemy(2,100,230) })
  for i = 1, 31 do w.bullets[i] = bullet(-100 + i * 6, 230) end
  local r = observe(w)
  check(r.chain_enemies == 1 and r.chain_bullets < #w.bullets,
    "line of white bullets incorrectly propagated explosions between enemies")
end
do
  local a, b = enemy(1,-70,220,false,false,2,0), enemy(2,70,220,false,false,-2,0)
  local r = observe(world({a,b}), { prediction_frames = 24 })
  check(r.chain_enemies == 1 and r.future_enemies == 2 and r.future_score > r.chain_score,
    "approaching enemies failed to create a future window")
  check(r.target_id == r.ignition_id and r.target_x == r.ignition_x,
    "movement and shooting targets differ")
  check(r.target_y == r.ignition_y + observer.defaults.target_below, "target position offset incorrect")
  check(r.future_has_ignition and r.future_aligned and r.future_ignition_x == -22,
    "future ignition is missing or uses another component's coordinates")
  check(r.future_target_y == r.future_ignition_y + observer.defaults.target_below,
    "future target position is not a player coordinate")
  local departing = observe(world({enemy(1,0,220,false,false,20,0)}), {prediction_frames=24})
  check(not departing.future_has_ignition and departing.future_ignition_x == nil
    and not departing.future_aligned, "departed future ignition remained valid")
end
do
  local w = world({ enemy(1,0,220,true,false), enemy(2,20,220,true,false) })
  local r = observe(w)
  check(r.has_target and not r.has_ignition and r.ignition_x == nil, "focus-only scene became ignitable")
  check(r.chain_score == 0 and r.focus_spirits == 2 and r.focus_value > 1, "spirit grouping failed")
end
do
  local w = world({enemy(1,0,220), enemy(2,1,220), enemy(3,2,220), enemy(4,3,220),
    enemy(5,4,220), enemy(6,5,220), enemy(7,6,220)}, {bullet(0,220),bullet(1,220),bullet(2,220)})
  w.enemies[2].enabled = false
  w.enemies[3].isBoss, w.enemies[4].isLily, w.enemies[5].isPseudoEnemy = true,true,true
  w.enemies[6].x, w.enemies[7].vy = 0/0, math.huge
  w.bullets[2].enabled, w.bullets[3].x = 0, 0/0
  local state, r = {}, nil
  r = observe(w,nil,state)
  check(r.counts.fairies == 1 and r.chain_enemies == 1 and r.counts.erasable == 1,
    "disabled, special or invalid objects became resources")
  check(r.stats.invalid_objects == 5, "invalid diagnostics inconsistent")
  w.enemies[1].enabled = false
  r = observe(w,nil,state)
  check(not r.has_target and state.bloom_observer_target_id == nil, "lost target retained stale resources")
end
do
  local w = world({ enemy(1,10,220), enemy(2,30,220,true,true), enemy(3,12,200,true,false) },
    {bullet(15,210),bullet(20,215)})
  local reference = observe(w)
  for character = 0, 15 do
    w.player.character = character
    local r = observe(w)
    check(r.has_target and r.chain_score == reference.chain_score and r.focus_value == reference.focus_value,
      "character branch disabled or fabricated resource advantage: " .. character)
  end
end
do
  local w = world({ enemy(1,-10,220), enemy(2,10,220) }, {bullet(0,220)})
  local r = observe(w, { prediction_frames = 0/0, grid_size = 0, max_enemies = math.huge })
  check(r.valid and r.chain_bullets == 1, "overlapping node neighborhoods double counted one bullet")
  check(r.chain_score < math.huge and r.chain_score == r.chain_score, "invalid config contaminated score")
  local snapshot_x = w.enemies[1].x
  observe(w)
  check(w.enemies[1].x == snapshot_x and w.player.character == 0, "observer mutated game snapshot")
end

-- C2 is an expanding area ignition, independently of ordinary-shot eligibility.
do
  local w = world({enemy("s1",0,220,true,false),enemy("s2",0,160,true,false),
    enemy("s3",0,100,true,false),enemy("s4",0,90,true,false)})
  for i=1,20 do w.bullets[i]=bullet(i%4,75) end
  local r = observe(w)
  check(not r.has_ignition and r.c2.has_ignition, "pure unactivated spirits cannot be C2 seeds")
  check(r.c2.chain_enemies == 4 and r.c2.chain_spirits == 4 and #r.c2.chain_ids == 4,
    "C2 propagation group lost unactivated spirit nodes")
  check(r.c2.chain_bullets == 20 and r.c2.future_bullets == 20 and r.c2.future_has_ignition,
    "C2 failed to connect a reachable seed to net bullets beyond its own circle")
  check(r.c2.target_x == w.player.x and r.c2.target_y == w.player.y,
    "C2 release centre confused with ordinary-shot alignment")
  local shifted = observe(world({enemy("off-axis",100,220,true,false)}))
  check(shifted.c2.has_ignition and not shifted.ignition_aligned,
    "C2 area ignition incorrectly requires ordinary-shot horizontal alignment")
  local state = {lock_ids={}}
  for _,id in ipairs(r.c2.chain_ids) do state.lock_ids[id]=true end
  w.enemies[1].enabled=false
  check(observe(w,nil,state).c2.has_ignition, "C2 set lock lost surviving original spirit seed")
  for _,e in ipairs(w.enemies) do e.enabled=false end
  w.enemies[5]=enemy("replacement",100,220,true,false)
  check(not observe(w,nil,state).c2.has_ignition, "C2 borrowed unrelated replacement group after original loss")
  state.lock_ids={}
  check(not observe(w,nil,state).c2.has_ignition, "C2 ignored empty set lock")
end
do
  local w = world({enemy(1,-20,220),enemy(2,0,220),enemy(3,20,220)})
  local baseline = observe(w).c2.chain_score
  for i=1,100 do w.bullets[i]=bullet(i%5,215) end
  local r=observe(w)
  check(r.chain_bullets == 100 and r.c2.chain_bullets == 0,
    "direct/contested C2 bullets were counted as chain return/recharge")
  check(math.abs(r.c2.chain_score-baseline) < 1e-8, "swallowed bullets boosted C2 score indirectly")
  check(r.c2.contested_bullets == 100 and r.c2.direct_bullets == 0,
    "overlapping C2/chain envelope was not reported as contested")
  r=observe(world({}, {bullet(0,220)}))
  check(not r.c2.has_ignition and r.c2.chain_bullets == 0 and r.c2.direct_bullets == 1,
    "pure swallowed bullets became a C2 resource or lost diagnostics")
end
do
  local w=world({enemy(1,0,220),enemy(2,0,160,true,false),enemy(3,0,100,true,false)})
  w.bullets={bullet(0,75,0,4)}
  local r=observe(w)
  check(r.c2.has_ignition and r.chain_bullets == 1 and r.c2.chain_bullets == 0,
    "currently outside bullet heading into C2 envelope counted as net yield")
  check(r.c2.contested_bullets == 1, "swept envelope exclusion not reported")
  w.bullets={bullet(0,75,0,-1)}
  r=observe(w)
  check(r.c2.chain_bullets == 1, "bullet remaining outside C2 envelope was wrongly excluded")
  -- Both endpoints are outside: the interior of the segment crosses the disk.
  w=world({enemy(1,0,190),enemy(2,-60,170,true,false),enemy(3,-120,150,true,false),
    enemy(4,-180,130,true,false),enemy(5,-230,130,true,false)}, {bullet(-230,130,12,0)})
  r=observe(w)
  check(r.c2.has_ignition and r.chain_bullets == 1 and r.c2.chain_bullets == 0,
    "endpoint-only C2 sweep missed a bullet crossing the complete envelope")
end
do
  check(observe(world({enemy(1,0,132,true,false)})).c2.has_ignition,
    "last live C2 radius 188 should touch the enemy centre")
  check(not observe(world({enemy(1,0,131,true,false)})).c2.has_ignition,
    "C2 seed outside last live radius accepted")
  check(not observe(world({enemy(1,0,220,true,false,0,-6)})).c2.has_ignition,
    "enemy outrunning the expanding wave accepted as C2 seed")
  check(observe(world({enemy(1,0,100,true,false,0,2)})).c2.has_ignition,
    "approaching enemy that the expanding wave reaches was discarded")
end

-- Independent discrete reference for the analytic growing-circle contact
-- solver, including approach, retreat and brief crossings between updates.
do
  for i=1,2048 do
    -- Start inside the complete field. 2.0.3 excludes off-field groups even
    -- when a test widens the unrelated ordinary-shot observation window.
    local x,y,vx,vy=(i%41)*7-140,320-(i%47)*6,(i%19)-9,(i%23)-11
    local expected=false
    for tick=1,47 do
      local dx,dy=x+vx*tick,y+vy*tick-320
      if dx*dx+dy*dy <= (4*tick)^2 then expected=true;break end
    end
    local r=observe(world({enemy(i,x,y,true,false,vx,vy)}),
      {prediction_frames=0,above_range=2048,side_range=2048})
    check(r.c2.has_ignition == expected, 'C2 contact disagrees with discrete reference: '..i)
  end
end

print("bloom_observer correctness: PASS (" .. checks .. " assertions)")
local clock = perf_now or os.clock
for _, dense in ipairs({false,true}) do
  for _, count in ipairs({0,200,1000,2000}) do
    local w = world()
    for i = 1, 128 do
      w.enemies[i] = enemy(i, dense and i%8 or (i%16-8)*16,
        dense and 210+i%4 or 100+floor(i/16)*20, i%4==0, i%8==0)
    end
    for i = 1, count do
      w.bullets[i] = bullet(dense and i%10 or (i%32-16)*8, dense and 210+i%10 or 90+i%210)
    end
    local iterations, state, result = BENCH_NEW_ITERATIONS or 30, {}, nil
    collectgarbage("collect")
    local started = clock()
    for i = 1, iterations do result = observe(w,nil,state) end
    local elapsed = (clock()-started)*1000/iterations
    check(result.stats.bullets_seen == count, "benchmark silently dropped bullets")
    check(result.stats.enemy_pair_tests <= 128*127 and result.stats.focus_pair_tests <= 128*128,
      "enemy computation exceeded fixed bound")
    check(#result.candidates <= observer.defaults.max_candidates, "unbounded result candidates")
    print(string.format("observer_perf,%s,enemies=128,bullets=%d,ms=%.3f,pairs=%d,grid=%d",
      dense and "dense" or "spread",count,elapsed,result.stats.enemy_pair_tests,result.stats.grid_queries))
  end
end
print("bloom_observer_test: PASS; native 64-bit Lua 5.1 microbenchmark, not game FPS")
