-- 3.2.5: the 180-second bloom rule uses 10800 Timer units. Synthetic
-- decision snapshots isolate timing/diagnostics, not rank or energy physics.
local bloom=dofile('bloom.lua')
local checks,cases,failures=0,0,{}
local function check(v,m) checks=checks+1;assert(v,m) end
local function eq(a,b,m) check(a==b,m..': '..tostring(a)..' ~= '..tostring(b)) end
local function scenario(name,fn)
  cases=cases+1;local ok,err=pcall(fn)
  if not ok then failures[#failures+1]=name..': '..tostring(err) end
end
local function fixture(time)
  return {state={battle_time=time or 0},cfg=bloom.defaults,
    world={player={x=0,y=320,life=10,currentCharge=0,currentChargeMax=200,chargeSpeed=10,
      sensor={state=0,canCharge=true,timeScale=1,cutIn=false,chargeWarmupFrames=0}},
      bullets={},enemies={},exAttacks={}},
    obs={valid=true,counts={field_erasable=100},c2={}}}
end
local function tick(f) return bloom.update(f.world,f.state,f.cfg,f.obs) end
local function thresholds(f,enter,leave)
  eq(f.state.bloom_enter_threshold,enter,'entry diagnostic')
  eq(f.state.bloom_exit_threshold,leave,'exit diagnostic')
end
scenario('180 updates are only three seconds',function()
  local f=fixture();for _=1,180 do tick(f) end
  eq(f.state.battle_time,180,'Timer updates');check(f.state.bloom_mode~=true,'180 updates must not activate late bloom')
  thresholds(f,160,110);check(f.state.bloom_late_active~=true,'late diagnostic must be false')
end)
scenario('10800 Timer boundary and late hysteresis',function()
  local f=fixture(10798);tick(f)
  eq(f.state.battle_time,10799,'pre-boundary');thresholds(f,160,110)
  check(f.state.bloom_mode~=true,'one Timer before 180 seconds is early')
  tick(f);eq(f.state.battle_time,10800,'exact 180-second boundary');thresholds(f,60,40)
  check(f.state.bloom_late_active==true and f.state.bloom_mode==true,'late rule enters exactly at 180 seconds')
  f.obs.counts.field_erasable=40;tick(f);check(f.state.bloom_mode==true,'exit threshold itself remains in mode')
  f.obs.counts.field_erasable=39;tick(f);check(f.state.bloom_mode~=true,'below late exit leaves mode')
end)
scenario('half-scale takes two callbacks per Timer unit',function()
  local f=fixture(10799);f.world.player.sensor.timeScale=0.5
  tick(f);eq(f.state.battle_time,10799.5,'half-scale first step');check(f.state.bloom_mode~=true,'not late after half step')
  tick(f);eq(f.state.battle_time,10800,'half-scale second step');check(f.state.bloom_late_active==true,'scaled boundary')
end)
scenario('cut-ins and time stops freeze the clock',function()
  for _,mode in ipairs({'cutIn','timeScale'}) do
    local f=fixture(10799);tick(f);local before=f.state.battle_time
    f.world.player.sensor[mode]=mode=='cutIn' and true or 0
    for _=1,120 do tick(f) end
    eq(f.state.battle_time,before,'clock freezes during '..mode)
  end
  local f=fixture(10799);f.world.player.sensor.cutIn=true
  for _=1,60 do tick(f) end
  eq(f.state.battle_time,10799,'cut-in cannot cross threshold')
  f.world.player.sensor.cutIn=false;tick(f);check(f.state.bloom_late_active==true,'resuming one active Timer reaches threshold')
end)
scenario('valid stable speed leaves base diagnostics intact',function()
  local f=fixture();f.obs.counts.field_erasable_speed=2
  for _=1,100 do tick(f) end
  thresholds(f,160,110)
  check(f.state.bloom_speed_active~=true and f.state.bloom_late_active~=true,'stable speed is not a speed/rank increase')
end)
scenario('speed proxy lowers threshold before the clock boundary',function()
  local f=fixture();f.obs.counts.field_erasable_speed=2
  for _=1,40 do tick(f) end
  f.obs.counts.field_erasable_speed=4
  for _=1,60 do tick(f) end
  thresholds(f,90,60)
  check(f.state.bloom_speed_active==true and f.state.bloom_late_active~=true,'speed diagnostic is separate from late clock')
  check(f.state.bloom_mode==true,'early speed-adjusted threshold permits medium field')
end)
scenario('opponent advantage adjusts effective entry only',function()
  local f=fixture();f.world.player.currentChargeMax=300
  f.world.player.sensor.opponentApiVersion=1
  f.world.player.sensor.opponent={valid=true,chargeMax=200}
  f.obs.counts.field_erasable=120;tick(f)
  thresholds(f,120,110)
  check(f.state.bloom_opponent_adjusted==true,'opponent adjustment is observable')
  check(f.state.bloom_mode==true,'exact 100-stock lead lowers entry')
  local g=fixture();g.world.player.currentChargeMax=300
  g.world.player.sensor.opponentApiVersion=1;g.world.player.sensor.opponent={valid=false,chargeMax=0}
  tick(g);thresholds(g,160,110);check(g.state.bloom_opponent_adjusted~=true,'invalid opponent is unknown, not zero stock')
end)
scenario('late and speed rules use the lower threshold without resetting time',function()
  local f=fixture(10700);f.obs.counts.field_erasable_speed=2
  for _=1,40 do tick(f) end
  f.obs.counts.field_erasable_speed=4
  for _=1,60 do tick(f) end
  eq(f.state.battle_time,10800,'clock accumulates independently of speed proxy')
  thresholds(f,60,40)
  check(f.state.bloom_late_active==true and f.state.bloom_speed_active==true,'both causes remain diagnostic')
end)
for _,message in ipairs(failures) do print('FAIL '..message) end
assert(#failures==0,string.format('bloom clock: %d/%d scenarios failed',#failures,cases))
print(string.format('bloom clock PASS: %d scenarios, %d assertions',cases,checks))
