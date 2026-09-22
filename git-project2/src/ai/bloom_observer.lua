-- Spatial bloom resources; Lua 5.1, read-only game data.
-- All ranges, weights and predictions below are strategy HEURISTICS. They are
-- NOT verified explosion/capture radii, damage, energy yields or character
-- field geometry. isErasable means erasable by an enemy explosion, not color.
-- Per the user's confirmed mechanic, ALL spirits can propagate an enemy blast;
-- only ordinary enemies / activated spirits can directly ignite our chain.
-- Bullets contribute locally and NEVER propagate a chain by themselves.
local M = {}
local abs, floor, min, max, sqrt = math.abs, math.floor, math.min, math.max, math.sqrt
-- Japanese 1.50a common C2 wave, statically traced from 403C30:
-- 41CFE0 creates type-1 bullet clearing; 41D0D0 creates type-4 enemy damage.
-- Both copy the release position, start at radius 0, grow by 4/update and have
-- lifetime 48. 41C8E0 removes them on the update computing radius 192; 188 is
-- the last live radius. These common-wave constants are not character skills.
M.c2_wave = { growth = 4, last_active_update = 47, active_radius = 188,
  exclusion_radius = 192, sweep_updates = 48 }
M.defaults = {
  above_range = 250,       -- Observe this far above the current player.
  below_range = 8,         -- Small tolerance below the player, not a rear target.
  side_range = 272,        -- Horizontal observation distance from the player.
  prediction_frames = 18,  -- One constant-velocity future sample; not simulation.
  link_radius = 64,        -- Heuristic enemy-to-enemy chain connection distance.
  bullet_radius = 48,      -- Heuristic resource neighborhood of an enemy node.
  grid_size = 16,          -- Bullet bins; neighborhood uses their cell centers.
  alignment_width = 24,    -- Heuristic shot alignment, not a character shot width.
  target_below = 76,       -- Preferred player position below the chosen resource.
  focus_radius = 64,       -- Spirit grouping distance, NOT the absorption field.
  enemy_weight = 1,
  spirit_weight = 1,      -- Unactivated spirits can relay blasts, not start shots.
  activated_weight = 1.25,
  bullet_weight = 0.06,
  bullet_score_cap = 80,   -- Bullet counts stay exact for bins; score saturates.
  density_weight = 0.3,   -- Reward a compact group of connected enemy nodes.
  future_discount = 0.85, -- Discount uncertain future geometry.
  focus_weight = 0.2,     -- Potential from nearby unactivated spirits.
  continuity_bonus = 0.25,-- Avoid target jitter when resource scores are similar.
  distance_weight = 0.001,-- Small travel preference; not part of chain_score.
  max_enemies = 128,      -- Native game has 128 enemy slots; hard-capped at 128.
  max_candidates = 12,    -- Returned summaries, hard-capped at 32.
  release_min_y = 150,    -- Top third of the full 0..448 field, rounded down-screen.
  release_max_y = 420,    -- Keep proposed release centres away from the bottom wall.
  release_side_limit = 124,-- Proposed centres keep a margin inside x=-136..136.
  release_step = 48,      -- Three columns and three rows; only same-height/lower rows.
  release_tolerance = 8,  -- at_target distance; never an attack eligibility gate.
  swallow_weight = 0.08,  -- Position merit cost per directly/contested erased bullet.
  travel_weight = 0.002,  -- Position merit cost per pixel; not path safety/reachability.
  position_search_interval = 6, -- Full <=9-site search cadence; yields are NEVER cached.
  timing_min_gain = 2,     -- Additional same-original-chain bullets for improving.
  timing_gain_ratio = 1.2, -- Future/current bullet ratio for improving, not energy.
  capture_preference_margin = 0.15, -- Same score units as ordinary candidates.
  c1_prediction_updates = 60, -- Bounded linear projection, not shot lifetime.
  reimu_c1_prediction_updates = 90, -- Includes the verified 40-Timer homing delay.
  c1_max_positions = 4,     -- Actual plus at most three lateral proposals.
  followup_travel_weight = 0.002, -- Small ranking cost, never C2 chain budget.
}

local function finite(v)
  return type(v) == "number" and v == v and v > -math.huge and v < math.huge
end
local function coordinate(v) return finite(v) and abs(v) <= 1000000 end
local function stableId(id) return finite(id) or (type(id) == "string" and #id > 0) end
local function settings(cfg)
  local c = {}
  cfg = type(cfg) == "table" and cfg or {}
  for k, fallback in pairs(M.defaults) do
    local v = cfg[k]
    c[k] = finite(v) and v >= 0 and v or fallback
  end
  -- Limit pathological configuration cost as well as ordinary scene cost.
  c.grid_size = max(8, min(64, c.grid_size))
  c.link_radius = max(1, min(192, c.link_radius))
  c.bullet_radius = min(128, c.bullet_radius)
  c.focus_radius = max(1, min(192, c.focus_radius))
  c.prediction_frames = min(60, c.prediction_frames)
  c.max_enemies = max(1, min(128, floor(c.max_enemies)))
  c.max_candidates = max(1, min(32, floor(c.max_candidates)))
  c.above_range, c.below_range, c.side_range = min(2048,c.above_range), min(128,c.below_range), min(2048,c.side_range)
  c.release_min_y = max(150, min(420, c.release_min_y))
  c.release_max_y = max(c.release_min_y, min(420, c.release_max_y))
  c.release_side_limit = min(124, c.release_side_limit)
  c.release_step, c.release_tolerance = min(192, c.release_step), min(48, c.release_tolerance)
  c.position_search_interval = max(1,min(30,floor(c.position_search_interval)))
  c.timing_min_gain, c.timing_gain_ratio = max(1,floor(c.timing_min_gain)), max(1,c.timing_gain_ratio)
  c.c1_prediction_updates = max(1,min(90,floor(c.c1_prediction_updates)))
  c.reimu_c1_prediction_updates = max(1,min(90,floor(c.reimu_c1_prediction_updates)))
  c.c1_max_positions = max(1,min(4,floor(c.c1_max_positions)))
  return c
end
local function validObject(o)
  if type(o) ~= "table" or o.enabled == false or o.enabled == 0 then return false end
  if not coordinate(o.x) or not coordinate(o.y) then return false end
  if o.vx ~= nil and not coordinate(o.vx) then return false end
  if o.vy ~= nil and not coordinate(o.vy) then return false end
  return true
end
local function near(x, y, p, c)
  return abs(x - p.x) <= c.side_range and y >= p.y - c.above_range and y <= p.y + c.below_range
end
-- Full local playfield, NOT the player's inset movement rectangle. Original
-- 1.50a initialises x=-144,y=0,width=288,height=448 at 41A9B8; movement uses
-- x=-136,y=16,width=272,height=416 at 41A9DE. Ordinary observation stays local.
local function inField(x, y) return x >= -144 and x <= 144 and y >= 0 and y <= 448 end
local function position(o, t)
  return o.x + (o.vx or 0) * t, o.y + (o.vy or 0) * t
end
local function distance2(ax, ay, bx, by)
  local dx, dy = ax - bx, ay - by
  return dx * dx + dy * dy
end
-- Numeric key is collision-free for accepted coordinates and bounded near-field
-- extrapolation (grid size >= 8). Avoid formatting thousands of strings/frame.
local function cellKey(x, y) return x * 1048576 + y end
local function addBullet(grid, x, y, size)
  local ix, iy = floor(x / size), floor(y / size)
  local key = cellKey(ix, iy)
  grid[key] = (grid[key] or 0) + 1
end

local function crossesC2Envelope(x, y, motion, p)
  local dx, dy = x - p.x, y - p.y
  if motion.inverse_length2 > 0 then
    local t = -(dx * motion.sx + dy * motion.sy) * motion.inverse_length2
    if t > 1 then t = 1 elseif t < 0 then t = 0 end
    dx, dy = dx + motion.sx * t, dy + motion.sy * t
  end
  return dx * dx + dy * dy <= 36864 -- 192 squared; common C2 envelope above.
end

-- Actual type-1 common waves are read independently from protection. Their
-- centre never follows the player; life/delay count circle updates, not Timer
-- units. This is a conservative YIELD exclusion, never a collision exemption.
local function actualWaves(sensor)
  local out={grid={},wide={},max_updates=0}
  if type(sensor)~='table' or sensor.followupApiVersion~=1 or sensor.commonWavesValid~=true or
      type(sensor.commonWaves)~='table' then return out,false end
  local seen={}
  for index,wave in ipairs(sensor.commonWaves) do
    if index>512 then return {},false end
    if type(wave)=='table' and wave.type==1 and wave.enabled==true and wave.listed==true and
        coordinate(wave.x) and coordinate(wave.y) and finite(wave.radius) and wave.radius>=0 and wave.radius<=4096 and
        finite(wave.growth) and wave.growth>=0 and wave.growth<=256 and finite(wave.life) and wave.life>0 and wave.life<=512 and
        finite(wave.delay) and wave.delay<=0 then
      local updates=max(0,wave.life-1)
      local radius=wave.radius+wave.growth*updates
      local key=table.concat({wave.x,wave.y,radius,updates},':')
      if not seen[key] then
        seen[key]=true
        local item={x=wave.x,y=wave.y,radius=radius,updates=updates}
        out[#out+1]=item
        out.max_updates=max(out.max_updates,updates)
        local x1,x2,y1,y2=floor((wave.x-radius)/64),floor((wave.x+radius)/64),floor((wave.y-radius)/64),floor((wave.y+radius)/64)
        if (x2-x1+1)*(y2-y1+1)>256 then out.wide[#out.wide+1]=item
        else
          for x=x1,x2 do for y=y1,y2 do
            local k=cellKey(x,y)
            local list=out.grid[k] or {};out.grid[k]=list;list[#list+1]=item
          end end
        end
      end
    end
  end
  return out,true
end
local function actualWaveExcludes(b,waves,scale,stats)
  if #waves==0 then return false end
  local seen={}
  local function test(wave)
    if seen[wave] then return false end
    seen[wave]=true
    stats.common_wave_tests=stats.common_wave_tests+1
    local dx,dy=b.x-wave.x,b.y-wave.y
    local sx,sy=(b.vx or 0)*scale*wave.updates,(b.vy or 0)*scale*wave.updates
    local length=sx*sx+sy*sy
    if length>0 then
      local t=max(0,min(1,-(dx*sx+dy*sy)/length))
      dx,dy=dx+sx*t,dy+sy*t
    end
    return dx*dx+dy*dy<=wave.radius*wave.radius
  end
  for _,wave in ipairs(waves.wide) do if test(wave) then return true end end
  local x=b.x+(b.vx or 0)*scale*waves.max_updates
  local y=b.y+(b.vy or 0)*scale*waves.max_updates
  local x1,x2,y1,y2=floor(min(b.x,x)/64),floor(max(b.x,x)/64),floor(min(b.y,y)/64),floor(max(b.y,y)/64)
  if (x2-x1+1)*(y2-y1+1)>256 then
    for _,wave in ipairs(waves) do if test(wave) then return true end end
  else
    for ix=x1,x2 do for iy=y1,y2 do
      local list=waves.grid[cellKey(ix,iy)]
      if list then for _,wave in ipairs(list) do if test(wave) then return true end end end
    end end
  end
  return false
end

-- Earliest integer update of predicted enemy-centre contact with the growing
-- common wave. This only establishes possible C2 ignition, not guaranteed
-- death: enemy HP/protection and explosion propagation timing are not exported.
local function c2SeedTime(node, release_time, p)
  local x, y = position(node, release_time)
  local dx, dy, vx, vy = x - p.x, y - p.y, node.vx or 0, node.vy or 0
  if vx == 0 and vy == 0 then
    local distance = sqrt(dx * dx + dy * dy)
    if distance <= M.c2_wave.active_radius then return max(1, math.ceil(distance / M.c2_wave.growth)) end
    return nil
  end
  local a = vx * vx + vy * vy - M.c2_wave.growth^2
  local b, cc = 2 * (dx * vx + dy * vy), dx * dx + dy * dy
  local first, last = 1, M.c2_wave.last_active_update
  if abs(a) < 1e-9 then
    if b < 0 then first = max(first, math.ceil(-cc / b - 1e-9))
    elseif b > 0 then last = min(last, -cc / b)
    elseif cc > 0 then return nil end
  else
    local disc = b * b - 4 * a * cc
    if disc < 0 then return nil end
    local r1, r2 = (-b - sqrt(disc)) / (2 * a), (-b + sqrt(disc)) / (2 * a)
    if r1 > r2 then r1, r2 = r2, r1 end
    if a > 0 then
      first, last = max(first, math.ceil(r1 - 1e-9)), min(last, r2)
    elseif a * first * first + b * first + cc > 0 then
      first = max(first, math.ceil(r2 - 1e-9))
    end
  end
  if first <= last + 1e-9 and a * first * first + b * first + cc <= 1e-6 then return first end
  return nil
end

local function components(nodes, t, grid, p, c, stats, lock_ids, net_grid, full_field)
  local points, parent, groups, by_node = {}, {}, {}, {}
  local link2, radius, size = c.link_radius*c.link_radius, c.bullet_radius, c.grid_size
  local radius2 = radius*radius
  for i, node in ipairs(nodes) do
    local x, y = position(node, t)
    if (full_field and inField(x, y)) or (not full_field and near(x, y, p, c)) then
      points[i], parent[i] = { x = x, y = y }, i
    end
  end
  local function root(i)
    while parent[i] ~= i do parent[i] = parent[parent[i]]; i = parent[i] end
    return i
  end
  for i = 1, #nodes do
    if points[i] then
      local a = root(i)
      for j = 1, i - 1 do
        if points[j] then
          local b = root(j)
          -- Existing connectivity is enough; no need to retest every pair in
          -- an already joined dense formation.
          if a ~= b then
            stats.enemy_pair_tests = stats.enemy_pair_tests + 1
            if distance2(points[i].x, points[i].y, points[j].x, points[j].y) <= link2 then
              parent[a], a = b, b
            end
          end
        end
      end
    end
  end
  for i, node in ipairs(nodes) do
    if points[i] then
      local r, q = root(i), points[i]
      local g = groups[r]
      if not g then
        g = { enemies = 0, fairies = 0, spirits = 0, activated = 0, bullets = 0,
          score = 0, cells = {}, ids = {}, lock_match = false, net_bullets = 0,
          min_x = q.x, max_x = q.x, min_y = q.y, max_y = q.y }
        groups[r] = g
      end
      g.enemies = g.enemies + 1
      g.ids[#g.ids + 1] = node.id
      if type(lock_ids) == "table" and lock_ids[node.id] == true then g.lock_match = true end
      local kind = node.activated and "activated" or (node.spirit and "spirits" or "fairies")
      g[kind] = g[kind] + 1
      g.score = g.score + (node.activated and c.activated_weight or (node.spirit and c.spirit_weight or c.enemy_weight))
      g.min_x, g.max_x = min(g.min_x, q.x), max(g.max_x, q.x)
      g.min_y, g.max_y = min(g.min_y, q.y), max(g.max_y, q.y)
      for ix = floor((q.x - radius) / size), floor((q.x + radius) / size) do
        for iy = floor((q.y - radius) / size), floor((q.y + radius) / size) do
          stats.grid_queries = stats.grid_queries + 1
          local key = cellKey(ix, iy)
          if not g.cells[key] and distance2(q.x, q.y, (ix + 0.5) * size, (iy + 0.5) * size) <= radius2 then
            g.cells[key] = true
            g.bullets = g.bullets + (grid[key] or 0)
            g.net_bullets = g.net_bullets + (net_grid and net_grid[key] or 0)
          end
        end
      end
      by_node[i] = g
    end
  end
  for _, g in pairs(groups) do
    local span = sqrt((g.max_x - g.min_x)^2 + (g.max_y - g.min_y)^2)
    g.score = g.score + min(g.bullets, c.bullet_score_cap) * c.bullet_weight
      + max(g.enemies - 1, 0) * c.density_weight / (1 + span / c.link_radius)
    -- Retain membership for C2 reuse when full/local views happen to coincide.
  end
  return by_node, groups
end

local function emptyTiming(window)
  return {valid=false,current_bullets=0,future_bullets=0,leaving_bullets=0,
    arriving_bullets=0,earliest_exit_frames=nil,urgency=false,improving=false,window_frames=window or 0}
end
local function emptyC2()
  return { has_ignition = false, chain_ids = {}, chain_enemies = 0, chain_fairies = 0,
    chain_spirits = 0, chain_activated = 0, chain_bullets = 0, chain_score = 0,
    direct_bullets = 0, contested_bullets = 0, future_has_ignition = false,
    future_enemies = 0, future_fairies = 0, future_spirits = 0, future_activated = 0,
    future_bullets = 0, future_score = 0, future_direct_bullets = 0, future_contested_bullets = 0,
    timing = emptyTiming() }
end
local function emptyCapture()
  return {valid=false,has_target=false,preferred=false,chain_ids={},focus_chain_ids={},
    chain_score=0,chain_bullets=0,chain_enemies=0,chain_spirits=0,chain_activated=0,
    future_score=0,future_bullets=0,future_enemies=0,focus_value=0,value=0,
    chain_activated_gain=0,timing=emptyTiming(),at_target=false}
end
local function emptyC1()
  local out=emptyC2()
  out.valid,out.model_limited,out.hit_count,out.seed_ids=false,true,0,{}
  out.action_active,out.remaining_only=false,false
  return out
end

local function c2Score(group, cfg)
  -- Strip the ordinary-shot bullet term completely before adding NET bullets.
  return group.score - min(group.bullets, cfg.bullet_score_cap) * cfg.bullet_weight
    + min(group.net_bullets, cfg.bullet_score_cap) * cfg.bullet_weight
end
local function c2LockAllows(state, node, group)
  return group and (state.lock_ids ~= nil and group.lock_match
    or (state.lock_ids == nil and (state.bloom_observer_lock_id == nil or state.bloom_observer_lock_id == node.id)))
end

local function chooseC2(nodes, now, future, p, c, state, blocked_now, blocked_future, remember)
  local out, best = emptyC2(), nil
  out.direct_bullets, out.future_direct_bullets = blocked_now, blocked_future
  for i, node in ipairs(nodes) do
    local g, f = now[i], future[i]
    if c2LockAllows(state, node, g) then
      local contact = c2SeedTime(node, 0, p)
      if contact then
        local future_contact = f and c2SeedTime(node, c.prediction_frames, p)
        local score, later_score = c2Score(g, c), future_contact and c2Score(f, c) or 0
        local merit = max(score, later_score * c.future_discount)
          + (state.bloom_observer_c2_id == node.id and c.continuity_bonus or 0)
        if not best or merit > best.merit or (merit == best.merit and contact < best.contact) then
          best = { node = node, g = g, f = future_contact and f or nil, merit = merit,
            score = score, later_score = later_score, contact = contact }
        end
      end
    end
  end
  if not best then
    if remember then state.bloom_observer_c2_id = nil end
    return out
  end
  local g, f, node = best.g, best.f, best.node
  out.has_ignition, out.seed_id, out.chain_ids = true, node.id, g.ids
  out.chain_enemies, out.chain_fairies, out.chain_spirits, out.chain_activated = g.enemies, g.fairies, g.spirits, g.activated
  out.chain_bullets, out.chain_score = g.net_bullets, best.score
  -- Exposure estimates, not actual clear counters: contested is the part of
  -- this propagation group's neighborhood swept by C2; direct is the rest of
  -- the observed C2 envelope exposure. BOTH have zero modeled yield.
  out.contested_bullets = g.bullets - g.net_bullets
  out.direct_bullets = max(0, blocked_now - out.contested_bullets)
  out.target_x, out.target_y = p.x, p.y -- proposed fixed RELEASE centre, not shot alignment
  out.seed_x, out.seed_y = node.x, node.y
  out.seed_contact_updates = best.contact
  out.future_has_ignition, out.future_score = f ~= nil, best.later_score
  if f then
    out.future_enemies, out.future_fairies, out.future_spirits, out.future_activated = f.enemies, f.fairies, f.spirits, f.activated
    out.future_bullets = f.net_bullets
    out.future_contested_bullets = f.bullets - f.net_bullets
    out.future_direct_bullets = max(0, blocked_future - out.future_contested_bullets)
  end
  if remember then state.bloom_observer_c2_id = node.id end
  return out
end

-- The same graph and cell membership serve every release centre. A bullet may
-- belong to two disconnected groups' overlapping neighbourhoods, but is counted
-- only once within either group. No candidate rebuilds enemy connectivity.
local function cellOwners(groups)
  local owners = {}
  for _, g in pairs(groups) do
    for key in pairs(g.cells) do
      local list = owners[key]
      if not list then list = {}; owners[key] = list end
      list[#list + 1] = g
    end
  end
  return owners
end
local function netResources(bullets, groups, centre, later, stats, actual)
  for _, g in pairs(groups) do g.net_bullets = 0 end
  local blocked = 0
  for _, b in ipairs(bullets) do
    local present = later and b.later or (not later and b.now)
    if present then
      local x, y = b.x, b.y
      if later then x, y = b.fx, b.fy end
      local swallowed
      if later and b.now and b.x == b.fx and b.y == b.fy then swallowed = b.blocked_now
      else
        stats.c2_bullet_tests = stats.c2_bullet_tests + 1
        swallowed = crossesC2Envelope(x, y, b, centre)
      end
      if not later then b.blocked_now = swallowed end
      -- Only frame-local records hold these flags. Candidate-site scans must
      -- not replace the actual player's exclusion result used by chain timing.
      if actual then
        if later then b.actual_blocked_future=swallowed else b.actual_blocked_now=swallowed end
      end
      if swallowed then blocked = blocked + 1
      else
        local list = b.now_groups
        if later then list = b.future_groups end
        if list then for _, g in ipairs(list) do g.net_bullets = g.net_bullets + 1 end end
      end
    end
  end
  return blocked
end
local function positionMerit(assessment, cfg)
  return max(assessment.chain_score, assessment.future_score * cfg.future_discount)
    - cfg.swallow_weight * max(assessment.direct_bullets + assessment.contested_bullets,
      (assessment.future_direct_bullets + assessment.future_contested_bullets) * cfg.future_discount)
end
local function positionConfigKey(c, character)
  -- prediction_frames is a dynamic charge ETA. Every assessment uses its new
  -- value; changing it must not turn the throttled search back into every-frame.
  local parts = {tostring(character)}
  for _,key in ipairs({'release_min_y','release_max_y','release_side_limit','release_step',
    'release_tolerance','position_search_interval','swallow_weight','travel_weight',
    'link_radius','bullet_radius','grid_size','max_enemies','enemy_weight','spirit_weight',
    'activated_weight','bullet_weight','bullet_score_cap','density_weight','future_discount','continuity_bonus'}) do
    parts[#parts+1] = tostring(c[key])
  end
  return table.concat(parts, ':')
end
local function assessPositions(nodes, bullets, now, future, now_groups, future_groups, p, c, state, stats)
  local now_owners, future_owners = cellOwners(now_groups), cellOwners(future_groups)
  for _, b in ipairs(bullets) do
    b.now_groups = now_owners[cellKey(floor(b.x/c.grid_size),floor(b.y/c.grid_size))]
    b.future_groups = future_owners[cellKey(floor(b.fx/c.grid_size),floor(b.fy/c.grid_size))]
  end
  local function assess(centre, remember)
    stats.c2_position_evaluations = stats.c2_position_evaluations + 1
    local blocked = netResources(bullets, now_groups, centre, false, stats,remember)
    local later = netResources(bullets, future_groups, centre, true, stats,remember)
    return chooseC2(nodes, now, future, centre, c, state, blocked, later, remember)
  end
  local function reachable(centre)
    for i,node in ipairs(nodes) do
      if c2LockAllows(state,node,now[i]) and c2SeedTime(node,0,centre) then return true end
    end
    return false
  end
  local actual = assess(p, true)
  local current_value = actual.has_ignition and positionMerit(actual, c) or nil
  local best, visited, count = nil, {}, 0
  state.bloom_observer_position_tick = (state.bloom_observer_position_tick or 0) + 1
  local tick = state.bloom_observer_position_tick
  local config_key = positionConfigKey(c,p.character)
  local cache_x,cache_y = state.bloom_observer_position_x,state.bloom_observer_position_y
  local legal_current = p.x >= -136 and p.x <= 136 and p.y >= c.release_min_y and p.y <= 432
  local cache_is_actual = cache_x == p.x and cache_y == p.y and legal_current
  local cache_legal = coordinate(cache_x) and coordinate(cache_y)
    and cache_x >= -136 and cache_x <= 136 and cache_y >= c.release_min_y and cache_y <= 432
    and (cache_is_actual or (abs(cache_x)<=c.release_side_limit
      and (cache_y<=c.release_max_y or cache_y==p.y)))
  local full_search = state.bloom_observer_position_config ~= config_key or not cache_legal
    or tick - (state.bloom_observer_position_search_tick or -30) >= c.position_search_interval
  local function consider(x,y,continuity_enabled)
    local key = tostring(x)..":"..tostring(y)
    if visited[key] ~= nil then return visited[key] end
    count = count + 1
    local candidate
    if x==p.x and y==p.y then candidate=actual
    else
      local centre={x=x,y=y}
      if reachable(centre) then candidate=assess(centre,false) end
    end
    visited[key] = candidate or false
    if candidate and candidate.has_ignition and y>=min(p.y,432) then
      local travel=sqrt(distance2(x,y,p.x,p.y))
      local value=positionMerit(candidate,c)-c.travel_weight*travel
      local continuity=continuity_enabled and cache_x==x and cache_y==y and c.continuity_bonus or 0
      if not best or value+continuity>best.rank or (value+continuity==best.rank and travel<best.travel) then
        best={assessment=candidate,value=value,rank=value+continuity,travel=travel}
      end
    end
    return candidate
  end
  if not full_search then
    if legal_current then consider(p.x,p.y,false) end
    local cached=consider(cache_x,cache_y,false)
    if not cached or not cached.has_ignition then full_search=true end
  end
  -- An empty/locked-away resource scene cannot supply any candidate. Do not
  -- search/scatter bullet scans; absence of a cached point lets newly arriving
-- resources trigger a search immediately, without waiting six observations.
  local eligible = false
  for i,node in ipairs(nodes) do
    if c2LockAllows(state,node,now[i]) then eligible=true; break end
  end
  if not eligible then
    full_search=false
    state.bloom_observer_position_x,state.bloom_observer_position_y=nil,nil
  end
  local bx = max(-c.release_side_limit, min(c.release_side_limit, p.x))
  local by = max(c.release_min_y, min(c.release_max_y, p.y))
  -- A legal actual point replaces the first slot, including wall-side points.
  -- Candidate wall margins must never pull a player below y=420 upward again.
  if full_search then
  -- A failed cached seed is cheaply rejected before a full search, so reset
  -- candidate bookkeeping. Actual itself is reused, not scanned a second time.
  best,visited,count = nil,{},0
  for row = 0, 2 do
    for _, col in ipairs({0, -1, 1}) do
      local x = max(-c.release_side_limit, min(c.release_side_limit, bx + col * c.release_step))
      local y = max(min(432,p.y), max(c.release_min_y, min(c.release_max_y, by + row * c.release_step)))
      if row == 0 and col == 0 and legal_current then x,y = p.x,p.y end
      consider(x,y,true)
    end
  end
  state.bloom_observer_position_search_tick=tick
  state.bloom_observer_position_config=config_key
  state.bloom_observer_position_x=best and best.assessment.target_x or nil
  state.bloom_observer_position_y=best and best.assessment.target_y or nil
  end
  stats.c2_position_candidates = count
  stats.c2_position_full_search = full_search
  local out = emptyC2()
  if best then
    -- Copy: actual is also a candidate; position metadata must never mutate c2.
    for k,v in pairs(best.assessment) do out[k] = v end
    out.value, out.travel_distance = best.value, best.travel
    out.at_target = best.travel <= c.release_tolerance
    out.improvement = current_value and best.value - current_value or nil
  else
    out.at_target = false
  end
  out.current_value, out.candidate_count = current_value, count
  return actual, out
end

local function spiritPotential(spirits, x, y, c, stats)
  local value, sx, sy, count = 0, 0, 0, 0
  for _, s in ipairs(spirits) do
    stats.focus_pair_tests = stats.focus_pair_tests + 1
    local d = distance2(s.x, s.y, x, y)
    if d <= c.focus_radius^2 then
      count, sx, sy = count + 1, sx + s.x, sy + s.y
      value = value + 1 - 0.25 * sqrt(d) / c.focus_radius
    end
  end
  return value, count > 0 and sx / count or x, count > 0 and sy / count or y, count
end

local function nodeIndexes(nodes)
  local out={}
  for i,node in ipairs(nodes) do out[node.id]=i end
  return out
end
local function addTimingCells(cells, node, t, c, stats)
  local x,y=position(node,t)
  local size,radius=c.grid_size,c.bullet_radius
  for ix=floor((x-radius)/size),floor((x+radius)/size) do
    for iy=floor((y-radius)/size),floor((y+radius)/size) do
      stats.timing_grid_queries=stats.timing_grid_queries+1
      if distance2(x,y,(ix+.5)*size,(iy+.5)*size)<=radius*radius then cells[cellKey(ix,iy)]=true end
    end
  end
end
-- One node is the only case where the exit from the union of neighbourhoods is
-- unambiguous without simulating propagation. Require known constant velocities
-- and agreement with the actual circle, not just approximate bin membership.
local function singleNodeExit(b,node,c)
  if not b.velocity_known or not node.velocity_known or c.prediction_frames<=0 then return nil end
  local dx,dy=b.x-node.x,b.y-node.y
  local vx,vy=b.vx-node.vx,b.vy-node.vy
  local r2=c.bullet_radius*c.bullet_radius
  local a=vx*vx+vy*vy
  if dx*dx+dy*dy>r2 or a<=1e-12 then return nil end
  local ex,ey=dx+vx*c.prediction_frames,dy+vy*c.prediction_frames
  if ex*ex+ey*ey<=r2 then return nil end
  local bb=2*(dx*vx+dy*vy)
  local disc=bb*bb-4*a*(dx*dx+dy*dy-r2)
  if disc<0 then return nil end
  local exit=(-bb+sqrt(disc))/(2*a)
  if finite(exit) and exit>=0 and exit<=c.prediction_frames then return exit end
  return nil
end
local function chainTiming(seed_index,nodes,indexes,now,future,bullets,p,c,state,stats,c2_mode,future_eligible)
  local out=emptyTiming(c.prediction_frames)
  local current=seed_index and now[seed_index]
  if not current then return out end
  local later=seed_index and future[seed_index]
  if future_eligible==false then later=nil end
  local originals,later_nodes={},{}
  for _,id in ipairs(current.ids) do
    local i=indexes[id]
    -- A preparation/attack lock defines the original saved set. Otherwise the
    -- currently selected component defines it; newly joining future nodes do not.
    if i and (state.lock_ids==nil or (type(state.lock_ids)=='table' and state.lock_ids[id]==true)) then
      originals[#originals+1]=nodes[i]
      if later and future[i]==later then later_nodes[#later_nodes+1]=nodes[i] end
    end
  end
  if #originals==0 then return out end
  local current_cells=current.cells
  if #originals~=#current.ids then
    current_cells={}
    for _,node in ipairs(originals) do addTimingCells(current_cells,node,0,c,stats) end
  end
  local later_cells={}
  if later and #later_nodes==#later.ids then later_cells=later.cells
  else for _,node in ipairs(later_nodes) do addTimingCells(later_cells,node,c.prediction_frames,c,stats) end end
  out.valid=true
  local earliest,precise=nil,#originals==1 and #later_nodes==1
  for _,b in ipairs(bullets) do
    stats.timing_bullet_tests=stats.timing_bullet_tests+1
    local bounds_now,bounds_later=b.near_now,b.near_later
    if c2_mode then bounds_now,bounds_later=b.now,b.later end
    local has_now=bounds_now and current_cells[b.now_key]==true
    local has_later=bounds_later and later_cells[b.future_key]==true
    local later_blocked=false
    if c2_mode then
      if has_now then has_now=not b.actual_blocked_now end
      if has_later then
        later_blocked=b.actual_blocked_future
        has_later=not later_blocked
      end
    end
    if has_now then out.current_bullets=out.current_bullets+1 end
    if has_later then out.future_bullets=out.future_bullets+1 end
    if has_now and not has_later then
      out.leaving_bullets=out.leaving_bullets+1
      -- An envelope loss is not a measured exit from the chain neighborhood.
      if c2_mode and precise and not later_blocked then
        later_blocked=b.actual_blocked_future
      end
      if precise and bounds_now and bounds_later and not later_blocked then
        local exit=singleNodeExit(b,originals[1],c)
        if exit then earliest=earliest and min(earliest,exit) or exit else precise=false end
      else precise=false end
    elseif has_later and not has_now then out.arriving_bullets=out.arriving_bullets+1 end
  end
  out.urgency=out.leaving_bullets>0
  out.improving=out.future_bullets-out.current_bullets>=c.timing_min_gain
    and out.future_bullets>=out.current_bullets*c.timing_gain_ratio
  if precise and out.urgency then out.earliest_exit_frames=earliest end
  return out
end

-- Count only the retained original members that still belong to this seed's
-- future component. Newly arriving nodes must not inflate a capture promise.
local function retainedFuture(group,seed,nodes,indexes,future,grid,c,state,stats)
  local destination=future[seed]
  local out={score=0,bullets=0,enemies=0,spirits=0,activated=0,cells={}}
  if not destination then return out end
  for _,id in ipairs(group.ids) do
    local i=indexes[id]
    if i and future[i]==destination and (state.lock_ids==nil or
        type(state.lock_ids)=='table' and state.lock_ids[id]==true) then
      local node=nodes[i]
      out.enemies=out.enemies+1
      if node.spirit then
        if node.activated then out.activated=out.activated+1 else out.spirits=out.spirits+1 end
      end
      out.score=out.score+(node.activated and c.activated_weight or
        node.spirit and c.spirit_weight or c.enemy_weight)
      addTimingCells(out.cells,node,c.prediction_frames,c,stats)
    end
  end
  for key in pairs(out.cells) do out.bullets=out.bullets+(grid[key] or 0) end
  out.score=out.score+min(out.bullets,c.bullet_score_cap)*c.bullet_weight
  return out
end

local function assessCapture(nodes,spirits,indexes,now,future,future_grid,bullets,p,c,state,stats,activated,ordinary)
  local out,seen,best=emptyCapture(),{},nil
  out.valid=true
  for _,spirit in ipairs(spirits) do
    local i=indexes[spirit.id]
    local group=now[i]
    if group and not seen[group] and c2LockAllows(state,spirit,group) then
      seen[group]=true
      local cluster={}
      for _,id in ipairs(group.ids) do
        local n=nodes[indexes[id]]
        if n and n.spirit and not n.activated and (state.lock_ids==nil or
            type(state.lock_ids)=='table' and state.lock_ids[id]==true) then
          cluster[#cluster+1]=n
        end
      end
      local sx,sy,count,anchor=0,0,0,spirit
      -- A long connected chain may have distinct spirit clusters. Never aim
      -- at their empty global centroid as if it were a capture opportunity.
      for _,a in ipairs(cluster) do
        local ax,ay,n=0,0,0
        for _,b in ipairs(cluster) do
          stats.focus_pair_tests=stats.focus_pair_tests+1
          if distance2(a.x,a.y,b.x,b.y)<=c.focus_radius*c.focus_radius then ax,ay,n=ax+b.x,ay+b.y,n+1 end
        end
        if n>count then sx,sy,count,anchor=ax,ay,n,a end
      end
      i=indexes[anchor.id]
      if count>0 then
        local fx,fy=sx/count,sy/count
        local tx=max(-c.release_side_limit,min(c.release_side_limit,fx))
        local ty=max(c.release_min_y,min(c.release_max_y,fy+c.target_below))
        local later=retainedFuture(group,i,nodes,indexes,future,future_grid,c,state,stats)
        local value=max(group.score,later.score*c.future_discount)+count*c.focus_weight
          -(abs(fx-p.x)+abs(fy+c.target_below-p.y))*c.distance_weight
          +(state.bloom_observer_capture_id==anchor.id and c.continuity_bonus or 0)
        if not best or value>best.value then
          best={seed=i,id=anchor.id,g=group,later=later,value=value,fx=fx,fy=fy,tx=tx,ty=ty,count=count}
        end
      end
    end
  end
  if not best then
    if type(state.lock_ids)=='table' then
      for id in pairs(activated) do if state.lock_ids[id]==true then out.chain_activated_gain=out.chain_activated_gain+1 end end
    end
    state.bloom_observer_capture_id=nil;return out
  end
  local g,later=best.g,best.later
  out.has_target,out.target_id,out.chain_ids,out.focus_chain_ids=true,best.id,g.ids,g.ids
  out.focus_x,out.focus_y,out.target_x,out.target_y=best.fx,best.fy,best.tx,best.ty
  out.focus_value,out.focus_spirits,out.value=best.count,best.count,best.value
  out.chain_score,out.chain_bullets,out.chain_enemies=g.score,g.bullets,g.enemies
  out.chain_spirits,out.chain_activated=g.spirits,g.activated
  out.future_score,out.future_bullets,out.future_enemies=later.score,later.bullets,later.enemies
  out.future_spirits,out.future_activated=later.spirits,later.activated
  out.travel_distance=sqrt(distance2(p.x,p.y,best.tx,best.ty))
  out.at_target=out.travel_distance<=c.release_tolerance
  out.preferred=not ordinary or not ordinary.has_ignition or
    best.value>=ordinary.value+c.capture_preference_margin
  if not out.preferred and ordinary and (ordinary.focus_spirits or 0)>0 then
    local ids={}
    for _,id in ipairs(g.ids) do ids[id]=true end
    for _,id in ipairs(ordinary.focus_chain_ids or {}) do if ids[id] then out.preferred=true;break end end
  end
  out.timing=chainTiming(best.seed,nodes,indexes,now,future,bullets,p,c,state,stats,false)
  for _,id in ipairs(g.ids) do
    if activated[id] and (state.lock_ids==nil or type(state.lock_ids)=='table' and state.lock_ids[id]==true) then
      out.chain_activated_gain=out.chain_activated_gain+1
    end
  end
  state.bloom_observer_capture_id=best.id
  return out
end

local function axisInterval(delta,velocity,half,first,last)
  if first>last then return nil end
  if abs(velocity)<1e-9 then
    if abs(delta)>half then return nil end
    return first,last
  end
  local a,b=(-half-delta)/velocity,(half-delta)/velocity
  if a>b then a,b=b,a end
  first,last=max(first,a),min(last,b)
  if first<=last then return first,last end
end
local function c1Models(sensor,c,reimu)
  local profile=type(sensor)=='table' and sensor.followupApiVersion==1 and sensor.c1Profile
  local out={valid=false,limited=true,pending={},active={},action_active=false}
  out.reimu=reimu==true
  local pending_seen,active_seen={},{}
  if type(profile)~='table' then return out end
  out.homing_valid=profile.homingTargetValid==true and coordinate(profile.homingTargetX) and coordinate(profile.homingTargetY)
  out.homing_state_valid=profile.homingStateValid==true
  out.homing_x,out.homing_y=profile.homingTargetX,profile.homingTargetY
  out.reimu_profile_valid=profile.valid==true and profile.activeValid==true
  out.action_active=sensor.c1ActionActive==true
  out.remaining_only=out.action_active or profile.activeValid==true and
    type(profile.activeShots)=='table' and #profile.activeShots>0
  out.valid=profile.valid==true or profile.activeValid==true
  out.limited=profile.limited~=false or profile.valid~=true or profile.activeValid~=true
  local scale=finite(sensor.timeScale) and max(0,min(1,sensor.timeScale)) or 1
  local age=out.action_active and sensor.c1ActionAge or 0
  local duration=finite(profile.actionDuration) and profile.actionDuration or sensor.c1ActionDuration
  if not finite(duration) or duration<0 then duration=0;out.limited=true end
  if not finite(age) or age<0 then age=0;out.limited=true end
  if profile.valid==true and type(profile.shots)=='table' then
    for index,shot in ipairs(profile.shots) do
      if index>128 then out.limited=true;break end
      local special=type(shot)=='table' and reimu and shot.motionModel=='reimu_c1_homing'
      local valid=type(shot)=='table' and (shot.supported==true or special) and
        finite(shot.spawnTick) and shot.spawnTick>=0 and finite(shot.offsetX) and finite(shot.offsetY) and
        finite(shot.width) and shot.width>0 and shot.width<=4096 and finite(shot.height) and shot.height>0 and shot.height<=4096 and
        finite(shot.angle) and finite(shot.speed) and abs(shot.speed)<=256 and finite(shot.damage) and shot.damage>0 and
        finite(shot.type) and shot.type>=0 and shot.type<=3 and shot.type==floor(shot.type)
      if valid and shot.spawnTick<duration and (not out.remaining_only or out.action_active and shot.spawnTick>age) then
        local delay=scale>0 and max(0,(shot.spawnTick-age)/scale) or math.huge
        local key=reimu and index or table.concat({shot.offsetX,shot.offsetY,shot.width,shot.height,shot.angle,shot.speed,delay,shot.type},':')
        if delay<=c.c1_prediction_updates and not pending_seen[key] then
          pending_seen[key]=true
          out.pending[#out.pending+1]={x=shot.offsetX,y=shot.offsetY,width=shot.width,height=shot.height,
            vx=math.cos(shot.angle)*shot.speed*scale,vy=math.sin(shot.angle)*shot.speed*scale,
            delay=delay,horizon=c.c1_prediction_updates,scale=scale,absolute=out.action_active,
            piercing=shot.type==2 or shot.type==3,type=shot.type,damage=shot.damage,
            speed=shot.speed,motion_model=special and 'reimu_c1_homing' or nil}
        end
      elseif not valid then out.limited=true end
    end
  end
  if profile.activeValid==true and type(profile.activeShots)=='table' then
    for index,shot in ipairs(profile.activeShots) do
      if index>128 then out.limited=true;break end
      if type(shot)=='table' and shot.supported==true and shot.damageReady~=false and coordinate(shot.x) and coordinate(shot.y) and
          finite(shot.width) and shot.width>0 and shot.width<=4096 and finite(shot.height) and shot.height>0 and shot.height<=4096 and
          finite(shot.damage) and shot.damage>0 and finite(shot.type) and shot.type>=0 and shot.type<=3 and shot.type==floor(shot.type) then
        -- Native slots identify independent cards even when their AABBs overlap.
        local key=reimu and shot.slotId or table.concat({shot.x,shot.y,shot.width,shot.height,shot.type},':')
        if reimu and (not finite(key) or key<0 or key~=floor(key)) then out.limited=true
        elseif not active_seen[key] then out.active[#out.active+1]=shot;active_seen[key]=true end
      elseif type(shot)~='table' or shot.damageReady~=false then out.limited=true end
    end
  end
  return out
end
-- A target centre inside the verified shot AABB is a conservative possible
-- hit. Enemy edge/radius, HP/protection and custom shot callbacks are not
-- invented. Angle changes motion only; the native generic AABB does not rotate.
local function c1Hit(node,centre,models,t,stats,include_active)
  if not node.ignitable then return false,false end
  local x,y=position(node,t)
  if include_active then
    for _,shot in ipairs(models.active) do
      stats.c1_hit_tests=stats.c1_hit_tests+1
      if abs(x-shot.x)<=shot.width*.5 and abs(y-shot.y)<=shot.height*.5 then return true,true,shot,0 end
    end
  end
  for _,shot in ipairs(models.pending) do
    stats.c1_hit_tests=stats.c1_hit_tests+1
    local delay=shot.absolute and max(0,shot.delay-t) or shot.delay
    local elapsed=shot.absolute and max(0,t-shot.delay) or 0
    local horizon=shot.absolute and max(0,shot.horizon-t) or shot.horizon
    local dx=x+node.vx*shot.scale*delay-centre.x-shot.x-shot.vx*elapsed
    local dy=y+node.vy*shot.scale*delay-centre.y-shot.y-shot.vy*elapsed
    local first,last=axisInterval(dx,node.vx*shot.scale-shot.vx,shot.width*.5,0,horizon-delay)
    if first then
      first,last=axisInterval(dy,node.vy*shot.scale-shot.vy,shot.height*.5,first,last)
      if first then return true,false,shot,first+delay end
    end
  end
  return false,false
end
local function unionResources(selected,nodes,indexes,grid,c,originals,t,stats)
  local out={enemies=0,fairies=0,spirits=0,activated=0,bullets=0,score=0,ids={},cells={},id_set={}}
  for group in pairs(selected) do
    for _,id in ipairs(group.ids) do
      if not out.id_set[id] and (not originals or originals[id]) then
        local node=nodes[indexes[id]]
        out.id_set[id]=true;out.ids[#out.ids+1]=id;out.enemies=out.enemies+1
        local kind=node.activated and 'activated' or node.spirit and 'spirits' or 'fairies'
        out[kind]=out[kind]+1
        out.score=out.score+(node.activated and c.activated_weight or node.spirit and c.spirit_weight or c.enemy_weight)
        addTimingCells(out.cells,node,t,c,stats)
      end
    end
  end
  for key in pairs(out.cells) do out.bullets=out.bullets+(grid[key] or 0) end
  out.score=out.score+min(out.bullets,c.bullet_score_cap)*c.bullet_weight
  return out
end
local function c1UnionTiming(current,later,bullets,c,stats)
  local out=emptyTiming(c.prediction_frames)
  out.valid=current.enemies>0
  for _,b in ipairs(bullets) do
    stats.timing_bullet_tests=stats.timing_bullet_tests+1
    local a=b.now and current.cells[b.now_key]==true
    local f=b.later and later.cells[b.future_key]==true
    if a then out.current_bullets=out.current_bullets+1 end
    if f then out.future_bullets=out.future_bullets+1 end
    if a and not f then out.leaving_bullets=out.leaving_bullets+1
    elseif f and not a then out.arriving_bullets=out.arriving_bullets+1 end
  end
  out.urgency=out.leaving_bullets>0
  out.improving=out.future_bullets-out.current_bullets>=c.timing_min_gain and
    out.future_bullets>=out.current_bullets*c.timing_gain_ratio
  return out
end

-- Reimu's four non-piercing cards use a verified custom motion callback.
-- Keep this separate from generic SHT coverage: contact must fund a kill,
-- protected/boss targets still consume cards, and unactivated spirits never
-- become direct C1 seeds. Forecasts retain the CURRENT homing target only;
-- new spawns, target switches, other shots and blast damage supply no credit.
local function reimuDamageSeeds(enemies,centre,models,p,c,stats,t,actual)
  local targets,seeds={},{}
  local sensor=p.sensor or {}
  local scale=finite(sensor.timeScale) and sensor.timeScale or 0
  local valid=models.reimu_profile_valid and scale==1
  if not valid then return false,seeds,0,0 end
  local release_delay=0
  if not models.remaining_only then
    if not finite(p.chargeSpeed) or p.chargeSpeed<=0 or not finite(p.currentCharge)
        or not finite(sensor.chargeWarmupFrames) then return false,seeds,0,0 end
    release_delay=math.ceil(max(0,100-p.currentCharge)/p.chargeSpeed
      +max(0,sensor.chargeWarmupFrames))
    if release_delay>90 then return false,seeds,0,0 end
  end
  local goal,ambiguous_goal=nil,false
  for _,e in ipairs(enemies or {}) do
    if validObject(e) and e.enabled~=false and e.enabled~=0 then
      local s=e.sensor
      if #targets>=128 or not stableId(e.id) or type(s)~='table' or s.apiVersion~=1 or s.valid~=true
          or not finite(s.health) or s.health<0 or s.health~=floor(s.health)
          or type(s.shotCollisionEnabled)~='boolean' or type(s.shotDamageable)~='boolean'
          or not finite(s.shotDamageDivisor) or s.shotDamageDivisor<1
          or not coordinate(s.hitX) or not coordinate(s.hitY)
          or not finite(s.hitWidth) or s.hitWidth<0 or s.hitWidth>4096
          or not finite(s.hitHeight) or s.hitHeight<0 or s.hitHeight>4096
          or not finite(e.vx) or not finite(e.vy) then return false,{},0,0 end
      -- Unknown extra collision geometry can consume cards before another
      -- target, so merely withholding this enemy's own kill credit is unsafe.
      if s.shotCollisionEnabled and s.damageModelLimited==true then return false,{},0,0 end
      local v={id=e.id,x=s.hitX,y=s.hitY,vx=e.vx,vy=e.vy,health=s.health,
        width=s.hitWidth,height=s.hitHeight,collision=s.shotCollisionEnabled,
        damageable=s.shotDamageable and s.damageModelLimited~=true,divisor=s.shotDamageDivisor,
        seed=not(e.isBoss or e.isLily or e.isPseudoEnemy) and (not e.isSpirit or e.isActivatedSpirit==true)}
      targets[#targets+1]=v
      if models.homing_valid and abs(s.hitX-models.homing_x)<.01 and abs(s.hitY-models.homing_y)<.01 then
        if goal then ambiguous_goal=true else goal=v end
      end
    end
  end
  -- Unmatched/ambiguous native homing targets are not invented future paths.
  local can_project=models.homing_state_valid and (not models.homing_valid or goal and not ambiguous_goal)
  local projectiles={}
  if can_project then
    for _,s in ipairs(models.pending) do
      if s.motion_model=='reimu_c1_homing' and s.type==0 and s.damage>0 then
        projectiles[#projectiles+1]={x=centre.x+s.x,y=centre.y+s.y,vx=s.vx,vy=s.vy,
          speed=s.speed,damage=s.damage,width=s.width,height=s.height,delay=s.delay,alive=true}
      end
    end
  end
  local hits,last_kill=0,0
  -- Swept target bins only reduce collision candidates; every queried hit is
  -- still checked against the exact projected primary AABB. Include charge
  -- lead, enemy velocity and the largest relevant card. Large sweeps use a
  -- bounded fallback list rather than allocating an unbounded grid.
  local hit_grid,wide={},{}
  local half_x,half_y=0,0
  for _,s in ipairs(projectiles) do half_x=max(half_x,s.width*.5);half_y=max(half_y,s.height*.5) end
  for _,s in ipairs(models.active) do half_x=max(half_x,s.width*.5);half_y=max(half_y,s.height*.5) end
  local horizon=models.remaining_only and 0 or c.reimu_c1_prediction_updates
  for i,v in ipairs(targets) do
    if v.collision and v.health>0 then
      v.start_x,v.start_y=v.x+v.vx*(t+release_delay),v.y+v.vy*(t+release_delay)
      local ex,ey=v.start_x+v.vx*horizon,v.start_y+v.vy*horizon
      local x1,x2=floor((min(v.start_x,ex)-v.width*.5-half_x)/64),floor((max(v.start_x,ex)+v.width*.5+half_x)/64)
      local y1,y2=floor((min(v.start_y,ey)-v.height*.5-half_y)/64),floor((max(v.start_y,ey)+v.height*.5+half_y)/64)
      if (x2-x1+1)*(y2-y1+1)>128 then wide[#wide+1]=i
      else
        for x=x1,x2 do for y=y1,y2 do
          local k=cellKey(x,y);local list=hit_grid[k] or {};hit_grid[k]=list;list[#list+1]=i
        end end
      end
    end
  end
  local function claim(shot,x,y,damage,clock)
    local first,overlap=nil,false
    local function scan(list)
      for _,i in ipairs(list) do
        local v=targets[i]
        if v.health>0 then
        stats.c1_hit_tests=stats.c1_hit_tests+1
        -- AABB size includes the actual enemy hitbox. Ambiguous simultaneous
        -- contacts consume a non-piercing card without guessing slot order.
          if abs(v.start_x+v.vx*clock-x)<(shot.width+v.width)*.5 and
              abs(v.start_y+v.vy*clock-y)<(shot.height+v.height)*.5 then
            if first then overlap=true;return else first=i end
          end
        end
      end
    end
    local list=hit_grid[cellKey(floor(x/64),floor(y/64))]
    if list then scan(list) end
    if not overlap then scan(wide) end
    if first and not overlap then damage[first]=(damage[first] or 0)+shot.damage;hits=hits+1 end
    return first~=nil
  end
  local function applyDamage(damage,clock)
    for i,amount in pairs(damage) do
      local v=targets[i]
      if v.damageable then
        v.health=v.health-floor(amount/v.divisor)
        if v.health<=0 and v.seed then
          seeds[v.id]=release_delay+clock;last_kill=max(last_kill,release_delay+clock)
        end
      end
    end
  end
  -- Already spawned custom cards are known only at their current AABB.
  -- Do not extrapolate their velocity or count another hit after consumption.
  if actual and t==0 then
    local damage={}
    for _,s in ipairs(models.active) do
      if s.type==0 and s.supported==true then claim(s,s.x,s.y,damage,0) end
    end
    applyDamage(damage,0)
  end
  if models.remaining_only then return valid,seeds,hits,last_kill end
  for clock=0,horizon do
    local damage={}
    for _,s in ipairs(projectiles) do
      if s.alive and clock>=s.delay then
        if claim(s,s.x,s.y,damage,clock) then s.alive=false end
      end
    end
    applyDamage(damage,clock)
    for _,s in ipairs(projectiles) do
      if s.alive and clock>=s.delay then
        local age=clock-s.delay
        if age>=40 then
          local vx,vy=s.vx,s.vy
          if goal then
            -- Once the retained target dies, do not manufacture retargets.
            if goal.health<=0 then s.alive=false end
            local dt=t+release_delay+clock
            local dx,dy=goal.x+goal.vx*dt-s.x,goal.y+goal.vy*dt-s.y
            local d=sqrt(dx*dx+dy*dy)
            local divisor=max(1,d/(max(.001,s.speed)*.25))
            vx,vy=vx+dx/divisor,vy+dy/divisor
            local speed=sqrt(vx*vx+vy*vy)
            s.speed=max(1,min(10,speed))
            if speed>1e-9 then s.vx,s.vy=vx*s.speed/speed,vy*s.speed/speed end
          else
            if s.speed<10 then s.speed=s.speed+1/3 end
            local speed=sqrt(vx*vx+vy*vy)
            if speed>1e-9 then s.vx,s.vy=vx*s.speed/speed,vy*s.speed/speed end
          end
        end
        s.x,s.y=s.x+s.vx,s.y+s.vy
      end
    end
  end
  return valid,seeds,hits,last_kill
end

-- Value each funded seed where its cards are predicted to kill it, not where
-- the target/whites were when Z was pressed. Only original component members
-- may relay; drifting new arrivals cannot bridge the original chain. Resource
-- propagation/radius remains a heuristic, not an engine blast simulation.
local function reimuImpactResources(kills,nodes,indexes,original,bullets,p,c,state,stats,offset,originals)
  local out={enemies=0,fairies=0,spirits=0,activated=0,bullets=0,score=0,ids={},id_set={},bullet_ids={},seed_ids={}}
  local ordered={}
  for id,delay in pairs(kills) do ordered[#ordered+1]={id=id,delay=delay} end
  table.sort(ordered,function(a,b) return a.delay<b.delay or a.delay==b.delay and tostring(a.id)<tostring(b.id) end)
  for _,event in ipairs(ordered) do
    local id,delay=event.id,event.delay
    local seed=indexes[id]
    local group=seed and original[seed]
    if group and not out.id_set[id] and (not originals or originals[id]) and c2LockAllows(state,nodes[seed],group) then
      local time=offset+delay
      local retained,ri={},{}
      for _,member in ipairs(group.ids) do
        -- Members consumed by an earlier modeled explosion cannot explode
        -- again at a later card hit to collect newly arriving white bullets.
        if not out.id_set[member] and (not originals or originals[member]) then
          local node=nodes[indexes[member]]
          retained[#retained+1]=node;ri[member]=#retained
        end
      end
      local projected=components(retained,time,{},p,c,stats,nil,nil,true)
      local impact=projected[ri[id]]
      if impact then
        out.seed_ids[#out.seed_ids+1]=id
        local cells={}
        for _,member in ipairs(impact.ids) do
          local node=nodes[indexes[member]]
          addTimingCells(cells,node,time,c,stats)
          if not out.id_set[member] then
            out.id_set[member]=true;out.ids[#out.ids+1]=member;out.enemies=out.enemies+1
            local kind=node.activated and 'activated' or node.spirit and 'spirits' or 'fairies'
            out[kind]=out[kind]+1
            out.score=out.score+(node.activated and c.activated_weight or node.spirit and c.spirit_weight or c.enemy_weight)
          end
        end
        for i,b in ipairs(bullets) do
          stats.timing_bullet_tests=stats.timing_bullet_tests+1
          -- Missing velocity cannot promise that a white will stay until impact.
          if not out.bullet_ids[i] and (time==0 or b.velocity_known) then
            local x,y=position(b,time)
            if inField(x,y) and cells[cellKey(floor(x/c.grid_size),floor(y/c.grid_size))] then
              out.bullet_ids[i]=true;out.bullets=out.bullets+1
            end
          end
        end
      end
    end
  end
  out.score=out.score+min(out.bullets,c.bullet_score_cap)*c.bullet_weight
  return out
end
local function reimuImpactTiming(current,later,c)
  local out=emptyTiming(c.prediction_frames)
  out.valid,out.at_impact=current.enemies>0,true
  out.current_bullets,out.future_bullets=current.bullets,later.bullets
  for i in pairs(current.bullet_ids) do if not later.bullet_ids[i] then out.leaving_bullets=out.leaving_bullets+1 end end
  for i in pairs(later.bullet_ids) do if not current.bullet_ids[i] then out.arriving_bullets=out.arriving_bullets+1 end end
  out.urgency=out.leaving_bullets>0
  out.improving=out.future_bullets-out.current_bullets>=c.timing_min_gain and
    out.future_bullets>=out.current_bullets*c.timing_gain_ratio
  return out
end

local function assessC1(nodes,indexes,now,future,grid,future_grid,bullets,p,c,state,stats,capture,candidates,enemies)
  local models=c1Models(p.sensor,c,p.character==0)
  local function assess(centre,actual)
    local out=emptyC1()
    out.valid,out.model_limited=models.valid,models.limited
    out.action_active,out.remaining_only=models.action_active,models.remaining_only==true
    out.target_x,out.target_y=centre.x,centre.y
    out.active_hit_count,out.pending_hit_count=0,0
    out.profile='native-sht-selector1-and-current-aabb'
    if not models.valid then return out end
    stats.c1_position_evaluations=stats.c1_position_evaluations+1
    if models.reimu then
      local valid,kills,hits,kill_time=reimuDamageSeeds(enemies,centre,models,p,c,stats,0,actual)
      out.damage_model_valid,out.kill_count,out.contact_count=valid,0,hits
      out.kill_delay,out.profile=kill_time,'reimu-c1-hp-and-retained-homing-target'
      local later_valid,later_kills=reimuDamageSeeds(enemies,centre,models,p,c,stats,c.prediction_frames,false)
      -- Both alternatives retain the same original component, projected to
      -- their respective hit times. Already spawned cards are never replayed.
      local current=reimuImpactResources(kills,nodes,indexes,now,bullets,p,c,state,stats,0)
      local later=reimuImpactResources(later_valid and later_kills or {},nodes,indexes,now,bullets,p,c,state,stats,c.prediction_frames,current.id_set)
      out.seed_ids,out.kill_count=current.seed_ids,#current.seed_ids
      out.has_ignition,out.hit_count=valid and out.kill_count>0,hits
      out.chain_ids,out.chain_enemies,out.chain_fairies,out.chain_spirits,out.chain_activated=current.ids,current.enemies,current.fairies,current.spirits,current.activated
      out.chain_score,out.chain_bullets=current.score,current.bullets
      out.future_has_ignition,out.future_score,out.future_bullets=later.enemies>0,later.score,later.bullets
      out.future_enemies,out.future_fairies,out.future_spirits,out.future_activated=later.enemies,later.fairies,later.spirits,later.activated
      out.value=max(current.score,later.score*c.future_discount)
      if actual then out.timing=reimuImpactTiming(current,later,c) end
      return out
    end
    local groups,seeds,claims={}, {}, {}
    local function take(i,active)
      groups[now[i]],seeds[i]=true,true
      out.seed_ids[#out.seed_ids+1]=nodes[i].id
      if active then out.active_hit_count=out.active_hit_count+1
      else out.pending_hit_count=out.pending_hit_count+1 end
    end
    for i,node in ipairs(nodes) do
      if now[i] then
        local hit,active,shot,contact=c1Hit(node,centre,models,0,stats,actual)
        if hit then
          if shot.piercing==true or shot.type==2 or shot.type==3 then
            if c2LockAllows(state,node,now[i]) then take(i,active) end
          elseif not claims[shot] or contact<claims[shot].contact then claims[shot]={i=i,active=active,contact=contact} end
        end
      end
    end
    for _,claim in pairs(claims) do
      if c2LockAllows(state,nodes[claim.i],now[claim.i]) then take(claim.i,claim.active) end
    end
    local current=unionResources(groups,nodes,indexes,grid,c,nil,0,stats)
    local later_groups,later_claims={},{}
    for i,node in ipairs(nodes) do
      if future[i] then
        -- Already spawned custom-motion shots support only current geometry.
        local hit,_,shot,contact=c1Hit(node,centre,models,c.prediction_frames,stats,false)
        if hit then
          if shot.piercing then
            if seeds[i] then later_groups[future[i]]=true end
          elseif not later_claims[shot] or contact<later_claims[shot].contact then later_claims[shot]={i=i,contact=contact} end
        end
      end
    end
    for _,claim in pairs(later_claims) do
      if seeds[claim.i] then later_groups[future[claim.i]]=true end
    end
    local later=unionResources(later_groups,nodes,indexes,future_grid,c,current.id_set,c.prediction_frames,stats)
    out.has_ignition,out.hit_count=current.enemies>0,#out.seed_ids
    out.chain_ids,out.chain_enemies,out.chain_fairies,out.chain_spirits,out.chain_activated=current.ids,current.enemies,current.fairies,current.spirits,current.activated
    out.chain_score,out.chain_bullets=current.score,current.bullets
    out.future_has_ignition,out.future_score,out.future_bullets=later.enemies>0,later.score,later.bullets
    out.future_enemies,out.future_fairies,out.future_spirits,out.future_activated=later.enemies,later.fairies,later.spirits,later.activated
    out.value=max(current.score,later.score*c.future_discount)
    if actual then out.timing=c1UnionTiming(current,later,bullets,c,stats) end
    return out
  end
  local actual=assess(p,true)
  local preferred=emptyC1()
  if not models.valid then return actual,preferred end
  local seen,best,count={},nil,0
  local function consider(x)
    x=max(-c.release_side_limit,min(c.release_side_limit,x))
    if seen[x] or count>=c.c1_max_positions then return end
    seen[x]=true;count=count+1
    local a=x==p.x and actual or assess({x=x,y=p.y},false)
    if a.has_ignition then
      local travel=abs(x-p.x)
      local value=a.value-c.travel_weight*travel
      if not best or value>best.value then best={a=a,value=value,travel=travel} end
    end
    return a
  end
  -- Current edge positions remain exact, while proposed positions use margins.
  seen[p.x]=true;count=1
  if actual.has_ignition then best={a=actual,value=actual.value,travel=0} end
  state.bloom_observer_c1_tick=(state.bloom_observer_c1_tick or 0)+1
  local tick=state.bloom_observer_c1_tick
  local cache=state.bloom_observer_c1_x
  local full=not coordinate(cache) or tick-(state.bloom_observer_c1_search_tick or -30)>=c.position_search_interval
  if not full then
    local cached=cache==p.x and actual or consider(cache)
    if not cached or not cached.has_ignition then full=true end
  end
  if full then
    if capture.has_target then consider(capture.target_x) end
    for _,candidate in ipairs(candidates) do if candidate.has_ignition then consider(candidate.x) end end
    state.bloom_observer_c1_search_tick=tick
  end
  state.bloom_observer_c1_x=best and best.a.target_x or nil
  if best then
    for key,value in pairs(best.a) do preferred[key]=value end
    preferred.value,preferred.travel_distance=best.value,best.travel
    preferred.at_target=best.travel<=c.release_tolerance
    preferred.improvement=actual.has_ignition and best.value-actual.value or nil
  end
  preferred.candidate_count=count
  preferred.full_search=full
  return actual,preferred
end

local function followupPosition(result,p,c)
  local capture,c1=result.capture,result.c1
  capture.preferred_before_c1 = capture.preferred
  if capture.preferred and c1.valid and c1.has_ignition and (c1.value or 0)>=capture.value then
    capture.preferred=false
  end
  local chosen,kind
  if capture.has_target then chosen,kind=capture,'capture' end
  local position=result.c1_position
  if position.valid and position.has_ignition and (not chosen or position.value>chosen.value) then
    chosen,kind=position,'c1'
  end
  local out=result.followup
  out.has_target=chosen~=nil
  if not chosen then return end
  out.kind,out.target_x,out.target_y,out.value=kind,chosen.target_x,chosen.target_y,chosen.value
  local sensor=p.sensor or {}
  local speed=finite(p.speedFast) and p.speedFast or 0
  local scale=finite(sensor.timeScale) and max(0,min(1,sensor.timeScale)) or 1
  local sx=finite(sensor.moveScaleX) and sensor.moveScaleX or 0
  local sy=finite(sensor.moveScaleY) and sensor.moveScaleY or 0
  local function travel(x,y)
    if speed<=0 or scale<=0 or sx<=0 or sy<=0 then return nil end
    -- Axis-wise lower bound with current poison multipliers, not a safe-route
    -- promise; dodge still handles future clouds/EX/lasers and protection end.
    return max(abs(chosen.target_x-x)/(speed*sx*scale),abs(chosen.target_y-y)/(speed*sy*scale))
  end
  out.travel_updates=travel(p.x,p.y)
  out.travel_timer=out.travel_updates and out.travel_updates*scale or nil
  out.path_verified=false
  local actual,suggested=result.c2,result.c2_position
  out.joint_compared=false
  if not out.travel_updates or not actual.has_ignition or not suggested.has_ignition or p.y<c.release_min_y then return end
  local next_travel=travel(suggested.target_x,suggested.target_y)
  if not next_travel then return end
  -- Compare only the already assessed actual point and existing best C2 site.
  -- Never replace it with an unassessed capture point or borrow capture yield
  -- into actual chain_score / chain_bullets.
  local actual_value=positionMerit(actual,c)
  local a=actual_value-c.followup_travel_weight*out.travel_updates
  local b=suggested.value-c.followup_travel_weight*next_travel
  out.joint_compared,out.current_joint_value,out.suggested_joint_value=true,a,b
  if a>b then
    local selected={}
    for k,v in pairs(actual) do selected[k]=v end
    selected.value,selected.current_value,selected.improvement=actual_value,actual_value,0
    selected.travel_distance,selected.at_target=0,true
    selected.candidate_count=suggested.candidate_count
    result.c2_position=selected
    suggested=selected
  end
  suggested.joint_value=max(a,b)
  suggested.followup_travel_updates=a>b and out.travel_updates or next_travel
end

-- has_target includes a focus-only spirit target; has_ignition requires an
-- ordinary enemy / activated spirit. ignition_* is nil without that trigger.
-- counts are CURRENT near-field counts, spirits means UNACTIVATED spirits.
-- chain_enemies includes ALL propagation nodes; chain_spirits separates its
-- unactivated spirits. chain_ids lists every current propagation node's ID.
-- chain_* and future_* always describe the SAME selected ignition node, even
-- if it joins a different component later. Future motion assumes no kills,
-- spawns, activation or velocity changes. future_score is not predicted energy.
-- future_aligned compares the predicted resource to the CURRENT player x;
-- it is not a promise that the player can safely remain there or reach it.
-- target_* is a preferred PLAYER coordinate below that target, while ignition_*
-- and focus_* are RESOURCE coordinates. focus_value is opportunity, never proof
-- that a character's actual field intersects the spirit.
-- Optional state.lock_ids is a set of ORIGINAL chain IDs (ID => true). While
-- set, only a CURRENT component containing an original node is eligible. A
-- pure spirit group can retain a focus target, but never ordinary ignition.
-- A surviving original spirit can link a new ignition enemy into the
-- same chain; an unrelated replacement chain cannot satisfy this lock. Empty
-- or malformed sets permit no ignition; nil unlocks. The caller must not replace
-- this set with each frame's chain_ids, or the lock would migrate to new nodes.
-- The legacy state.bloom_observer_lock_id selects one exact ignition ID, only
-- when lock_ids is nil. The caller owns clearing either lock.
-- c2 is a separate common-wave assessment: any fairy/spirit can be a seed,
-- regardless of ordinary-shot activation/alignment. Its resource score uses
-- ONLY bullets whose complete predicted 48-update path avoids the fixed
-- radius-192 exclusion envelope. This deliberately undercounts chain blasts
-- that might beat the C2 wave inside that envelope; no race is simulated.
-- Circle growth/contact is statically grounded; chain distances, enemy kills,
-- motion forecasts and energy/return yield remain estimates, not guarantees.
-- c2 always describes release at the ACTUAL current player centre. C2 graphs
-- cover the full field, including high chains and bullets below the player.
-- c2_position is a separate preferred release centre among <=9 legal sites; it
-- has the same yield fields plus value/current_value/improvement, travel_distance,
-- at_target and candidate_count. It predicts no safe path or arrival time.
-- Missing current ignition makes current_value/improvement nil. With no legal
-- ignition site, has_ignition=false and target coordinates remain nil. A caller
-- must not turn this preference or at_target into a new cadence/release gate.
-- Full position search runs every position_search_interval observations; between
-- searches only coordinates are reused. Actual/cached-site yields and locks are
-- evaluated anew. Failed eligibility/config changes can trigger an earlier search.
-- timing tracks white-bullet IDs overlapping the selected ORIGINAL node set at
-- now/the forecast sample. urgency means some current overlap is lost, not a
-- damage/death prediction. C2 timing counts only net resources at the actual
-- release centre. earliest_exit_frames is normally nil; its single-node case is
-- a constant-velocity exit from the heuristic circle, never blast arrival time.
-- capture independently values unactivated-spirit clusters, including their
-- white-bullet overlap and retained-original future resources. preferred compares
-- ordinary and actual C1 opportunities; target coordinates are an approach, not
-- proof that a character's real focus field or a safe path reaches the spirits.
-- c1/c1_position separate actual coverage from <=4 lateral sites. Native generic
-- supported SHT shots use fixed-axis full-width/full-height rectangles; unknown
-- callbacks never acquire invented beam/circle geometry. Existing C1 objects use
-- supported damage-ready CURRENT AABBs only. Active/lingering type-1 actions set
-- remaining_only and cannot replay the full template as a fresh C1 budget.
-- Potential contact is not enemy death, return or energy; HP is not exported.
-- Non-piercing templates select their first predicted ordinary ignition target.
-- C1 sites cache only coordinates at the existing search cadence, not resources.
-- Actual listed type-1 common waves exclude potentially directly swallowed
-- resources from ALL chain budgets. Their fixed centres and update-count life
-- are independent from protectionFrames. No threat object is removed from dodge.
-- followup compares only the already assessed actual/best C2 centres using a
-- small current-poison travel cost; actual C2 yield is never augmented. This
-- finite two-point preference is not a complete future attack/path simulation.
function M.observe(game_side, state, cfg)
  local c, result = settings(cfg), {
    valid = false, counts = { fairies = 0, spirits = 0, activated = 0, erasable = 0 },
    chain_score = 0, chain_enemies = 0, chain_fairies = 0, chain_spirits = 0, chain_activated = 0, chain_bullets = 0,
    future_score = 0, future_enemies = 0, future_fairies = 0, future_spirits = 0, future_activated = 0, future_bullets = 0,
    chain_ids = {}, focus_chain_ids = {}, chain_activated_gain = 0,
    timing = emptyTiming(),
    capture = emptyCapture(),c1 = emptyC1(),c1_position = emptyC1(),
    followup = {common_waves_valid=false,common_wave_count=0,excluded_bullets=0},
    c2 = emptyC2(),
    c2_position = emptyC2(),
    activated_gain = 0,
    focus_value = 0, focus_spirits = 0, has_target = false, has_ignition = false,
    ignition_aligned = false, future_has_ignition = false, future_aligned = false, candidates = {},
    stats = { enemies_seen = 0, bullets_seen = 0, invalid_objects = 0,
      enemy_pair_tests = 0, focus_pair_tests = 0, grid_queries = 0, truncated = false,
      c2_enemy_pair_tests = 0, c2_grid_queries = 0, c2_bullet_tests = 0, c2_position_candidates = 0,
      c2_position_evaluations = 0, c2_position_full_search = false,
      timing_bullet_tests=0,timing_grid_queries=0,common_wave_tests=0,
      c1_hit_tests=0,c1_position_evaluations=0 },
  }
  state = type(state) == "table" and state or {}
  local p = type(game_side) == "table" and game_side.player
  result.window_frames = c.prediction_frames
  result.timing.window_frames,result.c2.timing.window_frames=c.prediction_frames,c.prediction_frames
  if type(p) ~= "table" or not coordinate(p.x) or not coordinate(p.y) then
    state.bloom_observer_target_id = nil
    state.bloom_observer_spirits = nil
    state.bloom_observer_c2_id = nil
    state.bloom_observer_position_x, state.bloom_observer_position_y = nil, nil
    return result
  end
  local stats, nodes, spirits, current_grid, future_grid = result.stats, {}, {}, {}, {}
  local waves,waves_valid=actualWaves(p.sensor)
  local wave_scale=type(p.sensor)=='table' and finite(p.sensor.timeScale) and max(0,min(1,p.sensor.timeScale)) or 1
  result.followup.common_waves_valid,result.followup.common_wave_count=waves_valid,#waves
  local c2_nodes, c2_bullets, c2_grid, c2_future_grid = {}, {}, {}, {}
  local timing_bullets,timing_seen,activated_ids={},{},{}
  local same_c2_view = true
  local old_spirits, new_spirits = state.bloom_observer_spirits or {}, {}
  local enemies = type(game_side.enemies) == "table" and game_side.enemies or {}
  local accepted = 0
  for i, e in ipairs(enemies) do
    stats.enemies_seen = stats.enemies_seen + 1
    local flags_valid = type(e) == "table"
    if flags_valid then
      for _, key in ipairs({ "isSpirit", "isActivatedSpirit", "isBoss", "isLily", "isPseudoEnemy" }) do
        if e[key] ~= nil and type(e[key]) ~= "boolean" then flags_valid = false; break end
      end
      if e.isActivatedSpirit and not e.isSpirit then flags_valid = false end
    end
    if flags_valid and validObject(e) then
      local excluded = e.isBoss or e.isLily or e.isPseudoEnemy
      if not excluded then
        local x, y = position(e, c.prediction_frames)
        local now, later = near(e.x, e.y, p, c), near(x, y, p, c)
        if now ~= inField(e.x,e.y) or later ~= inField(x,y) then same_c2_view = false end
        local spirit, activated = e.isSpirit == true, e.isActivatedSpirit == true
        local node = { id = stableId(e.id) and e.id or ("slot:" .. i), x = e.x, y = e.y,
          vx = e.vx or 0, vy = e.vy or 0, spirit = spirit, activated = activated,
          ignitable = not spirit or activated,velocity_known=finite(e.vx) and finite(e.vy) }
        if inField(e.x, e.y) or inField(x, y) then
          if #c2_nodes < c.max_enemies then c2_nodes[#c2_nodes + 1] = node
          else stats.truncated = true end
        end
        if now or later then
          if accepted >= c.max_enemies then stats.truncated = true else
            accepted = accepted + 1
            if spirit and stableId(e.id) then
              new_spirits[e.id] = activated
              -- Only an observed ID transition counts. Newly arriving already
              -- activated spirits do not prove that our focus action worked.
              if now and activated and old_spirits[e.id] == false then
                result.activated_gain = result.activated_gain + 1
                activated_ids[e.id]=true
              end
            end
            nodes[#nodes + 1] = node
            if now then
              local kind = activated and "activated" or (spirit and "spirits" or "fairies")
              result.counts[kind] = result.counts[kind] + 1
              if spirit and not activated then spirits[#spirits + 1] = node end
            end
          end
        end
      end
    else stats.invalid_objects = stats.invalid_objects + 1 end
  end
  local bullets = type(game_side.bullets) == "table" and game_side.bullets or {}
  for _, b in ipairs(bullets) do
    stats.bullets_seen = stats.bullets_seen + 1
    if validObject(b) then
      if b.isErasable == true then
        local excluded=actualWaveExcludes(b,waves,wave_scale,stats)
        if excluded then
          result.followup.excluded_bullets=result.followup.excluded_bullets+1
          if near(b.x,b.y,p,c) then result.counts.erasable=result.counts.erasable+1 end
        else
        local near_now=near(b.x,b.y,p,c)
        if near_now then
          result.counts.erasable = result.counts.erasable + 1
          addBullet(current_grid, b.x, b.y, c.grid_size)
        end
        local x, y = position(b, c.prediction_frames)
        local near_later=near(x,y,p,c)
        if near_later then
          addBullet(future_grid, x, y, c.grid_size)
        end
        local now, later = inField(b.x, b.y), inField(x, y)
        if now ~= near_now or later ~= near_later then same_c2_view = false end
        if now then addBullet(c2_grid, b.x, b.y, c.grid_size) end
        if later then addBullet(c2_future_grid, x, y, c.grid_size) end
        if now or later or near_now or near_later then
          local sx,sy = (b.vx or 0)*M.c2_wave.sweep_updates,(b.vy or 0)*M.c2_wave.sweep_updates
          local length2 = sx*sx+sy*sy
          local record={ x=b.x,y=b.y,fx=x,fy=y,sx=sx,sy=sy,vx=b.vx or 0,vy=b.vy or 0,
            inverse_length2=length2>0 and 1/length2 or 0,now=now,later=later,
            near_now=near_now,near_later=near_later,velocity_known=finite(b.vx) and finite(b.vy),
            now_key=cellKey(floor(b.x/c.grid_size),floor(b.y/c.grid_size)),
            future_key=cellKey(floor(x/c.grid_size),floor(y/c.grid_size)) }
          if now or later then c2_bullets[#c2_bullets+1]=record end
          -- Native IDs are stable and unique. Defensive duplicates use the first
          -- valid sample; ID-less fixtures are distinct current-array slots.
          if not stableId(b.id) or not timing_seen[b.id] then
            timing_bullets[#timing_bullets+1]=record
            if stableId(b.id) then timing_seen[b.id]=true end
          end
        end
        end
      end
    else stats.invalid_objects = stats.invalid_objects + 1 end
  end
  local now, now_groups = components(nodes, 0, current_grid, p, c, stats, state.lock_ids)
  local future, future_groups = components(nodes, c.prediction_frames, future_grid, p, c, stats, nil)
  local c2_stats = { enemy_pair_tests=0,grid_queries=0 }
  local c2_now, c2_groups, c2_future, c2_future_groups
  if same_c2_view then
    c2_now, c2_groups, c2_future, c2_future_groups = now, now_groups, future, future_groups
  else
    c2_now, c2_groups = components(c2_nodes, 0, c2_grid, p, c, c2_stats, state.lock_ids, nil, true)
    c2_future, c2_future_groups = components(c2_nodes, c.prediction_frames, c2_future_grid, p, c, c2_stats, nil, nil, true)
  end
  stats.c2_enemy_pair_tests, stats.c2_grid_queries = c2_stats.enemy_pair_tests, c2_stats.grid_queries
  result.c2, result.c2_position = assessPositions(c2_nodes, c2_bullets, c2_now, c2_future,
    c2_groups, c2_future_groups, p, c, state, stats)
  local indexes,c2_indexes=nodeIndexes(nodes),nodeIndexes(c2_nodes)
  if result.c2.has_ignition then
    result.c2.timing=chainTiming(c2_indexes[result.c2.seed_id],c2_nodes,c2_indexes,c2_now,c2_future,
      timing_bullets,p,c,state,stats,true,result.c2.future_has_ignition)
  end
  local candidates, best = {}, nil
  local shootable_groups={}
  local empty = { score = 0, enemies = 0, fairies = 0, spirits = 0, activated = 0, bullets = 0, ids = {} }
  for i, node in ipairs(nodes) do
    if node.ignitable then
    if now[i] then shootable_groups[now[i]]=true end
    local current, predicted = now[i] or empty, future[i] or empty
    local fx, fy = position(node, c.prediction_frames)
    local target_x, target_y = node.x, node.y
    if not now[i] then target_x, target_y = fx, fy end
    local focus, focus_x, focus_y, focus_count = spiritPotential(spirits, target_x, target_y, c, stats)
    local candidate = { id = node.id, x = target_x, y = target_y,
      chain_score = current.score, chain_enemies = current.enemies, chain_bullets = current.bullets,
      chain_fairies = current.fairies, chain_spirits = current.spirits, chain_activated = current.activated,
      chain_ids = current.ids, focus_chain_ids=current.ids,lock_match = current.lock_match == true,
      future_score = predicted.score, future_enemies = predicted.enemies, future_bullets = predicted.bullets,
      future_fairies = predicted.fairies, future_spirits = predicted.spirits, future_activated = predicted.activated,
      focus_value = focus, focus_x = focus_x, focus_y = focus_y, focus_spirits = focus_count,
      has_ignition = now[i] ~= nil, future_has_ignition = future[i] ~= nil, future_x = fx, future_y = fy }
    candidate.value = max(current.score, predicted.score * c.future_discount) + focus * c.focus_weight
      - (abs(target_x - p.x) + abs(target_y + c.target_below - p.y)) * c.distance_weight
      + (state.bloom_observer_target_id == node.id and c.continuity_bonus or 0)
    candidates[#candidates + 1] = candidate
    end
  end
  -- A scene containing only unactivated spirits still provides a selective
  -- capture opportunity. It does not masquerade as an already ignitable chain.
    for _, s in ipairs(spirits) do
      local group=now[indexes[s.id]]
      if group and not shootable_groups[group] then
      local value, fx, fy, count = spiritPotential(spirits, s.x, s.y, c, stats)
      candidates[#candidates + 1] = { id = s.id, x = s.x, y = s.y,
        value = value * c.focus_weight - abs(s.x - p.x) * c.distance_weight,
        chain_score = 0, chain_enemies = 0, chain_fairies = 0, chain_spirits = 0, chain_activated = 0, chain_bullets = 0,
        future_score = 0, future_enemies = 0, future_fairies = 0, future_spirits = 0, future_activated = 0, future_bullets = 0,
        chain_ids = {},focus_chain_ids=group.ids,lock_match=group.lock_match==true,
        focus_value = value, focus_x = fx, focus_y = fy, focus_spirits = count,
        has_ignition = false, future_has_ignition = false }
      end
  end
  table.sort(candidates, function(a, b)
    if a.value ~= b.value then return a.value > b.value end
    if a.x ~= b.x then return a.x < b.x end
    if a.y ~= b.y then return a.y > b.y end
    return tostring(a.id) < tostring(b.id)
  end)
  best = candidates[1]
  if state.lock_ids ~= nil then
    best = nil
    for _, candidate in ipairs(candidates) do
      if candidate.lock_match then best = candidate; break end
    end
  elseif state.bloom_observer_lock_id ~= nil then
    best = nil
    for _, candidate in ipairs(candidates) do
      if candidate.id == state.bloom_observer_lock_id then best = candidate; break end
    end
  end
  for i = 1, min(#candidates, c.max_candidates) do result.candidates[i] = candidates[i] end
  result.valid = true
  if best then
    result.has_target, result.has_ignition = true, best.has_ignition
    result.future_has_ignition = best.future_has_ignition
    for _, key in ipairs({ "chain_score", "chain_enemies", "chain_fairies", "chain_spirits", "chain_activated", "chain_bullets", "chain_ids", "focus_chain_ids", "future_score",
      "future_enemies", "future_fairies", "future_spirits", "future_activated", "future_bullets", "focus_value", "focus_x", "focus_y", "focus_spirits" }) do
      result[key] = best[key]
    end
    result.target_x, result.target_y = best.x, best.y + c.target_below
    result.target_id = best.id
    result.timing=chainTiming(indexes[best.id],nodes,indexes,now,future,timing_bullets,p,c,state,stats,false)
    for _,id in ipairs(best.focus_chain_ids) do
      if activated_ids[id] and (state.lock_ids==nil or
          (type(state.lock_ids)=='table' and state.lock_ids[id]==true)) then
        result.chain_activated_gain=result.chain_activated_gain+1
      end
    end
    if best.has_ignition then
      result.ignition_id, result.ignition_x, result.ignition_y = best.id, best.x, best.y
      result.ignition_aligned = abs(best.x - p.x) <= c.alignment_width and best.y < p.y
    end
    if best.future_has_ignition then
      result.future_ignition_x, result.future_ignition_y = best.future_x, best.future_y
      result.future_target_x, result.future_target_y = best.future_x, best.future_y + c.target_below
      result.future_aligned = abs(best.future_x - p.x) <= c.alignment_width and best.future_y < p.y
    end
    state.bloom_observer_target_id = best.id
  else state.bloom_observer_target_id = nil end
  result.capture=assessCapture(nodes,spirits,indexes,now,future,future_grid,timing_bullets,
    p,c,state,stats,activated_ids,best)
  result.c1,result.c1_position=assessC1(c2_nodes,c2_indexes,c2_now,c2_future,c2_grid,c2_future_grid,
    timing_bullets,p,c,state,stats,result.capture,candidates,enemies)
  followupPosition(result,p,c)
  state.bloom_observer_spirits = new_spirits
  return result
end

return M
