-- 3.2.5 held-C1 reserve policy. Snapshots are supplied explicitly: this is
-- not an energy simulator and never turns a predicted C1 yield into stock.
local bloom = dofile('bloom.lua')
local checks, cases, failures = 0, 0, {}
local function check(v, message) checks = checks + 1; assert(v, message) end
local function close(a, b, message) check(type(a) == 'number' and math.abs(a-b) < 0.0001, message) end
local function copy(t)
  local r = {}; for k,v in pairs(t) do r[k] = type(v)=='table' and copy(v) or v end; return r
end
local function scenario(name, fn)
  cases = cases + 1
  local ok, err = pcall(fn)
  if not ok then failures[#failures+1] = name .. ': ' .. tostring(err) end
end
local function fixture()
  local cfg = copy(bloom.defaults)
  cfg.armed_max_frames = 0 -- isolate reserve waits from existing shape waits
  local f = {cfg=cfg, state={target_level=1, fresh_charge=true, press_z=true,
    last_life=10, since_c=0, since_c2=0},
    world={player={x=0,y=320,life=10,currentCharge=50,currentChargeMax=190,
      chargeSpeed=3.3,sensor={state=0,canCharge=true,canPressZ=true,
        c1ActionActive=false,cutIn=false,timeScale=1,chargeWarmupFrames=0}},
      bullets={},enemies={},exAttacks={}},
    obs={valid=true, counts={field_erasable=0}, has_ignition=true,
      chain_score=5,chain_enemies=3,chain_bullets=10,chain_ids={1},
      target_x=0,target_y=320,
      c2={has_ignition=true,chain_score=6,chain_enemies=3,chain_bullets=12,
        direct_bullets=0,contested_bullets=0,future_has_ignition=true,
        future_enemies=3,future_bullets=12,future_score=6,target_x=0,target_y=320,
        chain_ids={1}}}}
  return f
end
local function tick(f, stock, charge)
  if stock ~= nil then f.world.player.currentChargeMax = stock end
  if charge ~= nil then f.world.player.currentCharge = charge end
  local before = f.world.player.currentChargeMax
  local r = bloom.update(f.world, f.state, f.cfg, f.obs)
  check(f.world.player.currentChargeMax == before, 'policy cannot manufacture stock')
  check((r.target_level or 0) <= 2 and not r.press_x and not r.use_x,
    'reserve must not request C3/C4 or X')
  return r
end
local function gains(f, stocks)
  local charges = {50,70,90,105}
  local r
  for i,stock in ipairs(stocks or {190,191,192,193}) do r=tick(f,stock,charges[i] or 105) end
  return r
end
local function waiting(f, r)
  check(r.phase=='armed' and r.reason=='wait_c2_refill' and r.press_z==true,
    'observed replenishment should preserve the held C1')
  check(f.state.c2_reserve_active==true, 'reserve active diagnostic')
  check((f.state.release_c1 or 0)==0, 'reserve cannot release a C1 first')
end
local function cancelled(f, r, why)
  check(f.state.c2_reserve_active~=true and r.reason~='wait_c2_refill', why)
end

scenario('static 199 is not replenishment evidence', function()
  local f=fixture(); local r=gains(f,{199,199,199,199})
  cancelled(f,r,'static 199 must not wait indefinitely')
  check((f.state.release_c1 or 0)==1,'normal mature C1 still releases')
end)
scenario('three positive samples retain charge then promote only on real 200', function()
  local f=fixture(); local r=gains(f); waiting(f,r)
  check(f.state.target_level==1 and f.state.c2_ready_updates==-1,'sub-200 is not a ready C2')
  r=tick(f,197,120); waiting(f,r)
  r=tick(f,200,140)
  check(f.state.target_level==2 and r.press_z==true,'real stock 200 promotes held charge')
  check((f.state.release_c1 or 0)==0,'promotion preserves charge without a C1 reset')
  r=tick(f,200,200)
  check(r.phase=='release' and (f.state.release_c2 or 0)==1,'actual mature C2 releases')
end)
scenario('no C2 resource and no deadline gives no reserve', function()
  local f=fixture();f.obs.c2={};local r=gains(f)
  cancelled(f,r,'replenishment alone cannot justify a C2')
end)
scenario('independent C2 deadline can justify otherwise empty resources', function()
  local f=fixture();f.obs.c2={};f.state.since_c2=479
  waiting(f,gains(f))
end)
scenario('stock below 190 stays with original policy', function()
  local f=fixture();cancelled(f,gains(f,{186,187,188,189}),'reserve margin boundary')
end)
scenario('too-slow refill cannot fit the reserve window', function()
  local f=fixture();cancelled(f,gains(f,{190,190.1,190.2,190.3}),'insufficient observed rate')
end)
scenario('minimum observed increment dominates a burst', function()
  local f=fixture();cancelled(f,gains(f,{190,191,191.1,194}),'mean/burst must not replace conservative rate')
end)
scenario('a stock decline breaks consecutive evidence', function()
  local f=fixture();cancelled(f,gains(f,{190,192,191,194}),'oscillation is not consecutive refill')
end)
scenario('two increments cannot stand in for three confirmed increments', function()
  local f=fixture();tick(f,190,50);tick(f,191,70)
  cancelled(f,tick(f,192,105),'the third positive increment has not happened')
end)
scenario('stock gained before holding C1 cannot be borrowed', function()
  local f=fixture()
  for _,stock in ipairs({190,192,194,196}) do
    f.state.target_level,f.state.press_z,f.state.fresh_charge=nil,false,nil
    tick(f,stock,0)
  end
  f.state.target_level,f.state.press_z,f.state.fresh_charge=1,true,true
  cancelled(f,tick(f,198,105),'new held C1 needs its own refill observations')
end)
scenario('future C1 estimate cannot fund reserve', function()
  local f=fixture();f.obs.future_score=10000;f.obs.future_bullets=10000
  f.obs.c1={valid=true,has_ignition=true,chain_score=10000,chain_bullets=10000,chain_enemies=100}
  cancelled(f,gains(f,{199,199,199,199}),'future chain estimates are not observed stock')
end)
scenario('refill interruption cancels an active reserve', function()
  local f=fixture();waiting(f,gains(f));local r=tick(f,193,115)
  cancelled(f,r,'zero gain must revoke evidence');check((f.state.release_c1 or 0)==1,'fall back to mature C1')
end)
scenario('resource disappearance cancels an active reserve', function()
  local f=fixture();waiting(f,gains(f));f.obs.c2={}
  cancelled(f,tick(f,194,115),'lost C2 demand cancels reserve')
end)
scenario('real stock reaching 200 does not override vanished C2 demand', function()
  local f=fixture();waiting(f,gains(f));f.obs.c2={}
  local r=tick(f,200,140)
  cancelled(f,r,'funding and surviving C2 demand are both required')
  check((f.state.release_c1 or 0)==1 and (f.state.release_c2 or 0)==0,
    'funded but no-longer-needed C2 returns to a real C1 release')
end)
scenario('already mature actual C2 cannot be relabeled C1 after demand vanishes', function()
  local f=fixture();waiting(f,gains(f));f.obs.c2={}
  local r=tick(f,200,200)
  cancelled(f,r,'mature C2 ends the old C1 reservation')
  check(r.phase=='release' and (f.state.release_c2 or 0)==1 and (f.state.release_c1 or 0)==0,
    'actual charge 200 is always counted as C2 even after resources vanish')
end)
scenario('unexpected held-charge reset discards prior reserve evidence', function()
  local f=fixture();waiting(f,gains(f))
  cancelled(f,tick(f,194,0),'charge dropping below 100 invalidates an active reserve')
  cancelled(f,tick(f,195,105),'a new charge cannot immediately reuse old refill samples')
end)
scenario('observer invalidity cancels active reserve', function()
  local f=fixture();waiting(f,gains(f));f.obs.valid=false
  cancelled(f,tick(f,194,115),'invalid observer cannot fund reserve')
end)
scenario('charge gate and active C1 cancel reserve', function()
  for _,field in ipairs({'canCharge','c1ActionActive'}) do
    local f=fixture();waiting(f,gains(f));f.world.player.sensor[field]=(field=='c1ActionActive')
    cancelled(f,tick(f,194,115),'engine gate must cancel reserve: '..field)
  end
end)
scenario('cut-in time stop and recovery cancel reserve', function()
  for _,mode in ipairs({'cutIn','timeScale','state'}) do
    local f=fixture();waiting(f,gains(f))
    f.world.player.sensor[mode]=mode=='cutIn' and true or (mode=='state' and 4 or 0)
    local r=tick(f,194,115);cancelled(f,r,'pause/recovery cancels reserve: '..mode)
    check((f.state.release_c2 or 0)==0,'paused reserve cannot release a C2')
  end
end)
scenario('hit revokes evidence even if sensor is already normal', function()
  local f=fixture();waiting(f,gains(f));f.world.player.life=7
  cancelled(f,tick(f,194,115),'hit must discard pre-hit reserve state')
end)
scenario('age budget cannot be extended by new increments', function()
  local f=fixture();waiting(f,gains(f));f.state.c2_reserve_age=18
  cancelled(f,tick(f,194,115),'expired Timer budget cannot restart while mature')
end)
scenario('C1 charge ceiling overrides expected stock gain', function()
  local f=fixture();waiting(f,gains(f))
  local r=tick(f,194,197)
  cancelled(f,r,'charge+speed >=200 must not keep C1 held')
  check((f.state.release_c1 or 0)==1,'ceiling falls back to C1 release')
end)
scenario('half-speed reserve age uses Timer units', function()
  local f=fixture();f.world.player.sensor.timeScale=0.5
  waiting(f,gains(f,{190,190.5,191,191.5}))
  local age=f.state.c2_reserve_age
  waiting(f,tick(f,192,115))
  close(f.state.c2_reserve_age-age,0.5,'reserve age must track scaled game time')
end)
scenario('C2 readiness uses real stock gates warmup and timeScale', function()
  local f=fixture();f.world.player.chargeSpeed=10
  f.world.player.sensor.chargeWarmupFrames=4;f.world.player.sensor.timeScale=0.5
  tick(f,210,100);close(f.state.c2_ready_updates,28,'ready updates = (warmup+remaining/speed)/scale')
  f=fixture();tick(f,199,100);check(f.state.c2_ready_updates==-1,'not ready below actual 200')
  f=fixture();f.world.player.sensor.canCharge=false;tick(f,210,100)
  check(f.state.c2_ready_updates==-1,'not ready with closed action gate')
  f=fixture();f.world.player.sensor.cutIn=true;tick(f,210,100)
  check(f.state.c2_ready_updates==-1,'not ready during cut-in')
  f=fixture();f.world.player.sensor.timeScale=0;tick(f,210,100)
  check(f.state.c2_ready_updates==-1,'not ready during time stop')
  f=fixture();f.world.player.sensor.c1ActionActive=true;tick(f,210,100)
  check(f.state.c2_ready_updates==-1,'active C1 cannot promise a new C2')
  f=fixture();f.world.player.sensor.state=4;tick(f,210,100)
  check(f.state.c2_ready_updates==-1,'recovery cannot promise a new C2')
end)
scenario('fractional warmup consumes its own update before charge updates', function()
  local f=fixture();f.world.player.sensor.chargeWarmupFrames=0.5
  tick(f,250,198)
  close(f.state.c2_ready_updates,2,'partial warmup plus partial remaining charge need two updates')
  f=fixture();f.state={};f.obs.valid=false
  f.world.player.sensor.chargeWarmupFrames=0.5;f.world.player.chargeSpeed=15
  tick(f,250,0)
  close(f.state.c2_ready_updates,15,'one warmup update plus fourteen charging updates is fifteen')
end)

for _,message in ipairs(failures) do print('FAIL '..message) end
assert(#failures==0, string.format('c2 reserve: %d/%d scenarios failed',#failures,cases))
print(string.format('c2 reserve PASS: %d scenarios, %d assertions',cases,checks))
