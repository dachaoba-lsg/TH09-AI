-- 3.8 human movement preferences: actual admitted geometry, safe speed changes,
-- bounded speed hysteresis and mech bypass. No game process or input is used.
-- Optional TH09_HUMAN_DODGE_BASELINE points to the unmodified 3.7 dodge.lua.
HitType = { Rect=0, Circle=1, RotatableRect=2 }
ExAttackType = { Medicine=16 }
local dodge = dofile('dodge.lua')
local checks, cases, failures = 0, 0, {}
local function check(value,message) checks=checks+1;assert(value,message) end
local function near(a,b,message) check(type(a)=='number' and math.abs(a-b)<1e-7,message..': '..tostring(a)..' != '..tostring(b)) end
local function copy(value)
  if type(value)~='table' then return value end
  local out={};for k,v in pairs(value) do out[k]=copy(v) end;return out
end
local function test(name,run)
  cases=cases+1;local ok,err=pcall(run)
  if ok then print('PASS '..name) else failures[#failures+1]=name..': '..tostring(err);print('FAIL '..name..': '..tostring(err)) end
end
local poison_diagnostic = {poison_cost=true, poison_nav_active=true, poison_level=true, poison_risk=true, poison_target_x=true, poison_target_y=true, poison_probe_count=true, poison_nav_samples=true}
local function same(a,b,path)
  check(type(a)==type(b),path..' type')
  if type(b)~='table' then check(a==b,path..' value');return end
  for k,v in pairs(b) do
    if type(k)~='string' or not (k:match('^human_') or poison_diagnostic[k]) then same(a[k],v,path..'.'..tostring(k)) end
  end
  for k in pairs(a) do
    if type(k)~='string' or not (k:match('^human_') or poison_diagnostic[k]) then check(b[k]~=nil,path..' unexpected '..tostring(k)) end
  end
end
local function config(enabled)
  local cfg=dofile('config.lua').dodge
  check(type(cfg.human_movement)=='table','human movement defaults are present')
  cfg.human_movement.enabled=enabled~=false
  -- Isolate 3.8 movement style; 3.9 common toxin navigation has its own suite.
  cfg.poison_navigation.enabled=false
  cfg.attention.enabled=true;cfg.attention.difficulty='unlimited'
  cfg.attention.tracked_threat=120;cfg.attention.threat_per_second=90;cfg.attention.plan_interval=1
  -- Isolate speed preferences from the existing direction cap, except where
  -- a case explicitly restores the cap. Speed switching is a separate input.
  cfg.move_change_budget=10000;cfg.move_change_min_frames=0
  return cfg
end
local function sensor()
  return {apiVersion=1,valid=true,state=0,protectionFrames=0,timeScale=1,cutIn=false,movementEnabled=true,
    baseScaleX=1,baseScaleY=1,moveScaleX=1,moveScaleY=1,poisonClouds={}}
end
local function player()
  return {x=0,y=320,speedFast=4,speedSlow=2,sensor=sensor(),
    hitBodyRect={type=0,x=0,y=320,width=4,height=4},hitBodyCircle={type=1,x=0,y=320,radius=2}}
end
local function circle(id,x,y,vx,vy,r)
  return {id=id,vx=vx or 0,vy=vy or 0,hitBody={type=1,x=x,y=y,radius=r or 2}}
end
local function rect(id,x,y,vx,vy,width,height)
  return {id=id,vx=vx or 0,vy=vy or 0,hitBody={type=0,x=x,y=y,width=width or 4,height=height or 4}}
end
local function world(bullets,p,ex,enemies)
  return {player=p or player(),bullets=bullets or {},exAttacks=ex or {},enemies=enemies or {}}
end
local function dense(count)
  local bullets={};for i=1,count or 100 do
    bullets[#bullets+1]=circle(i,(i%17-8)*4,280+(i%6)*2,0,-0.5)
  end;return world(bullets)
end
local function tick(side,state,cfg,intent)
  state.frame=(state.frame or 0)+1
  return dodge.choose(side,state,cfg,intent or {focus=false,min_y=150})
end
local function contract(out)
  check(type(out.human_enabled)=='boolean','explicit human enabled flag')
  check(type(out.human_pressure)=='number' and out.human_pressure>=0,'pressure count')
  check(type(out.human_slow)=='boolean','slow mode flag')
  check(type(out.human_speed_held)=='boolean' and type(out.human_speed_override)=='boolean','speed choice diagnostics')
  check(type(out.human_lane_cost)=='number' and out.human_lane_cost>=0,'bounded lane diagnostic')
  check((math.floor((out.key or 0)/4)%2==1)==out.focus,'reported focus matches actual Shift mask')
end
local function enter(side,state,cfg)
  local out
  for i=1,cfg.human_movement.enter_frames do out=tick(side,state,cfg);contract(out) end
  check(out.human_slow,'persistent observed density enters slow intent')
  -- Entry is an intent, not an immediate key rewrite: an already selected safe
  -- fast mode retains its short hold before applying the new slow preference.
  for i=1,cfg.human_movement.speed_hold_frames do
    if out.focus then break end
    out=tick(side,state,cfg);contract(out)
  end
  check(out.human_slow and out.focus,'slow intent eventually selects real slow candidate after bounded safe hold')
  return out
end

test('release defaults and empty field do not invent slow pressure',function()
  local cfg=config();local state={}
  check(cfg.human_movement.enter_bullets==12 and cfg.human_movement.exit_bullets==7,'density hysteresis thresholds')
  for i=1,30 do local out=tick(world(),state,cfg);contract(out)
    check(out.human_enabled and out.human_pressure==0 and not out.human_slow,'empty field pressure remains zero')
  end
end)
test('three current admitted dense observations enter slow mode',function()
  local cfg,state,side=config(),{},dense()
  for i=1,cfg.human_movement.enter_frames-1 do
    local out=tick(side,state,cfg);contract(out)
    check(out.attention_tracked==100 and out.human_pressure==100,'real tracked circle count, no capacity increase')
    check(not out.human_slow,'density must persist')
  end
  local out=tick(side,state,cfg);check(out.human_slow and not out.collides,'three observations enter slow intent safely')
  check(not out.focus and out.human_speed_held,'existing safe speed hold precedes the new preference')
  for i=1,cfg.human_movement.speed_hold_frames do if out.focus then break end;out=tick(side,state,cfg) end
  check(out.focus and not out.collides,'bounded hold eventually applies actual Shift')
end)
test('entry blips reset and exit has a longer quiet hysteresis',function()
  -- Reappearance pays acquisition again, so keep this separate hysteresis
  -- fixture within the actual credit budget instead of resetting attention.
  local cfg,state=config(),{};local busy=dense(12)
  for i=1,4 do tick(busy,state,cfg);tick(busy,state,cfg)
    check(not tick(world(),state,cfg).human_slow,'isolated two-frame blips do not accumulate')
  end
  enter(busy,state,cfg)
  for i=1,cfg.human_movement.exit_frames-1 do check(tick(world(),state,cfg).human_slow,'brief density relief retains slow mode') end
  check(not tick(world(),state,cfg).human_slow,'sustained quiet leaves slow mode')
end)
test('game-time speed changes preserve the configured holding duration',function()
  local cfg,state,side=config(),{},dense();side.player.sensor.timeScale=0.5
  for i=1,cfg.human_movement.enter_frames*2-1 do check(not tick(side,state,cfg).human_slow,'half speed requires twice the callbacks') end
  check(tick(side,state,cfg).human_slow,'entry accumulated actual game time')
end)
test('outside-circle bullets and untracked in-circle bullets remain invisible',function()
  local cfg=config();local outside={}
  for i=1,100 do outside[i]=circle(i,0,100,0,30) end
  for i=1,8 do local out=tick(world(outside),{},cfg);check(out.human_pressure==0 and not out.human_slow,'outside current circle cannot supply pressure') end
  cfg.attention.tracked_threat=0.1;cfg.attention.threat_per_second=0;cfg.attention.reflex_radius=0
  local state={attention_config=cfg.attention,attention_tokens=0}
  for i=1,8 do local out=tick(dense(),state,cfg)
    check(out.attention_tracked==0 and out.attention_skipped>0,'fixture truly refuses admission')
    check(out.human_pressure==0 and not out.human_slow and out.human_lane_cost==0,'new preferences cannot secretly inspect refused geometry')
  end
end)
test('free enemies poison terrain and warning beams do not fake bullet density',function()
  local cfg=config();local ex,enemies,warnings={},{},{}
  for i=1,20 do
    ex[i]=circle(i,0,320,0,0,64);ex[i].type=16;ex[i].hittable=true
    enemies[i]=circle(100+i,i-10,285,0,-0.5)
    warnings[i]={id=200+i,vx=0,vy=0,hitBody={type=2,x=-100,y=280+i,width=200,height=0,angle=0}}
  end
  local side=world(warnings,nil,ex,enemies);local state={}
  for i=1,8 do local out=tick(side,state,cfg);check(out.human_pressure==0 and not out.human_slow,'only actual admitted hard bullet/EX threats count') end
end)
test('slow preference and speed hold yield immediately to the only safe fast escape',function()
  local cfg,state=config(),{};enter(dense(),state,cfg)
  local side=world({rect(1001,0,306,0,4,400,4)})
  local out=tick(side,state,cfg)
  check(out.name=='fast-down' and not out.focus and not out.collides,'never apply Shift after planning fast escape')
  check(out.human_speed_override,'emergency speed override is recorded')
end)
test('actual fast hold also yields when only slow escape is safe',function()
  local cfg,state=config(),{}
  local first=tick(world(),state,cfg,{focus=false,target_x=100,target_y=320})
  check(not first.focus,'start in actual fast movement')
  local rows={{5,327,-3,1},{17,334,-1,3},{17,308,3,2},{-14,347,-1,0},{12,332,-2,1},{-9,294,-2,1},{-6,291,3,4}}
  local bullets={};for i,r in ipairs(rows) do bullets[i]=rect(i,r[1],r[2],r[3],r[4]) end
  local out=tick(world(bullets),state,cfg,{focus=false,focus_mismatch_cost=8})
  check(out.focus and not out.collides,'fast hold cannot forbid the available safe slow escape')
end)
test('alternating resource focus does not produce frame-by-frame Shift chatter',function()
  local cfg,state=config(),{};local disabled=config(false);local oldstate={}
  local changes,oldchanges,last,oldlast,last_at=0,0,nil,nil,0
  for i=1,100 do
    local intent={focus=i%2==1,focus_mismatch_cost=8}
    local out=tick(world(),state,cfg,intent);local old=tick(world(),oldstate,disabled,intent)
    if last~=nil and out.focus~=last then
      changes=changes+1
      check(i-last_at>=cfg.human_movement.speed_hold_frames,'safe speed switches respect minimum hold')
      last_at=i
    elseif last==nil then last_at=i end
    if oldlast~=nil and old.focus~=oldlast then oldchanges=oldchanges+1 end
    last,oldlast=out.focus,old.focus
    check(not out.collides,'speed holding never manufactures danger on empty field')
  end
  check(changes>0 and changes<oldchanges/2,'holding suppresses chatter without permanently latching Shift')
end)
test('freeze recovery and explicit reset discard prior density and speed intent',function()
  for _,kind in ipairs({'cutIn','timeScale','state4','state5','movementEnabled'}) do
    local cfg,state=config(),{};local side=dense();enter(side,state,cfg)
    if kind=='cutIn' then side.player.sensor.cutIn=true
    elseif kind=='timeScale' then side.player.sensor.timeScale=0
    elseif kind=='state4' then side.player.sensor.state=4
    elseif kind=='state5' then side.player.sensor.state=5
    else side.player.sensor.movementEnabled=false end
    local out=tick(side,state,cfg)
    check(not out.human_enabled and not out.human_slow,'inactive game state skips new preferences')
    check(state.human_movement==nil,'inactive game state clears prior human intent')
    side.player.sensor=sensor();out=tick(side,state,cfg)
    check(not out.human_slow,'resume must accumulate fresh density again')
    dodge.resetHuman(state);check(state.human_movement==nil,'explicit reset supports main fault and new-round paths')
  end
end)
test('human style cannot raise attention capacity or purchase new identities',function()
  local cfg,state=config(),{};local base=config(false);local oldstate={};local side=dense()
  for i=1,40 do
    local out=tick(side,state,cfg);local old=tick(side,oldstate,base)
    for k,v in pairs(old) do
      if type(k)=='string' and k:match('^attention_') then same(out[k],v,k) end
    end
    check(out.objects_seen==old.objects_seen and out.objects_relevant==old.objects_relevant,'identical perceived objects')
  end
end)
test('all-colliding candidate pool retains prior escape ranking',function()
  local cfg=config();local base=config(false)
  local side=world({rect(1,0,320,0,0,500,500)})
  local out=dodge.choose(side,{},cfg,{focus=true,target_x=100})
  local old=dodge.choose(side,{},base,{focus=true,target_x=100})
  check(out.collides and old.collides and out.key==old.key,'width preference never replaces forced escape ordering')
  near(out.danger,old.danger,'same collision risk when all routes fail')
end)
test('warning geometry has no fake hard-clearance lane penalty',function()
  local cfg=config();local side=world({{id=1,vx=0,vy=0,hitBody={type=2,x=-100,y=320,width=200,height=0,angle=0}}})
  local out=dodge.choose(side,{},cfg,{focus=false})
  check(out.warning_lasers==1 and out.human_lane_cost==0,'warning beams remain existing soft warnings only')
end)
test('wider clearance preference changes a real safe choice without buying collision risk',function()
  local cfg=config();local without=copy(cfg);without.human_movement.corridor_weight=0
  local rows={{-30,300,-2,-1},{2,357,-1,-0.5},{9,319,0,0.5},{1,277,1,2},{-54,291,-2,-1.5}}
  local bullets={};for i,r in ipairs(rows) do bullets[i]=circle(i,r[1],r[2],r[3],r[4]) end
  local side=world(bullets);local intent={focus=false,target_x=50,target_y=320}
  local old=dodge.choose(side,{},without,intent);local out=dodge.choose(side,{},cfg,intent)
  check(old.name=='stay' and out.name=='fast-left','lane preference chooses the open side despite resource target to the right')
  check(not old.collides and not out.collides and old.focus==out.focus,'same actual fast speed and no invented collision')
  near(out.danger,old.danger,'wide preference does not purchase extra near-miss danger')
  check(out.terrain_cost<=old.terrain_cost and out.human_lane_cost<old.human_lane_cost,'less clearance exposure without additional wall cost')
  -- Independent sampled physical trajectories, not a second call to the
  -- implementation's interval solver. This fixture is far from field walls.
  local function close_samples(candidate)
    local count=0
    for step=0,120 do
      local t=step/10;local x,y=side.player.x+candidate.vx*t,side.player.y+candidate.vy*t
      for _,b in ipairs(bullets) do
        local dx=x-b.hitBody.x-b.vx*t;local dy=y-b.hitBody.y-b.vy*t
        if dx*dx+dy*dy<16*16 then count=count+1 end
      end
    end
    return count
  end
  check(close_samples(out)<close_samples(old),'independent sampled path spends less time close to perceived bullets')
  check(out.attention_tracked==old.attention_tracked and out.objects_relevant==old.objects_relevant,'no extra visibility or admission needed for the wider choice')
end)
test('new preferences stay inside the actual direction-cap candidate pool',function()
  local cfg=config();cfg.move_change_budget=0;cfg.move_change_min_frames=5
  local side=world({rect(1,0,310,0,0,240,2),rect(2,0,330,0,0,240,2),rect(3,-20,320,2,0,4,40)})
  local state={last_move_dir=7}
  local out=tick(side,state,cfg)
  check(out.rescue_routes_total==2 and out.rescue_routes_safe==2,'true eligible pool contains only slow/fast right')
  check(out.vx>0 and out.vy==0 and not out.collides,'lane or speed preference cannot bypass direction cap')
end)
test('actual full short-horizon protection is respected by the extra lane preference',function()
  local cfg=config();local side=world({rect(1,0,320,0,0,20,20)})
  side.player.sensor.state=3;side.player.sensor.protectionFrames=30
  local out=dodge.choose(side,{},cfg,{focus=false})
  check(not out.collides,'fixture has genuine native protection for entire short horizon')
  check(out.human_lane_cost==0,'new lane does not price contacts within verified protection as unprotected danger')
end)
test('a free enemy inside the wider envelope is not culled by the original narrow broad phase',function()
  local cfg=config();cfg.move_change_budget=0;cfg.move_change_min_frames=5
  local p=player();p.speedSlow=p.speedFast
  -- The left free enemy makes staying dangerous, so the real direction cap
  -- restricts both candidate speeds to right. At horizon x=48, x=60 is outside
  -- the old 4-unit near-miss padding but inside the 12-unit lane padding.
  local enemies={circle(600,60,320),circle(601,-20,320,2,0)}
  local side=world({},p,{},enemies)
  local out=tick(side,{last_move_dir=7},cfg)
  check(out.rescue_routes_total==2 and out.vx==4 and out.vy==0,'actual cap keeps the rightward route')
  check(not out.collides and out.danger==0,'wide edge does not become physical or original near-miss danger')
  check(out.human_lane_cost>0,'already-visible free enemy contributes its expanded clearance exposure')
  check(out.human_pressure==0,'enemies still never inflate bullet density')
  local blind=world({circle(600,60,320)},player(),{}, {circle(601,-20,320,2,0)})
  blind.player.speedSlow=blind.player.speedFast
  local hidden=tick(blind,{last_move_dir=7},cfg)
  check(hidden.attention_tracked==0 and hidden.human_lane_cost==0,'wider scoring envelope cannot admit an otherwise untracked ordinary bullet')
end)
test('static and tracked laser edges enter the wider envelope without becoming hits',function()
  local cfg=config();cfg.move_change_budget=0;cfg.move_change_min_frames=5
  local p=player();p.speedSlow=p.speedFast
  local beam={id=700,vx=0,vy=0,hitBody={type=2,x=60,y=300,width=40,height=4,angle=math.pi/2}}
  local side=world({beam},p,{}, {circle(701,-20,320,2,0)})
  local state={last_move_dir=7}
  local static=tick(side,state,cfg)
  check(static.dynamic_lasers==0 and static.human_lane_cost>0,'first-frame free laser contributes broad envelope')
  check(not static.collides and static.danger==0 and static.vx==4,'static wider margin does not change hard geometry')
  local tracked=tick(side,state,cfg)
  check(tracked.tracked_lasers==1 and tracked.dynamic_lasers==0 and tracked.human_lane_cost>0,
    'stationary tracked laser retains the existing static fast path and expanded cull')
  beam.hitBody.y=300.1 -- measurable tangent translation, still the same x=60 edge
  local moving=tick(side,state,cfg)
  check(moving.dynamic_lasers==1 and moving.human_lane_cost>0,'actual dynamic sweep also survives expanded cull')
  check(not moving.collides and moving.danger==0 and moving.vx==4,'dynamic-laser path remains genuinely safe')
  check(static.human_pressure==1 and tracked.human_pressure==1 and moving.human_pressure==1,
    'one real beam counted once; free enemy not counted')
end)
test('forty-five-degree local padding survives the projected broad phase',function()
  local cfg=config();cfg.move_change_budget=0;cfg.move_change_min_frames=5
  local p=player();p.speedSlow=p.speedFast
  local shape={id=800,vx=0,vy=0,hitBody={type=2,x=69,y=318.6,width=40,height=4,angle=math.pi/4}}
  -- Its padded local lower-left corner barely intersects the rightward
  -- endpoint. Expanding the world cull by only eight (12-4) would miss it;
  -- projecting both local axes needs up to eight*sqrt(2).
  local c=math.sqrt(0.5)
  local old_left=shape.hitBody.x-(2+4+4+4)*c
  check(old_left-48>8 and old_left-48<8*math.sqrt(2),'fixture crosses the rotated extra-padding edge')
  local enemy_side=world({},p,{}, {shape,circle(801,-20,320,2,0)})
  local enemy=tick(enemy_side,{last_move_dir=7},cfg)
  check(enemy.vx==4 and not enemy.collides and enemy.danger==0,'rotated free enemy remains physically outside route')
  check(enemy.human_lane_cost>0 and enemy.human_pressure==0,'projected enemy envelope contributes soft clearance only')
  local beam=copy(shape);beam.id=802
  local laser_side=world({beam},player(),{}, {circle(803,-20,320,2,0)})
  laser_side.player.speedSlow=laser_side.player.speedFast
  local state={last_move_dir=7};local static=tick(laser_side,state,cfg)
  check(static.human_lane_cost>0 and not static.collides,'rotated static free laser survives projected cull')
  beam.hitBody.x=68.98;beam.hitBody.y=318.58
  local moving=tick(laser_side,state,cfg)
  check(moving.dynamic_lasers==1 and moving.human_lane_cost>0,'slightly translating rotated laser uses expanded dynamic cull')
  check(not moving.collides and moving.danger==0 and moving.vx==4,'dynamic padding cannot become a physical hit')
end)

local baseline_path=os and os.getenv and os.getenv('TH09_HUMAN_DODGE_BASELINE')
local baseline=baseline_path and baseline_path~='' and dofile(baseline_path) or dodge
test('mech preserves every pre-human movement output and planner state',function()
  for scenario=1,4 do
    local cfg=config();cfg.attention.enabled=false;cfg.attention.difficulty='mech'
    cfg.move_change_budget=6;cfg.move_change_min_frames=5
    local base=copy(cfg);base.human_movement.enabled=false
    local state,oldstate={},{};local p=player()
    for frame=1,100 do
      state.frame,oldstate.frame=frame,frame
      local bullets,ex={},{}
      for i=1,32 do
        bullets[i]=circle(i+math.floor((frame+i)/23)*100,
          ((i*29+frame*(i%5-2))%330)-165,((i*31+frame*(1+i%5))%448),i%7-3,0.75+i%8)
      end
      bullets[#bullets+1]={id=900,vx=0,vy=0,hitBody={type=2,x=-100,y=275,width=180+frame%31,height=frame%20<4 and 0 or 4,angle=frame*0.003}}
      if scenario==2 then
        p.sensor.moveScaleX,p.sensor.moveScaleY=0.4,0.4
        p.sensor.poisonClouds={{x=0,y=315,radius=64,framesLeft=120,age=50,active=true}}
        ex[1]=circle(999,0,315,0,0,64);ex[1].type=16;ex[1].hittable=true
      elseif scenario==3 then
        p.sensor.state=frame%30<12 and 3 or 0;p.sensor.protectionFrames=p.sensor.state==3 and 18-frame%12 or 0
      end
      local side=world(bullets,p,ex)
      local intent={focus=frame%40<12,min_y=150,target_x=(scenario%3-1)*48,target_y=280+scenario*8,
        protected_followup=scenario==3 and p.sensor.state==3}
      local out=dodge.choose(side,state,cfg,intent);local old=baseline.choose(side,oldstate,base,intent)
      check(not out.human_enabled,'mech hard bypass')
      same(out,old,'mech output');same(state,oldstate,'mech planner')
      p.x=math.max(-130,math.min(130,p.x+old.vx));p.y=math.max(160,math.min(425,p.y+old.vy))
      p.hitBodyRect.x,p.hitBodyCircle.x=p.x,p.x;p.hitBodyRect.y,p.hitBodyCircle.y=p.y,p.y
    end
  end
end)
test('explicit mech bypass remains hard when a caller supplies another difficulty string',function()
  local cfg,state=config(),{};cfg.human_movement.mech=true
  for i=1,10 do local out=tick(dense(),state,cfg);check(not out.human_enabled and state.human_movement==nil,'explicit mech identity cannot enable human state') end
end)
test('a non-mech attention override does not silently erase human movement style',function()
  local cfg,state=config(),{};cfg.attention.enabled=false;cfg.attention.difficulty='custom'
  local out=enter(dense(12),state,cfg)
  check(out.human_enabled and out.human_slow,'mech identity is separate from attention being disabled')
end)

if #failures>0 then error(table.concat(failures,'\n')) end
if not baseline_path or baseline_path=='' then print('Historical mech comparison not requested; current disabled-feature baseline used.') end
print(string.format('human_movement_test: PASS (%d scenarios / %d checks; real admitted geometry, no game)',cases,checks))
