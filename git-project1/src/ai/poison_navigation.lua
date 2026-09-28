-- Bounded terrain guidance only. Bullet/laser safety remains dodge.lua's
-- short-horizon continuous collision test; these rays are NOT safe routes.
local abs, min, max, sqrt = math.abs, math.min, math.max, math.sqrt
local RADIUS, STEP, LOOKAHEAD, BUFFER = 128, 16, 48, 12
local RAYS = {}
for index = 0, 15 do
  local angle = index * math.pi / 8
  RAYS[#RAYS + 1] = { math.cos(angle), math.sin(angle) }
end
local function finite(x) return type(x) == "number" and x == x and abs(x) < math.huge end
local function clamp(x, lo, hi) return max(lo, min(hi, x)) end
local function setting(cfg, key, default, lo, hi)
  local value = cfg[key]
  return finite(value) and clamp(value, lo, hi) or default
end

local function cloudsNear(player)
  local clouds = {}
  for _, raw in ipairs(player.sensor.poisonClouds or {}) do
    if finite(raw.x) and finite(raw.y) and finite(raw.radius) and raw.radius > 0
      and finite(raw.framesLeft) and raw.framesLeft > 0 then
      local active = finite(raw.age) and max(0, 21 - raw.age)
        or (raw.active == false and math.huge or 0)
      if active < LOOKAHEAD and active < raw.framesLeft
        and abs(raw.x - player.x) <= RADIUS + raw.radius + BUFFER
        and abs(raw.y - player.y) <= RADIUS + raw.radius + BUFFER then
        clouds[#clouds + 1] = { x = raw.x, y = raw.y, radius = raw.radius,
          active = active, expires = raw.framesLeft }
      end
    end
  end
  return clouds
end

local function riskAt(x, y, time, clouds, stats)
  stats.poison_nav_samples = stats.poison_nav_samples + 1
  local dose, edge, level = 0, 0, 0
  for _, cloud in ipairs(clouds) do
    local remaining = cloud.expires - time
    if remaining > 0 then
      local delay = max(0, cloud.active - time)
      local weight = min(1, remaining / 60) * (delay == 0 and 1 or max(0, 1 - delay / LOOKAHEAD) * 0.5)
      local dx, dy = x - cloud.x, y - cloud.y
      local distance2 = dx * dx + dy * dy
      if distance2 < (cloud.radius + BUFFER)^2 then
        local distance = sqrt(distance2)
        if distance < cloud.radius then
          dose = dose + weight
          if delay == 0 then level = level + 1 end
          -- A shallow depth term helps near the boundary. The remembered
          -- escape target supplies progress even at a flat concentric centre.
          edge = edge + weight * (0.25 + 0.25 * (1 - distance / cloud.radius))
        else
          edge = edge + weight * 0.25 * (1 - (distance - cloud.radius) / BUFFER)
        end
      end
    end
  end
  return dose * dose + edge, level
end

local function pointOn(candidate, time)
  for _, segment in ipairs(candidate.segments) do
    if time <= segment.start + segment.duration then
      local dt = max(0, time - segment.start)
      return segment.x + segment.vx * dt, segment.y + segment.vy * dt
    end
  end
  local last = candidate.segments[#candidate.segments]
  return last.x + last.vx * last.duration, last.y + last.vy * last.duration
end

local function routeScore(player, x, y, clouds, cfg, stats, initial)
  local dx, dy = x - player.x, y - player.y
  local distance = sqrt(dx * dx + dy * dy)
  if distance < 4 then return nil end
  local steps, total, peak, target_risk = min(8, max(1, math.ceil(distance / STEP))), 0, initial, initial
  local base_speed = max(0.5, max(player.speedFast, player.speedSlow)
    * min(player.sensor.baseScaleX or 1, player.sensor.baseScaleY or 1))
  for index = 1, steps do
    local fraction = index / steps
    -- Time is a bounded terrain look-ahead, not a claim of arrival time in
    -- stacked poison. The actual 12-frame candidate uses measured multipliers.
    local risk = riskAt(player.x + dx * fraction, player.y + dy * fraction,
      min(LOOKAHEAD, distance * fraction / base_speed), clouds, stats)
    total, peak, target_risk = total + risk, max(peak, risk), risk
  end
  local clearance = min(x - cfg.field.min_x, cfg.field.max_x - x,
    y - cfg.field.min_y, cfg.field.max_y - y)
  -- Penalize traversing denser poison, not merely the dose of the destination.
  return 8 * target_risk + 2 * total / steps + 8 * max(0, peak - initial)
    + distance / RADIUS * 0.4 + max(0, 16 - clearance) * 0.25, target_risk
end

local function chooseTarget(player, memory, clouds, cfg, stats, initial, frame)
  local best, best_score
  local base_speed = max(0.5, max(player.speedFast, player.speedSlow)
    * min(player.sensor.baseScaleX or 1, player.sensor.baseScaleY or 1))
  -- Reconsider the old target using today's clouds. A small hysteresis bonus
  -- keeps near-equivalent exits stable, but cannot preserve a newly toxic one.
  if memory and memory.target_x then
    local score, risk = routeScore(player, memory.target_x, memory.target_y, clouds, cfg, stats, initial)
    if score and risk < initial * 0.85 then
      best = { target_x = memory.target_x, target_y = memory.target_y }
      best_score = score - 0.75
    end
  end
  for _, ray in ipairs(RAYS) do
    local total, peak = 0, initial
    for step = 1, 8 do
      local distance = step * STEP
      local x, y = player.x + ray[1] * distance, player.y + ray[2] * distance
      -- Do not clamp a target behind a wall into an apparent zero-length exit.
      if x < cfg.field.min_x + 8 or x > cfg.field.max_x - 8
        or y < cfg.field.min_y + 8 or y > cfg.field.max_y - 8 then break end
      stats.poison_probe_count = stats.poison_probe_count + 1
      -- Reuse each ray's accumulated samples: at most 128 new probe points,
      -- not a separate path integration for every possible endpoint.
      local risk = riskAt(x, y, min(LOOKAHEAD, distance / base_speed), clouds, stats)
      total, peak = total + risk, max(peak, risk)
      local clearance = min(x - cfg.field.min_x, cfg.field.max_x - x,
        y - cfg.field.min_y, cfg.field.max_y - y)
      local score = 8 * risk + 2 * total / step + 8 * max(0, peak - initial)
        + distance / RADIUS * 0.4 + max(0, 16 - clearance) * 0.25
      if risk < initial * 0.85 and (not best_score or score < best_score) then
        best, best_score = { target_x = x, target_y = y }, score
      end
    end
  end
  best = best or {}
  best.plan_frame, best.plan_x, best.plan_y = frame, player.x, player.y
  return best
end

local function score(player, candidates, state, cfg, stats, frame)
  stats.poison_nav_active, stats.poison_level, stats.poison_risk = 0, 0, 0
  stats.poison_target_x, stats.poison_target_y = 0, 0
  stats.poison_probe_count, stats.poison_nav_samples = 0, 0
  for _, candidate in ipairs(candidates) do candidate.poison_cost = 0 end
  local options, sensor = cfg.poison_navigation, player.sensor
  if not options or options.enabled ~= true or type(sensor) ~= "table" or sensor.valid ~= true then
    state.poison_navigation = nil; return
  end
  local clouds = cloudsNear(player)
  if #clouds == 0 then state.poison_navigation = nil; return end
  local risk_weight = setting(options, "risk_weight", 80, 0, 1000)
  local progress_weight = setting(options, "progress_weight", 6, 0, 100)
  local replan = math.floor(setting(options, "replan_frames", 12, 1, 60))
  local initial, level = riskAt(player.x, player.y, 0, clouds, stats)
  stats.poison_level, stats.poison_risk = level, initial
  local future = riskAt(player.x, player.y, cfg.prediction_frames, clouds, stats)
  local memory = state.poison_navigation
  -- Do not chase a cloud that is about to vanish. Soft short-horizon exposure
  -- still discourages newly entering it, without commanding unnecessary trips.
  if future < 0.05 then
    memory = nil
  elseif not memory or frame < memory.plan_frame or frame - memory.plan_frame >= replan
    or (player.x - memory.plan_x)^2 + (player.y - memory.plan_y)^2 > 64 * 64 then
    memory = chooseTarget(player, memory, clouds, cfg, stats, max(initial, future), frame)
  end
  state.poison_navigation = memory
  local target_x, target_y = memory and memory.target_x, memory and memory.target_y
  local current_distance = target_x and sqrt((player.x - target_x)^2 + (player.y - target_y)^2) or 0
  if target_x then stats.poison_target_x, stats.poison_target_y = target_x, target_y end
  for _, candidate in ipairs(candidates) do
    local middle_x, middle_y = pointOn(candidate, cfg.prediction_frames * 0.5)
    local end_x, end_y = pointOn(candidate, cfg.prediction_frames)
    local middle = riskAt(middle_x, middle_y, cfg.prediction_frames * 0.5, clouds, stats)
    local ending = riskAt(end_x, end_y, cfg.prediction_frames, clouds, stats)
    candidate.poison_cost = risk_weight * (middle * 0.4 + ending * 0.6)
    if target_x then
      local distance = sqrt((end_x - target_x)^2 + (end_y - target_y)^2)
      candidate.poison_cost = candidate.poison_cost + progress_weight * (distance - current_distance)
    end
    if candidate.poison_cost ~= 0 then stats.poison_nav_active = 1 end
  end
end

return { score = score }
