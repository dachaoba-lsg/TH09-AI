-- 3.9 module-only terrain tests. No dodge integration, game process or input.
-- Candidate segments are explicit physical trajectories, not invented speed.
local nav=dofile('poison_navigation.lua')
local abs,sqrt=math.abs,math.sqrt
local checks,cases,failures=0,0,{}
local function check(v,m) checks=checks+1;assert(v,m) end
local function near(a,b,m) check(type(a)=='number' and abs(a-b)<1e-7,m..': '..tostring(a)..' != '..tostring(b)) end
local function copy(v)
  if type(v)~='table' then return v end
  local out={};for k,x in pairs(v) do out[k]=copy(x) end;return out
end
local function same(a,b,path)
  check(type(a)==type(b),path..' type')
  if type(b)~='table' then check(a==b,path..' value');return end
  for k,v in pairs(b) do same(a[k],v,path..'.'..tostring(k)) end
  for k in pairs(a) do check(b[k]~=nil,path..' unexpected '..tostring(k)) end
end
local function test(name,fn)
  cases=cases+1;local ok,err=pcall(fn)
  if ok then print('PASS '..name) else failures[#failures+1]=name..': '..tostring(err);print('FAIL '..failures[#failures]) end
end
local function cloud(x,y,radius,age)
  age=age or 50
  return {x=x or 0,y=y or 320,radius=radius or 64,age=age,ageInt=math.floor(age),
    framesLeft=300-age,active=math.floor(age)>20 and math.floor(age)<300}
end
local function fixture(clouds)
  return {player={x=0,y=320,speedFast=4,speedSlow=2,currentCharge=150,currentChargeMax=300,
    sensor={valid=true,apiVersion=1,state=0,cutIn=false,timeScale=1,movementEnabled=true,
      baseScaleX=1,baseScaleY=1,moveScaleX=0.4,moveScaleY=0.4,poisonClouds=clouds or {}}},
    cfg={prediction_frames=12,vision_radius=448/3,field={min_x=-136,max_x=136,min_y=16,max_y=432},
      poison_navigation={enabled=true,risk_weight=80,progress_weight=6,replan_frames=12}},state={},stats={},frame=1,intent={min_y=150}}
end
local function candidate(p,vx,vy)
  return {vx=vx,vy=vy,collides=false,danger=0,terrain_cost=0,position_cost=3,
    segments={{start=0,duration=12,x=p.x,y=p.y,vx=vx,vy=vy}},
    terminal_x=p.x+vx*12,terminal_y=p.y+vy*12}
end
local function routes(f,speed)
  speed=speed or 1.6
  return {candidate(f.player,0,0),candidate(f.player,speed,0),candidate(f.player,-speed,0),
    candidate(f.player,0,speed),candidate(f.player,0,-speed)}
end
local function run(f,candidates)
  candidates=candidates or routes(f)
  nav.score(f.player,candidates,f.state,f.cfg,f.stats,f.frame,f.intent)
  check(f.stats.poison_probe_count>=0 and f.stats.poison_probe_count<=128,'bounded new terrain probe count')
  check(f.stats.poison_nav_samples<=2+#candidates*2+8+128,'sample budget includes at most eight cached-route samples')
  for _,c in ipairs(candidates) do check(type(c.poison_cost)=='number' and c.poison_cost==c.poison_cost and abs(c.poison_cost)<math.huge,'finite per-candidate soft cost') end
  local memory=f.state.poison_navigation
  if memory and memory.target_x then
    local dx,dy=memory.target_x-f.player.x,memory.target_y-f.player.y
    local radius=f.cfg.vision_radius
    if radius==nil or radius==0 then radius=128
    elseif type(radius)~='number' or radius<0 or radius~=radius then radius=448/3 end
    radius=math.min(128,math.max(16,radius))
    check(dx*dx+dy*dy<=radius*radius+1e-7,'target stays inside current circular view and 128 maximum')
    check(memory.target_x>=f.cfg.field.min_x+8 and memory.target_x<=f.cfg.field.max_x-8,'target respects real side walls')
    check(memory.target_y>=math.max(f.cfg.field.min_y+8,(f.intent or {}).min_y or -math.huge)
      and memory.target_y<=f.cfg.field.max_y-8,'target respects policy height and real top/bottom walls')
  end
  return candidates
end
local function inactive(f)
  local candidates=run(f)
  check(f.state.poison_navigation==nil,'inactive reason clears navigation cache')
  for _,c in ipairs(candidates) do check(c.poison_cost==0,'inactive reason leaves zero preference') end
  for _,name in ipairs({'poison_nav_active','poison_level','poison_risk','poison_target_x','poison_target_y','poison_probe_count','poison_nav_samples'}) do
    check(f.stats[name]==0,'inactive diagnostics reset: '..name)
  end
end

test('no clouds disabled and invalid snapshots clear stale costs and targets',function()
  for _,reason in ipairs({'empty','disabled','invalid','missing_clouds'}) do
    local f=fixture({cloud()});run(f);check(f.state.poison_navigation~=nil,'fixture planned terrain')
    if reason=='empty' then f.player.sensor.poisonClouds={}
    elseif reason=='disabled' then f.cfg.poison_navigation.enabled=false
    elseif reason=='invalid' then f.player.sensor.valid=false
    else f.player.sensor.poisonClouds=nil end
    inactive(f)
  end
end)
test('freeze recovery and movement-disabled states never retain a terrain command',function()
  for _,reason in ipairs({'cutIn','zero_time','negative_time','movement_off','state1','state2','state4','state5'}) do
    local f=fixture({cloud()});run(f)
    if reason=='cutIn' then f.player.sensor.cutIn=true
    elseif reason=='zero_time' then f.player.sensor.timeScale=0
    elseif reason=='negative_time' then f.player.sensor.timeScale=-1
    elseif reason=='movement_off' then f.player.sensor.movementEnabled=false
    else f.player.sensor.state=tonumber(reason:sub(6)) end
    inactive(f)
  end
end)
test('one and stacked clouds produce dose-aware finite preferences',function()
  local one=fixture({cloud()});run(one)
  local three=fixture({cloud(),cloud(),cloud()});run(three)
  check(one.stats.poison_level==1 and three.stats.poison_level==3,'native clouds are counted as terrain layers')
  check(three.stats.poison_risk>one.stats.poison_risk*3,'stacked dose has stronger than linear soft penalty')
  check(one.state.poison_navigation.target_x~=nil and three.state.poison_navigation.target_x~=nil,'bounded exits exist from concentric terrain')
end)
test('progress guides even tiny real movement out of a flat deep cloud centre',function()
  local f=fixture({cloud(),cloud(),cloud()});run(f)
  local m=f.state.poison_navigation;local dx,dy=m.target_x-f.player.x,m.target_y-f.player.y
  local length=sqrt(dx*dx+dy*dy);local speed=4*0.4^3
  f.frame=2
  local candidates=run(f,{candidate(f.player,0,0),candidate(f.player,dx/length*speed,dy/length*speed),candidate(f.player,-dx/length*speed,-dy/length*speed)})
  check(candidates[2].poison_cost<candidates[1].poison_cost and candidates[2].poison_cost<candidates[3].poison_cost,'reward follows a lower-dose target using actual tiny velocity')
  near(candidates[2].vx^2+candidates[2].vy^2,speed^2,'poison multiplier is not increased to force escape')
end)
test('piecewise poison and wall speeds are authoritative instead of nominal velocity',function()
  local f=fixture({cloud(40,320)});f.cfg.poison_navigation.progress_weight=0
  local a=candidate(f.player,4,0)
  a.segments={{start=0,duration=6,x=0,y=320,vx=0.4,vy=0},{start=6,duration=6,x=2.4,y=320,vx=4,vy=0}}
  local b=copy(a);b.vx=99;b.terminal_x=9999
  local slow=candidate(f.player,0.4,0)
  local out=run(f,{a,b,slow})
  near(out[1].poison_cost,out[2].poison_cost,'sampling ignores misleading nominal velocity and endpoint')
  check(abs(out[1].poison_cost-out[3].poison_cost)>1,'true speed change differs from a frozen speed approximation')
  f.player.x=132
  local wall=candidate(f.player,4,0);wall.segments={{start=0,duration=1,x=132,y=320,vx=4,vy=0},{start=1,duration=11,x=136,y=320,vx=0,vy=0}}
  local wall_copy=copy(wall);wall_copy.vx=100;wall_copy.terminal_x=1000
  out=run(f,{wall,wall_copy});near(out[1].poison_cost,out[2].poison_cost,'physical wall-clamped segments remain authoritative')
end)
test('navigation changes no collision physics resources protection or original candidate fields',function()
  local f=fixture({cloud()});local before=copy(f.player);local candidates=routes(f);local originals=copy(candidates)
  candidates[2].collides=true;originals[2].collides=true
  run(f,candidates);same(f.player,before,'player')
  for i,c in ipairs(candidates) do local out=copy(c);out.poison_cost=nil;same(out,originals[i],'candidate '..i) end
end)
test('every public circular radius bounds targets even at the smallest view',function()
  for _,radius in ipairs({16,20,32,64,96,149.333333333,640}) do
    local f=fixture({cloud(60,320)});f.cfg.vision_radius=radius;run(f)
    check(f.state.poison_navigation and f.state.poison_navigation.target_x~=nil,'visible edge permits a local lower-risk target')
  end
end)
test('a fully outside raw cloud cannot leak into the module through a caller mistake',function()
  local f=fixture({cloud(85,320)});f.cfg.vision_radius=16
  -- Cloud's nearest physical edge is x=21, outside the current circle. A raw
  -- projected x=48 route would enter it, which must not make hidden terrain known.
  inactive(f)
end)
test('moving the player invalidates an out-of-circle cached target immediately',function()
  local f=fixture({cloud()});f.cfg.vision_radius=96;run(f)
  local old=copy(f.state.poison_navigation);check(old.target_x~=nil,'initial remembered exit')
  local dx,dy=old.target_x-f.player.x,old.target_y-f.player.y;local length=sqrt(dx*dx+dy*dy)
  f.player.x=f.player.x-dx/length*40;f.player.y=f.player.y-dy/length*40
  f.frame=2;run(f)
  local now=f.state.poison_navigation
  check(not now or now.target_x~=old.target_x or now.target_y~=old.target_y,'outside target removed before twelve-callback cadence')
end)
test('policy-height changes invalidate the current goal before normal replanning',function()
  local f=fixture({cloud()});run(f);local old=copy(f.state.poison_navigation)
  f.intent.min_y=old.target_y+16;f.frame=2;run(f)
  local now=f.state.poison_navigation
  check(not now or not now.target_y or now.target_y>=f.intent.min_y,'no cached goal above the newly required height')
end)
test('physical corners never create clamped fake zero-length escape goals',function()
  for _,point in ipairs({{-132,28},{132,28},{-132,428},{132,428}}) do
    local f=fixture({cloud(point[1],point[2])});f.player.x,f.player.y=point[1],point[2]
    f.intent.min_y=16;run(f)
    local m=f.state.poison_navigation
    if m and m.target_x then check((m.target_x-f.player.x)^2+(m.target_y-f.player.y)^2>=16,'a real nonzero terrain goal') end
  end
end)
test('player above policy height can plan a legal descent rather than a forbidden upper target',function()
  local f=fixture({cloud(0,130)});f.player.y=130;f.intent.min_y=150
  run(f);local m=f.state.poison_navigation
  check(m and m.target_y and m.target_y>=150,'bounded rays can enter the legal lower region')
end)
test('new poison on a cached target forces immediate reconsideration',function()
  local f=fixture({cloud()});run(f);local old=copy(f.state.poison_navigation)
  for i=1,3 do f.player.sensor.poisonClouds[#f.player.sensor.poisonClouds+1]=cloud(old.target_x,old.target_y,32) end
  f.frame=2;run(f);local m=f.state.poison_navigation
  check(f.stats.poison_probe_count>0,'new geometry is checked before the normal planning cadence')
  check(not m or m.target_x~=old.target_x or m.target_y~=old.target_y,'new high-dose destination is not protected by hysteresis')
end)
test('new dense poison between player and goal can change a still-clean destination',function()
  local f=fixture({cloud()});run(f);local old=copy(f.state.poison_navigation)
  local x,y=(old.target_x+f.player.x)/2,(old.target_y+f.player.y)/2
  for i=1,5 do f.player.sensor.poisonClouds[#f.player.sensor.poisonClouds+1]=cloud(x,y,24) end
  f.frame=2;run(f);local m=f.state.poison_navigation
  check(f.stats.poison_probe_count>0,'new route terrain triggers replanning')
  check(not m or m.target_x~=old.target_x or m.target_y~=old.target_y,'ray peak discourages crossing newly stacked poison')
end)
test('quiet caches revalidate every callback but replan only on the callback cadence',function()
  local f=fixture({cloud()});run(f);local old=copy(f.state.poison_navigation)
  for frame=2,12 do
    f.frame=frame;run(f)
    check(f.stats.poison_probe_count==0,'quiet cache avoids needless full probing')
    check(f.stats.poison_nav_samples>2+#routes(f)*2,'cached target path was actually revalidated')
    near(f.state.poison_navigation.target_x,old.target_x,'quiet target x stays stable')
    near(f.state.poison_navigation.target_y,old.target_y,'quiet target y stays stable')
  end
  f.frame=13;run(f);check(f.stats.poison_probe_count>0,'twelve elapsed callbacks cause bounded replanning')
  f.frame=1;run(f);check(f.stats.poison_probe_count>0,'rewound callback counter invalidates old plan age')
end)
test('replanning remains callback-based at slow game time without inventing arrival time',function()
  local f=fixture({cloud()});f.player.sensor.timeScale=0.5;run(f)
  f.frame=12;run(f);check(f.stats.poison_probe_count==0,'eleven callbacks retain target')
  f.frame=13;run(f);check(f.stats.poison_probe_count>0,'cadence counts callbacks explicitly')
end)
test('cloud array reordering preserves equivalent terrain and a stable legal goal',function()
  local f=fixture({cloud(),cloud(20,330,48)});local before=copy(run(f))
  local goal=copy(f.state.poison_navigation)
  local clouds=f.player.sensor.poisonClouds;clouds[1],clouds[2]=clouds[2],clouds[1]
  f.frame=2;local after=run(f)
  check(f.stats.poison_probe_count>0,'changed snapshot order receives bounded re-evaluation')
  near(f.state.poison_navigation.target_x,goal.target_x,'equivalent terrain retains goal x')
  near(f.state.poison_navigation.target_y,goal.target_y,'equivalent terrain retains goal y')
  for i=1,#after do near(after[i].poison_cost,before[i].poison_cost,'cloud order does not change candidate cost') end
end)
test('a goal approached within four units cannot remain a stale travel command',function()
  local f=fixture({cloud(60,320)});run(f)
  local goal=copy(f.state.poison_navigation);check(goal and goal.target_x~=nil,'edge fixture has a nearby exit')
  local dx,dy=goal.target_x-f.player.x,goal.target_y-f.player.y;local distance=sqrt(dx*dx+dy*dy)
  check(distance<64,'approach will not trip the ordinary displacement replan threshold')
  f.player.x,f.player.y=goal.target_x-dx/distance*2,goal.target_y-dy/distance*2
  f.frame=2;run(f);local now=f.state.poison_navigation
  check(not now or now.target_x~=goal.target_x or now.target_y~=goal.target_y,'close goal is cleared or replaced before cadence')
end)
test('an impossible local exit is cached without claiming a safe route',function()
  local f=fixture({cloud(0,320,500)});run(f)
  check(f.state.poison_navigation and not f.state.poison_navigation.target_x,'no fictitious low-dose endpoint in an enormous uniform cloud')
  f.frame=2;run(f);check(f.stats.poison_probe_count==0,'unchanged impossible goal does not probe every callback')
end)
test('expiry or no relevant cloud clears a stale target and never grants immunity',function()
  local f=fixture({cloud()});run(f)
  f.player.sensor.poisonClouds[1].age=300;f.player.sensor.poisonClouds[1].framesLeft=0
  f.frame=2;inactive(f)
  f=fixture({cloud(0,320,64,295)});run(f)
  check(f.state.poison_navigation==nil,'soon-expiring terrain does not justify a long remembered trip')
end)
test('actual protection does not remove poison terrain or increase movement speed',function()
  local normal=fixture({cloud()});local a=run(normal)
  local protected=fixture({cloud()});protected.player.sensor.state=3;protected.player.sensor.protectionFrames=60
  local b=run(protected)
  for i=1,#a do near(a[i].poison_cost,b[i].poison_cost,'real invulnerability does not erase poison') end
  near(protected.player.sensor.moveScaleX,0.4,'original poisoned speed is untouched')
end)
test('all difficulty names including mech receive exactly the same terrain preference',function()
  local reference,stats
  for _,difficulty in ipairs({'human45','human200','human240','human300','human480','unlimited','custom','mech'}) do
    local f=fixture({cloud(),cloud()});f.cfg.attention={difficulty=difficulty,enabled=difficulty~='mech'}
    f.cfg.human_movement={mech=difficulty=='mech'}
    local out=run(f)
    if reference then
      for i=1,#out do near(out[i].poison_cost,reference[i].poison_cost,'shared terrain cost '..difficulty) end
      same(f.stats,stats,'shared terrain diagnostics '..difficulty)
    else reference,stats=copy(out),copy(f.stats) end
  end
end)
test('pathological cloud entries cannot poison numeric calculations',function()
  local f=fixture({{x=0/0,y=320,radius=64,framesLeft=100},{x=0,y=320,radius=-1,framesLeft=100},
    {x=0,y=320,radius=64,framesLeft=0},{x=0,y=320,radius=64,framesLeft=100,active=false}})
  inactive(f)
end)
test('dense cloud snapshots remain bounded in probes and risk sample calls',function()
  local clouds={};for i=1,256 do clouds[i]=cloud((i%7-3)*5,320+(i%5-2)*5) end
  local f=fixture(clouds);local candidates={}
  for i=1,18 do local angle=i*math.pi/9;candidates[i]=candidate(f.player,math.cos(angle)*0.01,math.sin(angle)*0.01) end
  run(f,candidates);check(f.stats.poison_level==256,'all visible layers are retained without truncation')
  f.frame=2;run(f,candidates);check(f.stats.poison_probe_count==0,'dense unchanged terrain also uses cache')
end)
test('explicit reset removes navigation only and can restart cleanly',function()
  local f=fixture({cloud()});f.state.other_policy={counter=19};run(f)
  nav.reset(f.state)
  check(f.state.poison_navigation==nil and f.state.other_policy.counter==19,'reset does not touch unrelated policy')
  f.frame=2;run(f);check(f.stats.poison_probe_count>0,'next valid frame builds a fresh terrain goal')
end)

if #failures>0 then error(table.concat(failures,'\n')) end
print(string.format('poison_navigation_test: PASS (%d scenarios / %d checks; module only, no game)',cases,checks))
