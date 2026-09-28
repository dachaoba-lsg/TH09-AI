-- Active v2.0.8 poison preference, native Lua 5.1 on/off latency comparison.
-- This is a synthetic 64-bit microbenchmark, not an in-game FPS guarantee.
HitType={Rect=0,Circle=1,RotatableRect=2}; ExAttackType={Medicine=16}
local dodge=dofile('dodge.lua')
local now=perf_now or os.clock
local iterations,warmups=30,3
local checks,total_enabled,total_changed=0,0,0
local function check(v,m) checks=checks+1;assert(v,m) end
local function config(enabled)
 local c=dofile('config.lua').dodge;c.poison_escape_enabled=enabled;return c
end
local cfg_off,cfg_on=config(false),config(true)
local intent={focus=false,focus_mismatch_cost=8,target_x=100,target_y=320,
 position_weight=.002,min_y=150}
local function world(cloud_count,object_count,dense)
 local clouds={}
 for i=1,cloud_count do
  -- Every cloud is settled, currently active and covers the player. Avoid
  -- a benchmark which accidentally times only the new feature's early exit.
  clouds[i]={x=20,y=320,radius=64,age=100,ageInt=100,framesLeft=200,active=true}
 end
 -- A 256-fold native binary32 multiplier has underflowed to zero. The Lua
 -- movement forecast remains unchanged; this fixture must not invent speed.
 local scale=cloud_count>=128 and 0 or .4^cloud_count
 local w={player={x=0,y=320,speedFast=4,speedSlow=2,
  hitBodyRect={type=0,width=4,height=4},hitBodyCircle={type=1,radius=2},
  sensor={apiVersion=1,valid=true,state=0,protectionFrames=0,cutIn=false,
   timeScale=1,movementEnabled=true,baseScaleX=1,baseScaleY=1,
   moveScaleX=scale,moveScaleY=scale,poisonClouds=clouds}},
  bullets={},enemies={},exAttacks={}}
 for i=1,object_count do
  if dense then
   -- Many broad-phase candidates and swept tests, while a valid stationary
   -- route remains clear. This also prevents all-collision early exits from
   -- being mistaken for the cost of enabled poison ranking.
   w.bullets[i]={vx=0,vy=0,hitBody={type=0,
    x=(i*37)%9-4,y=312+(i%3),width=4,height=4}}
  else
   w.bullets[i]={vx=(i%5-2)*.1,vy=.1,hitBody={type=0,
    x=(i*37)%273-136,y=32+(i*53)%200,width=4,height=4}}
  end
 end
 return w
end
local function benchmark(w,cfg,reference,geometric)
 for _=1,warmups do dodge.choose(w,{},cfg,intent) end
 collectgarbage('collect')
 local sum,peak,enabled,changed,last=0,0,0,0,nil
 for _=1,iterations do
  local start=now()
  local r=dodge.choose(w,{},cfg,intent)
  local elapsed=now()-start
  sum,peak=sum+elapsed,math.max(peak,elapsed)
  enabled=enabled+(r.poison_preference and 1 or 0)
  changed=changed+(r.poison_escape_changed and 1 or 0)
  check(r.objects_seen==#w.bullets,'object scan was truncated')
  check(r.poison_clouds==#w.player.sensor.poisonClouds,'active clouds were truncated')
  check(r.movement_segments<=18*14,'movement integration work became unbounded')
  check(r.trajectory_tests<=#w.bullets*r.movement_segments,'ordinary geometry grew an extra frame loop')
  check(math.floor(r.key/2)%2==0,'poison direction emitted X')
  if reference then
   check(r.focus==reference.focus,'preference changed the established Shift decision')
   check(not r.collides,'benchmark clear route acquired a collision')
   check(r.terrain_cost<=geometric.terrain_cost+1e-7,'poison bought wall exposure')
   check(r.danger<=geometric.danger+5.6+1e-7,'poison added a second soft-risk allowance')
  end
  last=r
 end
 -- Deliberately loose disaster bound: catches accidental unbounded loops,
 -- and makes no promise about 16.67ms callbacks or engine/rendering overhead.
 check(peak<2,'single synthetic dodge callback exceeded the two-second disaster bound')
 return {mean=sum*1000/iterations,peak=peak*1000,enabled=enabled,changed=changed,last=last}
end
local scenarios={
 {'clear',0,0,false},
 {'single_clear',1,0,false},
 {'sixteen_scattered',16,200,false},
 {'full_overlap_clear',256,0,false},
 {'single_dense',1,2000,true},
 {'full_overlap_dense',256,2000,true},
}
print('Synthetic native 64-bit Lua 5.1; 30 serial iterations + 3 warmups per toggle; no engine/injection/rendering cost.')
print('scenario,clouds,objects,off_mean_ms,off_peak_ms,on_mean_ms,on_peak_ms,enabled,changed,relevant,segments,trajectory_tests')
for _,scenario in ipairs(scenarios) do
 local name,clouds,objects,dense=unpack(scenario)
 local w=world(clouds,objects,dense)
 local geometric=dodge.choose(w,{},cfg_off)
 local off=benchmark(w,cfg_off)
 check(not off.last.collides,'benchmark fixture lost its clear route: '..name)
 local on=benchmark(w,cfg_on,off.last,geometric)
 check(off.enabled==0 and off.changed==0,'disabled preference ran: '..name)
 if clouds==0 then
  check(on.enabled==0 and on.changed==0 and on.last.key==off.last.key,
   'empty cloud list changed movement')
 else check(on.enabled==iterations,'active preference was not actually timed: '..name) end
 if name=='single_clear' then
  check(on.changed==iterations and on.last.terminal_x<0 and off.last.terminal_x>0,
   'single-cloud benchmark did not actually exercise a changed escape route')
 end
 total_enabled,total_changed=total_enabled+on.enabled,total_changed+on.changed
 print(string.format('%s,%d,%d,%.3f,%.3f,%.3f,%.3f,%d,%d,%d,%d,%d',
  name,clouds,objects,off.mean,off.peak,on.mean,on.peak,on.enabled,on.changed,
  on.last.objects_relevant,on.last.movement_segments,on.last.trajectory_tests))
end
check(total_enabled>0 and total_changed>0,'benchmark never exercised active poison optimization')
print(string.format('poison_preference_perf_test: PASS %d assertions; enabled=%d changed=%d',
 checks,total_enabled,total_changed))
