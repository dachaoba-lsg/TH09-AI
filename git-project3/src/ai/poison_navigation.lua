-- Bounded poison-terrain guidance, shared by every difficulty. This module
-- neither sees raw game objects nor decides which bullet/laser route is safe.
-- Caller supplies the current perceived player and existing physical segments.
local abs, min, max, sqrt = math.abs, math.min, math.max, math.sqrt
local RADIUS, STEP, LOOKAHEAD, BUFFER = 128, 16, 48, 12
local RAYS = {}
for index=0,15 do
  local angle=index*math.pi/8
  RAYS[#RAYS+1]={math.cos(angle),math.sin(angle)}
end
local function finite(v) return type(v)=='number' and v==v and abs(v)<math.huge end
local function clamp(v,lo,hi) return max(lo,min(hi,v)) end
local function setting(cfg,key,default,lo,hi)
  return finite(cfg[key]) and clamp(cfg[key],lo,hi) or default
end
local function reset(state) state.poison_navigation=nil end

local function viewRadius(cfg)
  -- Match perceive(): zero/missing is an explicit internal unbounded view;
  -- public settings use 16..640. Terrain probing itself never exceeds 128.
  if cfg.vision_radius==nil or cfg.vision_radius==0 then return math.huge end
  return finite(cfg.vision_radius) and cfg.vision_radius>0
    and clamp(cfg.vision_radius,16,640) or 448/3
end
local function bounds(cfg,intent)
  local field=cfg.field
  if type(field)~='table' or not finite(field.min_x) or not finite(field.max_x)
      or not finite(field.min_y) or not finite(field.max_y) then return nil end
  local out={min_x=field.min_x+8,max_x=field.max_x-8,min_y=field.min_y+8,max_y=field.max_y-8}
  if type(intent)=='table' and finite(intent.min_y) then out.min_y=max(out.min_y,intent.min_y) end
  if out.min_x>out.max_x or out.min_y>out.max_y then return nil end
  return out
end
local function legalTarget(player,x,y,limit,area)
  return finite(x) and finite(y) and x>=area.min_x and x<=area.max_x
    and y>=area.min_y and y<=area.max_y
    and (x-player.x)^2+(y-player.y)^2<=limit*limit+1e-7
end
local function cloudsNear(player,radius)
  local clouds={}
  for _,raw in ipairs(player.sensor.poisonClouds or {}) do
    if finite(raw.x) and finite(raw.y) and finite(raw.radius) and raw.radius>0
        and finite(raw.framesLeft) and raw.framesLeft>0 then
      local active=finite(raw.age) and max(0,21-raw.age) or (raw.active==false and math.huge or 0)
      local dx,dy=raw.x-player.x,raw.y-player.y
      -- The caller already applies the shared circular view. Repeat its cloud
      -- intersection guard so an accidentally raw snapshot cannot add terrain.
      if active<LOOKAHEAD and active<raw.framesLeft
          and dx*dx+dy*dy<=(radius+raw.radius)^2
          and abs(dx)<=RADIUS+raw.radius+BUFFER and abs(dy)<=RADIUS+raw.radius+BUFFER then
        clouds[#clouds+1]={x=raw.x,y=raw.y,radius=raw.radius,active=active,expires=raw.framesLeft}
      end
    end
  end
  return clouds
end
local function weight(cloud,time)
  local remaining=cloud.expires-time
  if remaining<=0 then return 0 end
  local delay=max(0,cloud.active-time)
  return min(1,remaining/60)*(delay==0 and 1 or max(0,1-delay/LOOKAHEAD)*0.5)
end
local function riskAt(x,y,time,clouds,stats)
  stats.poison_nav_samples=stats.poison_nav_samples+1
  local dose,edge,level,now_dose,now_edge=0,0,0,0,0
  for _,cloud in ipairs(clouds) do
    local dx,dy=x-cloud.x,y-cloud.y
    local distance2=dx*dx+dy*dy
    if distance2<(cloud.radius+BUFFER)^2 then
      local distance=sqrt(distance2)
      local forecast,current=weight(cloud,time),weight(cloud,0)
      if distance<cloud.radius then
        dose,now_dose=dose+forecast,now_dose+current
        if cloud.active<=time and cloud.expires>time then level=level+1 end
        local depth=0.25+0.25*(1-distance/cloud.radius)
        edge,now_edge=edge+forecast*depth,now_edge+current*depth
      else
        local fringe=0.25*(1-(distance-cloud.radius)/BUFFER)
        edge,now_edge=edge+forecast*fringe,now_edge+current*fringe
      end
    end
  end
  -- The third result checks today's target too. A newly dense target must not
  -- survive merely because an approximate travel time predicts later expiry.
  return dose*dose+edge,level,now_dose*now_dose+now_edge
end
local function pointOn(candidate,time,player)
  local segments=candidate.segments or {}
  for _,segment in ipairs(segments) do
    if time<=segment.start+segment.duration then
      local dt=max(0,time-segment.start)
      return segment.x+segment.vx*dt,segment.y+segment.vy*dt
    end
  end
  local last=segments[#segments]
  if last then return last.x+last.vx*last.duration,last.y+last.vy*last.duration end
  return candidate.terminal_x or player.x,candidate.terminal_y or player.y
end
local function baseSpeed(player)
  local sensor=player.sensor
  local sx=finite(sensor.baseScaleX) and max(0,sensor.baseScaleX) or 1
  local sy=finite(sensor.baseScaleY) and max(0,sensor.baseScaleY) or 1
  local fast=finite(player.speedFast) and player.speedFast or 0
  local slow=finite(player.speedSlow) and player.speedSlow or 0
  return max(0.5,max(fast,slow)*min(sx,sy))
end
local function terrainScore(x,y,distance,total,steps,peak,initial,target,area)
  local clearance=min(x-area.min_x,area.max_x-x,y-area.min_y,area.max_y-y)
  return 8*target+2*total/steps+8*max(0,peak-initial)
    +distance/RADIUS*0.4+max(0,8-clearance)*0.25
end
local function routeScore(player,x,y,clouds,area,stats,initial)
  local dx,dy=x-player.x,y-player.y
  local distance=sqrt(dx*dx+dy*dy)
  if distance<4 then return nil end
  local steps=min(8,max(1,math.ceil(distance/STEP)))
  local total,peak,target=0,initial,initial
  local speed=baseSpeed(player)
  for index=1,steps do
    local fraction=index/steps
    -- This bounded terrain look-ahead does NOT estimate poisoned arrival time
    -- precisely and does not inspect any bullet along the ray.
    local risk,_,current=riskAt(player.x+dx*fraction,player.y+dy*fraction,
      min(LOOKAHEAD,distance*fraction/speed),clouds,stats)
    total,peak,target=total+risk,max(peak,risk),max(risk,current)
  end
  return terrainScore(x,y,distance,total,steps,peak,initial,target,area),target
end
local function cloudsChanged(memory,clouds)
  local previous=memory and memory.clouds
  if not previous or #previous~=#clouds then return true end
  for index,cloud in ipairs(clouds) do
    local old=previous[index]
    if old.x~=cloud.x or old.y~=cloud.y or old.radius~=cloud.radius
        or old.active~=(cloud.active<=0) then return true end
  end
  return false
end
local function rememberClouds(clouds)
  local snapshot={}
  for index,cloud in ipairs(clouds) do
    snapshot[index]={x=cloud.x,y=cloud.y,radius=cloud.radius,active=cloud.active<=0}
  end
  return snapshot
end
local function chooseTarget(player,old,clouds,area,stats,initial,frame,limit,old_score)
  local best,best_score
  -- Old score was recomputed from today's visible clouds, never carried over
  -- from the previous planning frame. Hysteresis cannot keep a toxic target.
  if old and old.target_x and old_score then
    best={target_x=old.target_x,target_y=old.target_y};best_score=old_score-0.75
  end
  local speed=baseSpeed(player)
  for _,ray in ipairs(RAYS) do
    local total,peak=0,initial
    for step=1,8 do
      local distance=step*STEP
      if distance>limit+1e-7 then break end
      local x,y=player.x+ray[1]*distance,player.y+ray[2]*distance
      if x<area.min_x or x>area.max_x or y>area.max_y then break end
      -- A player above the policy height may descend into the legal region;
      -- skip upper ray endpoints rather than treating the policy as a wall.
      if y<area.min_y and ray[2]<=0 then break end
      stats.poison_probe_count=stats.poison_probe_count+1
      local risk,_,current=riskAt(x,y,min(LOOKAHEAD,distance/speed),clouds,stats)
      total,peak=total+risk,max(peak,risk)
      local target=max(risk,current)
      local score=terrainScore(x,y,distance,total,step,peak,initial,target,area)
      if legalTarget(player,x,y,limit,area) and target<initial*0.85
          and (not best_score or score<best_score) then
        best,best_score={target_x=x,target_y=y},score
      end
    end
  end
  best=best or {}
  best.plan_frame,best.plan_x,best.plan_y=frame,player.x,player.y
  best.radius,best.min_y=limit,area.min_y
  best.clouds=rememberClouds(clouds)
  return best
end

local function score(player,candidates,state,cfg,stats,frame,intent)
  stats.poison_nav_active,stats.poison_level,stats.poison_risk=0,0,0
  stats.poison_target_x,stats.poison_target_y=0,0
  stats.poison_probe_count,stats.poison_nav_samples=0,0
  for _,candidate in ipairs(candidates) do candidate.poison_cost=0 end
  local options,sensor=cfg.poison_navigation,player.sensor
  if type(options)~='table' or options.enabled~=true or type(sensor)~='table' or sensor.valid~=true
      or type(sensor.poisonClouds)~='table' or not finite(player.x) or not finite(player.y)
      or sensor.cutIn==true or sensor.movementEnabled==false
      or (finite(sensor.timeScale) and sensor.timeScale<=0)
      or (sensor.state~=nil and sensor.state~=0 and sensor.state~=3) then reset(state);return end
  local radius=viewRadius(cfg)
  local limit=min(RADIUS,radius)
  local area=bounds(cfg,intent)
  if not area then reset(state);return end
  local clouds=cloudsNear(player,radius)
  if #clouds==0 then reset(state);return end
  local risk_weight=setting(options,'risk_weight',80,0,1000)
  local progress_weight=setting(options,'progress_weight',6,0,100)
  local replan=math.floor(setting(options,'replan_frames',12,1,60))
  local horizon=finite(cfg.prediction_frames) and max(0,cfg.prediction_frames) or 12
  frame=finite(frame) and frame or 0
  local initial,level=riskAt(player.x,player.y,0,clouds,stats)
  local future=riskAt(player.x,player.y,horizon,clouds,stats)
  stats.poison_level,stats.poison_risk=level,initial
  local need=max(initial,future)
  local memory=state.poison_navigation
  local old_score,invalid
  if memory and memory.target_x then
    if legalTarget(player,memory.target_x,memory.target_y,limit,area) then
      local risk
      old_score,risk=routeScore(player,memory.target_x,memory.target_y,clouds,area,stats,need)
      if not old_score or risk>=need*0.85 then invalid=true;old_score=nil end
    else invalid=true end
  end
  -- Planning cadence is AI callback count, independent of wall-clock time.
  -- Every callback still verifies the cached target and today's cloud set.
  if future<0.05 then memory=nil
  elseif not memory or invalid or cloudsChanged(memory,clouds) or memory.radius~=limit
      or memory.min_y~=area.min_y or frame<memory.plan_frame or frame-memory.plan_frame>=replan
      or (player.x-memory.plan_x)^2+(player.y-memory.plan_y)^2>64*64 then
    memory=chooseTarget(player,not invalid and memory or nil,clouds,area,stats,need,frame,limit,old_score)
  end
  state.poison_navigation=memory
  local tx,ty=memory and memory.target_x,memory and memory.target_y
  local distance=tx and sqrt((player.x-tx)^2+(player.y-ty)^2) or 0
  if tx then stats.poison_target_x,stats.poison_target_y=tx,ty end
  for _,candidate in ipairs(candidates) do
    local mx,my=pointOn(candidate,horizon*0.5,player)
    local ex,ey=pointOn(candidate,horizon,player)
    local middle=riskAt(mx,my,horizon*0.5,clouds,stats)
    local ending=riskAt(ex,ey,horizon,clouds,stats)
    candidate.poison_cost=risk_weight*(middle*0.4+ending*0.6)
    if tx then
      local remaining=sqrt((ex-tx)^2+(ey-ty)^2)
      candidate.poison_cost=candidate.poison_cost+progress_weight*(remaining-distance)
    end
    if candidate.poison_cost~=0 then stats.poison_nav_active=1 end
  end
end

return {score=score,reset=reset}
