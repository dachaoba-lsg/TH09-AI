local keys = dofile("keyutils.lua")
local abs, min, max, sqrt = math.abs, math.min, math.max, math.sqrt
local INF, DIAGONAL = math.huge, 1 / math.sqrt(2)
local DIRECTIONS = {
  {"right", 1, 0, keys.mask.right}, {"left", -1, 0, keys.mask.left},
  {"down", 0, 1, keys.mask.down}, {"up", 0, -1, keys.mask.up},
  {"down-right", 1, 1, keys.mask.down + keys.mask.right},
  {"down-left", -1, 1, keys.mask.down + keys.mask.left},
  {"up-right", 1, -1, keys.mask.up + keys.mask.right},
  {"up-left", -1, -1, keys.mask.up + keys.mask.left},
}
local function clamp(x, lo, hi) return max(lo, min(hi, x)) end
local function finite(x) return type(x) == "number" and x == x and abs(x) < INF end

local function copyTable(source)
  local out = {}
  for key, value in pairs(source) do out[key] = value end
  return out
end

local function circleVisible(player, x, y, object_radius, radius)
  if not finite(x) or not finite(y) or not finite(object_radius) then return false end
  local dx, dy, reach = x - player.x, y - player.y, radius + abs(object_radius)
  return dx * dx + dy * dy <= reach * reach
end

-- Sight uses the object's CURRENT physical shape, with no swept motion,
-- player hitbox expansion or dodge safety margin. A long beam is anchored at
-- one end ([0,width]), exactly as in collisionBounds and upstream hitTest.
local function objectVisible(player, object, radius)
  local body = object.hitBody
  if type(body) ~= "table" then return circleVisible(player, object.x, object.y, 0, radius) end
  local x, y = body.x or object.x, body.y or object.y
  if not finite(x) or not finite(y) then return false end
  if body.type == HitType.Circle then
    return circleVisible(player, x, y, body.radius or 0, radius)
  end
  local dx, dy = player.x - x, player.y - y
  if body.type == HitType.Rect or body.type == HitType.RotatableRect then
    local width, height = body.width or 0, body.height or 0
    if not finite(width) or not finite(height) then return false end
    local nearest_x, nearest_y
    if body.type == HitType.RotatableRect then
      local angle = body.angle or 0
      if not finite(angle) then return false end
      local c, s = math.cos(angle), math.sin(angle)
      dx, dy = c * dx + s * dy, -s * dx + c * dy
      nearest_x = clamp(dx, 0, max(0, width))
      nearest_y = clamp(dy, -abs(height) * 0.5, abs(height) * 0.5)
    else
      nearest_x = clamp(dx, -abs(width) * 0.5, abs(width) * 0.5)
      nearest_y = clamp(dy, -abs(height) * 0.5, abs(height) * 0.5)
    end
    dx, dy = dx - nearest_x, dy - nearest_y
    return dx * dx + dy * dy <= radius * radius
  end
  return dx * dx + dy * dy <= radius * radius
end

-- Shared by the resource observer and dodge planner. Objects retain their
-- original references/IDs; only lists, player and sensor tables are copied.
-- User settings always supply a finite 16..640 radius. Missing/zero radius is
-- retained only for explicit internal geometry baselines using raw configs.
local function perceive(game_side, cfg)
  local radius = cfg and cfg.vision_radius
  local enabled = radius ~= nil and radius ~= 0
  if enabled then radius = finite(radius) and radius > 0 and clamp(radius, 16, 640) or 448 / 3
  else radius = 0 end
  local diagnostics = { radius = radius, visible_count = 0, hidden_count = 0 }
  local player = game_side.player
  local visible = enabled and copyTable(game_side) or game_side
  for _, spec in ipairs({ { "enemies", "enemies" }, { "bullets", "bullets" },
      { "exAttacks", "ex" } }) do
    local list, filtered = game_side[spec[1]] or {}, {}
    local visible_count, hidden_count = 0, 0
    for _, object in ipairs(list) do
      if not enabled or objectVisible(player, object, radius) then
        visible_count = visible_count + 1
        if enabled then filtered[#filtered + 1] = object end
      else hidden_count = hidden_count + 1 end
    end
    if enabled then visible[spec[1]] = filtered end
    diagnostics["visible_" .. spec[2]], diagnostics["hidden_" .. spec[2]] = visible_count, hidden_count
    diagnostics.visible_count = diagnostics.visible_count + visible_count
    diagnostics.hidden_count = diagnostics.hidden_count + hidden_count
  end
  local clouds = type(player.sensor) == "table" and player.sensor.poisonClouds or {}
  local filtered_clouds, cloud_count, hidden_clouds = {}, 0, 0
  for _, cloud in ipairs(clouds or {}) do
    if not enabled or circleVisible(player, cloud.x, cloud.y, cloud.radius, radius) then
      cloud_count = cloud_count + 1
      if enabled then filtered_clouds[#filtered_clouds + 1] = cloud end
    else hidden_clouds = hidden_clouds + 1 end
  end
  diagnostics.visible_poison, diagnostics.hidden_poison = cloud_count, hidden_clouds
  diagnostics.visible_count = diagnostics.visible_count + cloud_count
  diagnostics.hidden_count = diagnostics.hidden_count + hidden_clouds
  if enabled then
    visible.player = copyTable(player)
    if type(player.sensor) == "table" then
      visible.player.sensor = copyTable(player.sensor)
      visible.player.sensor.poisonClouds = filtered_clouds
    end
  end
  return visible, diagnostics
end

local function medicine(object)
  return ExAttackType and ExAttackType.Medicine ~= nil and object.type == ExAttackType.Medicine
end

-- The native sensor supplies current effective movement and separately the
-- non-poison factors. Never divide an observed speed by a guessed cloud count:
-- that would double-apply poison or invent a speed-up at cloud boundaries.
local function movementModel(player, cfg, stats)
  local sensor = player.sensor
  if type(sensor) ~= "table" or sensor.valid ~= true then return nil end
  if not finite(sensor.moveScaleX) or not finite(sensor.moveScaleY)
    or not finite(sensor.baseScaleX) or not finite(sensor.baseScaleY)
    or sensor.moveScaleX < 0 or sensor.moveScaleY < 0
    or sensor.baseScaleX < 0 or sensor.baseScaleY < 0 then return nil end
  stats.sensor_valid = 1
  local model = { current_x = sensor.moveScaleX, current_y = sensor.moveScaleY,
    base_x = sensor.baseScaleX, base_y = sensor.baseScaleY, clouds = {} }
  local reach = max(player.speedFast, player.speedSlow) * cfg.prediction_frames
    * max(1, model.current_x, model.current_y, model.base_x, model.base_y)
  for _, cloud in ipairs(sensor.poisonClouds or {}) do
    if finite(cloud.x) and finite(cloud.y) and finite(cloud.radius) and cloud.radius > 0
      and finite(cloud.framesLeft) and cloud.framesLeft > 0
      and abs(cloud.x - player.x) <= reach + cloud.radius
      and abs(cloud.y - player.y) <= reach + cloud.radius then
      -- Raw cloud age gates poison independently of upstream hittable.
      -- A newly created cloud may become active inside this horizon.
      local active_from = finite(cloud.age) and max(0, 21 - cloud.age)
        or (cloud.active == false and INF or 0)
      if active_from < cfg.prediction_frames then
        model.clouds[#model.clouds + 1] = { x = cloud.x, y = cloud.y, radius = cloud.radius,
          framesLeft = cloud.framesLeft, activeFrom = active_from }
      end
    end
  end
  stats.poison_clouds = #model.clouds
  if sensor.state == 3 and finite(sensor.protectionFrames) and sensor.protectionFrames > 0 then
    -- The engine tests the integer timer and may decrement it before the next
    -- collision update. Floor before subtracting that one-update margin, so
    -- a raw value such as 1.5 cannot grant an extra half-update of protection.
    model.protected_until = max(0, math.floor(sensor.protectionFrames) - 1)
    stats.protection_frames = sensor.protectionFrames
  end
  -- No cloud and ordinary factors preserve the original <=3-segment path.
  model.dynamic = #model.clouds > 0 or model.current_x ~= model.base_x or model.current_y ~= model.base_y
  return model
end

-- Continuous relative motion, including fast objects between frame samples.
local function rectInterval(x, y, vx, vy, lo_x, hi_x, lo_y, hi_y, duration)
  local enter, leave = 0, duration
  if abs(vx) < 1e-9 then
    if x < lo_x or x > hi_x then return nil end
  else
    local a, b = (lo_x - x) / vx, (hi_x - x) / vx
    if a > b then a, b = b, a end
    enter, leave = max(enter, a), min(leave, b)
    if enter > leave then return nil end
  end
  if abs(vy) < 1e-9 then
    if y < lo_y or y > hi_y then return nil end
  else
    local a, b = (lo_y - y) / vy, (hi_y - y) / vy
    if a > b then a, b = b, a end
    enter, leave = max(enter, a), min(leave, b)
    if enter > leave then return nil end
  end
  return enter, leave
end

local function circleInterval(x, y, vx, vy, radius, duration)
  local a, c = vx * vx + vy * vy, x * x + y * y - radius * radius
  if a < 1e-12 then
    if c <= 0 then return 0, duration end
    return nil
  end
  local b = x * vx + y * vy
  local discriminant = b * b - a * c
  if discriminant < 0 then return nil end
  local root = sqrt(discriminant)
  local enter, leave = max(0, (-b - root) / a), min(duration, (-b + root) / a)
  if enter > leave then return nil end
  return enter, leave
end

-- Intersect four linear inequalities. Unlike the ordinary bullet slab test,
-- the far end and thickness may grow during the candidate trajectory.
local function changingRectInterval(x, y, vx, vy, half_x, half_y, length, length_rate, half_y_rate, duration)
  local enter, leave = 0, duration
  local function clip(offset, rate)
    if abs(rate) < 1e-9 then return offset >= 0 end
    local crossing = -offset / rate
    if rate > 0 then enter = max(enter, crossing) else leave = min(leave, crossing) end
    return enter <= leave
  end
  if not clip(x + half_x, vx) or not clip(length + half_x - x, length_rate - vx)
    or not clip(y + half_y, vy + half_y_rate) or not clip(half_y - y, half_y_rate - vy) then return nil end
  return enter, leave
end

-- Integrated urgency changes smoothly with position. Tangency has a small
-- nonzero cost so a route barely touching a hitbox is not considered safe.
local function exposure(enter, leave, start, horizon)
  if not enter then return 0 end
  local first, last = start + enter, start + leave
  return (last - first) * (1 - (first + last) / (2 * horizon))
    + 0.1 * max(0, 1 - first / horizon)
end

local function wallTime(p, v, lo, hi)
  if v > 0 then return max(0, (hi - p) / v) end
  if v < 0 then return max(0, (lo - p) / v) end
  return INF
end

local function appendSegment(candidate, start, duration, x, y, vx, vy)
  if duration <= 0 then return end
  local previous = candidate.segments[#candidate.segments]
  if previous and abs(previous.vx - vx) < 1e-12 and abs(previous.vy - vy) < 1e-12 then
    previous.duration = previous.duration + duration
  else
    candidate.segments[#candidate.segments + 1] = {
      start = start, duration = duration, x = x, y = y, vx = vx, vy = vy }
  end
end

local function cloudScales(model, x, y, time)
  if time == 0 then return model.current_x, model.current_y end
  local factor = 1
  for _, cloud in ipairs(model.clouds) do
    -- TH09 tests the player's centre, not an expanded damage hitbox. Overlap
    -- stacks per active cloud, but poison itself never inflicts a hit.
    if time >= cloud.activeFrom and time < cloud.framesLeft
      and (x - cloud.x)^2 + (y - cloud.y)^2 < cloud.radius^2 then
      factor = factor * 0.4
    end
  end
  return model.base_x * factor, model.base_y * factor
end

local function addCandidate(list, player, cfg, name, key, vx, vy, model)
  local h, f = cfg.prediction_frames, cfg.field
  local candidate = { name = name, key = key, vx = vx, vy = vy, danger = 0, collides = false, segments = {},
    focus = math.floor(key / keys.mask.shift) % 2 == 1 }
  if model and model.dynamic then
    local x, y, time, boundary = player.x, player.y, 0, false
    -- Only nearby poison uses simulation-sized movement steps. Equal-velocity
    -- steps merge, so a player deep inside a cloud still has one trajectory.
    -- At nondefault long horizons the work remains capped at twelve steps.
    local step = h / min(12, max(1, math.ceil(h)))
    while time < h - 1e-9 do
      local scale_x, scale_y = cloudScales(model, x, y, time)
      local dx, dy = vx * scale_x, vy * scale_y
      if time == 0 then candidate.vx, candidate.vy = dx, dy end
      local finish, start_x, start_y = min(h, time + step), x, y
      local tx, ty = wallTime(x, dx, f.min_x, f.max_x), wallTime(y, dy, f.min_y, f.max_y)
      local local_time = 0
      while local_time < finish - time do
        local ending = min(finish - time, tx > local_time and tx or INF, ty > local_time and ty or INF)
        local sx, sy = local_time >= tx and 0 or dx, local_time >= ty and 0 or dy
        appendSegment(candidate, time + local_time, ending - local_time, x, y, sx, sy)
        x, y = clamp(x + sx * (ending - local_time), f.min_x, f.max_x),
          clamp(y + sy * (ending - local_time), f.min_y, f.max_y)
        local_time = ending
      end
      if abs(start_x + dx * (finish - time) - x) > 1e-7
        or abs(start_y + dy * (finish - time) - y) > 1e-7 then boundary = true end
      time = finish
    end
    local distance = min(x - f.min_x, f.max_x - x, y - f.min_y, f.max_y - y)
    local cost = boundary and cfg.boundary_cost or 0
    if distance < cfg.wall_margin then cost = cost + (cfg.wall_margin - distance) * cfg.wall_cost end
    candidate.terminal_x, candidate.terminal_y, candidate.terrain_cost = x, y, cost
    candidate.position_cost = cost + ((x - cfg.preferred_x)^2 + (y - cfg.preferred_y)^2) * cfg.position_cost
      + (candidate.vx^2 + candidate.vy^2) * (cfg.movement_cost or 0.03)
    list[#list + 1] = candidate
    return
  end
  vx, vy = vx * (model and model.base_x or 1), vy * (model and model.base_y or 1)
  candidate.vx, candidate.vy = vx, vy
  local tx = wallTime(player.x, vx, f.min_x, f.max_x)
  local ty = wallTime(player.y, vy, f.min_y, f.max_y)
  local start = 0
  -- Once a coordinate meets the wall, only that component stops. Never score
  -- an impossible escape outside the playable field as a safe trajectory.
  while start < h do
    local finish = min(h, tx > start and tx or INF, ty > start and ty or INF)
    candidate.segments[#candidate.segments + 1] = {
      start = start, duration = finish - start,
      x = clamp(player.x + vx * start, f.min_x, f.max_x),
      y = clamp(player.y + vy * start, f.min_y, f.max_y),
      vx = start >= tx and 0 or vx, vy = start >= ty and 0 or vy,
    }
    start = finish
  end
  local raw_x, raw_y = player.x + vx * h, player.y + vy * h
  local x, y = clamp(raw_x, f.min_x, f.max_x), clamp(raw_y, f.min_y, f.max_y)
  local distance = min(x - f.min_x, f.max_x - x, y - f.min_y, f.max_y - y)
  local cost = (raw_x ~= x or raw_y ~= y) and cfg.boundary_cost or 0
  if distance < cfg.wall_margin then cost = cost + (cfg.wall_margin - distance) * cfg.wall_cost end
  candidate.terminal_x, candidate.terminal_y, candidate.terrain_cost = x, y, cost
  candidate.position_cost = cost + ((x - cfg.preferred_x)^2 + (y - cfg.preferred_y)^2) * cfg.position_cost
    + (vx * vx + vy * vy) * (cfg.movement_cost or 0.03)
  list[#list + 1] = candidate
end

local function buildCandidates(player, cfg, model, stats, intent)
  local candidates = {}
  addCandidate(candidates, player, cfg, "stay", 0, 0, 0, model)
  -- Focus is an independent input even at zero velocity. Keep the historical
  -- seventeen-candidate path exactly when no bloom intent was supplied.
  if intent then addCandidate(candidates, player, cfg, "slow-stay", keys.mask.shift, 0, 0, model) end
  for speed_index = 1, 2 do
    local speed = speed_index == 1 and player.speedSlow or player.speedFast
    local shift = speed_index == 1 and keys.mask.shift or 0
    for _, d in ipairs(DIRECTIONS) do
      local factor = d[2] ~= 0 and d[3] ~= 0 and DIAGONAL or 1
      addCandidate(candidates, player, cfg, (speed_index == 1 and "slow-" or "fast-") .. d[1],
        d[4] + shift, d[2] * speed * factor, d[3] * speed * factor, model)
    end
  end
  candidates.protected_until = model and model.protected_until or 0
  local reach = 0
  for _, candidate in ipairs(candidates) do
    stats.movement_segments = stats.movement_segments + #candidate.segments
    for _, segment in ipairs(candidate.segments) do
      reach = max(reach, abs(segment.x - player.x), abs(segment.y - player.y),
        abs(segment.x + segment.vx * segment.duration - player.x),
        abs(segment.y + segment.vy * segment.duration - player.y))
    end
  end
  candidates.reach = reach
  return candidates
end

-- This is a policy limit on the next input, NOT a new physical wall. Keep
-- every surviving candidate's complete trajectory unchanged for hazard
-- prediction: an upward input may be legal now but must be reconsidered on
-- the next callback before its later forecast crosses the line.
local function heightCandidates(candidates, player, cfg, intent, stats)
  local limit = intent and intent.min_y
  if not finite(limit) then return candidates end
  limit = clamp(limit, cfg.field.min_y, cfg.field.max_y)
  stats.height_limited = true
  stats.height_recovering = player.y < limit
  local floor_y = stats.height_recovering and player.y or limit
  local legal = { protected_until = candidates.protected_until, reach = candidates.reach }
  for _, candidate in ipairs(candidates) do
    -- The first update uses the sensor's current poison/non-poison factors.
    -- All candidate inputs have a constant signed direction; real walls may
    -- stop a component, but the planning line must never stop or teleport it.
    local next_y = clamp(player.y + candidate.vy, cfg.field.min_y, cfg.field.max_y)
    if next_y >= floor_y then
      legal[#legal + 1] = candidate
    else
      stats.height_rejected = stats.height_rejected + 1
    end
  end
  return legal
end

-- Only a validated live state-3 timer suppresses damage. Hurt transitions or
-- missing sensors never imply protection. The interval includes expiry: a
-- hit exactly when the timer ends must remain a hard collision.
local function unprotectedInterval(first, last, start, protected_until)
  if not first or start + last < protected_until then return nil end
  return max(first, protected_until - start), last
end

local function scoreExposure(candidate, first, last, near_first, near_last, start, horizon, soft, cfg, protected_until, active_until)
  local endpoint = not soft and protected_until > horizon and first and start + last >= horizon
  if not soft and protected_until > 0 then
    first, last = unprotectedInterval(first, last, start, protected_until)
    near_first, near_last = unprotectedInterval(near_first, near_last, start, protected_until)
  end
  if first and not soft and active_until and start + first >= active_until then first, last = nil, nil end
  local collision = exposure(first, last, start, horizon)
  if first and not soft then candidate.collides = true end
  local near = exposure(near_first, near_last, start, horizon)
  candidate.danger = candidate.danger + collision * (soft and cfg.warning_laser_cost or cfg.collision_cost)
    + max(0, near - collision) * cfg.near_miss_cost
    -- A still-protected endpoint is not a hit, but do not choose to camp in a
    -- persistent hazard merely because expiry lies beyond this short horizon.
    + (endpoint and cfg.near_miss_cost or 0)
end

-- Only laser snapshots need history. Upstream IDs are unique for each object
-- lifetime; absent IDs, missing frames and implausible discontinuities must
-- never inherit an old object's velocity. Battle reload also resets state.
local function laserMotion(object, body, previous, following, frame, stats)
  local id = object.id
  if type(id) ~= "number" or object.enabled == false then return nil end
  local now = { frame = frame, x = body.x or object.x or 0, y = body.y or object.y or 0,
    length = max(0, body.width or 0), height = abs(body.height or 0), angle = body.angle or 0 }
  following[id] = now
  local last = previous[id]
  if not last or last.frame + 1 ~= frame then return nil end
  local vx, vy, dl, dh = now.x - last.x, now.y - last.y, now.length - last.length, now.height - last.height
  local da = (now.angle - last.angle + math.pi) % (2 * math.pi) - math.pi
  -- These are reset guards, not speed clamps: a teleport/new beam is scored
  -- at its actual new shape instead of projecting a screen-wide false sweep.
  if vx * vx + vy * vy > 256 * 256 or abs(dl) > 256 or abs(dh) > 64 or abs(da) > math.pi / 4 then
    stats.laser_history_resets = stats.laser_history_resets + 1
    return nil
  end
  stats.tracked_lasers = stats.tracked_lasers + 1
  -- A warning becoming active is a state change, not a measured expansion
  -- rate. In particular do not extrapolate an on/off thickness jump forever.
  if now.height == 0 or last.height == 0 then dh = 0 end
  if abs(vx) + abs(vy) + abs(dl) + abs(dh) + abs(da) < 1e-8 then return nil end
  now.vx, now.vy, now.dl, now.dh, now.da = vx, vy, dl, dh, da
  return now
end

local function dynamicLaser(player, body, motion, candidates, cfg, stats)
  local horizon, margin = cfg.prediction_frames, cfg.safety_margin
  local warning = motion.height == 0
  local half_x = abs(player.hitBodyRect.width or 0) * 0.5
  local player_half_y = abs(player.hitBodyRect.height or 0) * 0.5
  local height = warning and (motion.length >= cfg.warning_laser_min_length and cfg.warning_laser_virtual_half_thickness or 0) or motion.height
  local dh = warning and 0 or motion.dh
  local intervals, start = {}, 0
  local rotating = abs(motion.da) > 1e-8
  local sweep_radius = max(motion.length, motion.length + motion.dl * horizon) + half_x
    + player_half_y + max(height, height + dh * horizon) * 0.5
  local sweep_count = min(12, max(1, math.ceil(abs(motion.da) * horizon * sweep_radius / (2 * max(1, margin)))))
  local rotation_step = horizon / sweep_count
  local zero_length = motion.dl < 0 and -motion.length / motion.dl or INF
  local zero_height = dh < 0 and -height / dh or INF
  while start < horizon do
    local finish = min(horizon, rotating and start + rotation_step or INF,
      zero_length > start and zero_length or INF, zero_height > start and zero_height or INF)
    local length = max(0, motion.length + motion.dl * start)
    local thick = max(0, height + dh * start)
    local dl, dheight = start >= zero_length and 0 or motion.dl, start >= zero_height and 0 or dh
    local angle = motion.angle + motion.da * (rotating and (start + finish) * 0.5 or start)
    local c, s = math.cos(angle), math.sin(angle)
    local hx, hy = half_x, player_half_y + thick * 0.5
    local length_end = max(0, motion.length + motion.dl * finish)
    local height_end = max(0, height + dh * finish)
    if rotating then
      -- Enclose the complete angular sweep, not just endpoint samples. For
      -- each interval, use the middle angle and bound its lateral deviation.
      -- Gentle turns need fewer intervals, but every intervening angle stays
      -- enclosed. Only moving/rotating lasers take this bounded slow path.
      length, hy = max(length, length_end), player_half_y + max(thick, height_end) * 0.5
      local half_turn = abs(motion.da) * (finish - start) * 0.5
      if half_turn < math.pi / 2 then
        local turn = math.sin(half_turn)
        hx, hy = hx + hy * turn, hy + (length + half_x) * turn
      else
        -- Nondefault very long horizons keep the same bounded work: a full
        -- circular envelope is necessary when an interval turns >=180 deg.
        local radius = sqrt((length + hx)^2 + hy * hy)
        hx, hy, length = radius, radius, 0
      end
      dl, dheight = 0, 0
    end
    intervals[#intervals + 1] = { start = start, finish = finish, c = c, s = s,
      length = length, dl = dl, hx = hx, hy = hy, dhy = dheight * 0.5,
      soft = warning or start >= zero_height }
    start = finish
  end

  -- Broad phase uses each future interval's complete swept shape, so a
  -- growing/rotating beam cannot be discarded using only its present bounds.
  local reach = candidates.reach
  local relevant = false
  for _, part in ipairs(intervals) do
    local duration = part.finish - part.start
    local length = max(part.length, part.length + part.dl * duration)
    local hy = max(part.hy, part.hy + part.dhy * duration) + margin
    local hx = part.hx + margin
    local bx = abs(part.c) * (length * 0.5 + hx) + abs(part.s) * hy
    local by = abs(part.s) * (length * 0.5 + hx) + abs(part.c) * hy
    local x = motion.x + motion.vx * part.start + part.c * length * 0.5
    local y = motion.y + motion.vy * part.start + part.s * length * 0.5
    local end_x, end_y = x + motion.vx * duration, y + motion.vy * duration
    if max(x, end_x) + bx >= player.x - reach and min(x, end_x) - bx <= player.x + reach
      and max(y, end_y) + by >= player.y - reach and min(y, end_y) - by <= player.y + reach then relevant = true; break end
  end
  if not relevant then return end
  stats.objects_relevant = stats.objects_relevant + 1
  if warning then stats.warning_lasers = stats.warning_lasers + 1 end
  for _, candidate in ipairs(candidates) do
    for _, segment in ipairs(candidate.segments) do
      for _, part in ipairs(intervals) do
        local first_time, last_time = max(segment.start, part.start), min(segment.start + segment.duration, part.finish)
        if last_time > first_time then
          stats.trajectory_tests = stats.trajectory_tests + 1
          stats.laser_sweep_tests = stats.laser_sweep_tests + 1
          local player_dt, shape_dt = first_time - segment.start, first_time - part.start
          local dx = segment.x + segment.vx * player_dt - motion.x - motion.vx * first_time
          local dy = segment.y + segment.vy * player_dt - motion.y - motion.vy * first_time
          local vx, vy = segment.vx - motion.vx, segment.vy - motion.vy
          dx, dy = part.c * dx + part.s * dy, -part.s * dx + part.c * dy
          vx, vy = part.c * vx + part.s * vy, -part.s * vx + part.c * vy
          local length, hy = part.length + part.dl * shape_dt, part.hy + part.dhy * shape_dt
          local duration, first, last = last_time - first_time
          local fixed_bounds = part.dl == 0 and part.dhy == 0
          if fixed_bounds then
            first, last = rectInterval(dx, dy, vx, vy, -part.hx, length + part.hx, -hy, hy, duration)
          else
            first, last = changingRectInterval(dx, dy, vx, vy, part.hx, hy, length, part.dl, part.dhy, duration)
          end
          -- Positive thickness ends at zero_height. A contact occurring only
          -- at that boundary has no damaging interval; later geometry is at
          -- most a soft warning, never an everlasting hard collision line.
          if not part.soft and first and first_time + first >= zero_height then first, last = nil, nil end
          local near_first, near_last
          if not part.soft then
            if fixed_bounds then
              near_first, near_last = rectInterval(dx, dy, vx, vy,
                -part.hx - margin, length + part.hx + margin, -hy - margin, hy + margin, duration)
            else
              near_first, near_last = changingRectInterval(dx, dy, vx, vy,
                part.hx + margin, hy + margin, length, part.dl, part.dhy, duration)
            end
          end
          if candidates.protected_until > 0 then
            scoreExposure(candidate, first, last, near_first, near_last, first_time, horizon,
              part.soft, cfg, candidates.protected_until, zero_height)
          else
            local collision = exposure(first, last, first_time, horizon)
            if first and not part.soft then candidate.collides = true end
            local near = exposure(near_first, near_last, first_time, horizon)
            candidate.danger = candidate.danger + collision * (part.soft and cfg.warning_laser_cost or cfg.collision_cost)
              + max(0, near - collision) * cfg.near_miss_cost
          end
        end
      end
    end
  end
end

-- Shared by the attention broad phase and collision scoring. A rotated EX is
-- anchored at one end, not at its centre; both passes must include its length.
local function collisionBounds(player, body, x, y, warning, cfg)
  local shape, margin = body.type, cfg.safety_margin
  local half_x = abs(player.hitBodyRect.width or 0) * 0.5
  local half_y = abs(player.hitBodyRect.height or 0) * 0.5
  local radius, length, cos_a, sin_a
  local bound_x, bound_y, center_x, center_y = 0, 0, x, y
  if shape == HitType.Circle then
    radius = abs(body.radius or 0) + abs(player.hitBodyCircle.radius or 0)
    bound_x, bound_y = radius + margin, radius + margin
  elseif shape == HitType.Rect then
    half_x = half_x + abs(body.width or 0) * 0.5
    half_y = half_y + abs(body.height or 0) * 0.5
    bound_x, bound_y = half_x + margin, half_y + margin
  else
    length = max(0, body.width or 0)
    cos_a, sin_a = math.cos(body.angle or 0), math.sin(body.angle or 0)
    -- Upstream x spans [0,width], y spans +/- height/2.
    local thickness = abs(body.height or 0)
    if warning and length >= cfg.warning_laser_min_length then thickness = max(thickness, cfg.warning_laser_virtual_half_thickness) end
    half_y = half_y + thickness * 0.5
    center_x, center_y = x + cos_a * length * 0.5, y + sin_a * length * 0.5
    bound_x = abs(cos_a) * (length * 0.5 + half_x + margin) + abs(sin_a) * (half_y + margin)
    bound_y = abs(sin_a) * (length * 0.5 + half_x + margin) + abs(cos_a) * (half_y + margin)
  end
  return center_x, center_y, bound_x, bound_y, half_x, half_y, radius, length, cos_a, sin_a
end

local function scoreObject(player, object, kind, candidates, cfg, stats, previous_lasers, next_lasers, frame)
  stats.objects_seen = stats.objects_seen + 1
  -- Upstream labels the 64-pixel Medicine slow field as a hittable circle;
  -- that is a terrain boundary, unlike Eiki/Reimu/etc. damaging EX circles.
  if kind == "ex" and medicine(object) then return end
  local body = object.hitBody
  if not body or (kind == "ex" and object.hittable == false) then return end
  local shape = body.type
  if shape ~= HitType.Rect and shape ~= HitType.Circle and shape ~= HitType.RotatableRect then return end
  if shape == HitType.RotatableRect and kind == "bullet" then
    stats.laser_count = stats.laser_count + 1
    local motion = laserMotion(object, body, previous_lasers, next_lasers, frame, stats)
    if motion then
      stats.dynamic_lasers = stats.dynamic_lasers + 1
      dynamicLaser(player, body, motion, candidates, cfg, stats); return
    end
  end
  local x, y = body.x or object.x or 0, body.y or object.y or 0
  local vx, vy = object.vx or 0, object.vy or 0
  local h, margin = cfg.prediction_frames, cfg.safety_margin
  local warning = shape == HitType.RotatableRect and kind == "bullet"
    and (body.height or 0) == 0
  local center_x, center_y, bound_x, bound_y, half_x, half_y, radius, length, cos_a, sin_a =
    collisionBounds(player, body, x, y, warning, cfg)
  -- Scan every object. Swept bounds include bullet velocity and all candidate
  -- travel, so neither distant fast bullets nor late array entries get omitted.
  local reach = candidates.reach
  local start_x, start_y = center_x, center_y
  if candidates.active_from and not warning then
    -- The stationary post-route safety pass cannot take damage before live
    -- protection expires. Cull only against the remaining damaging sweep;
    -- keep warning lasers' entire sweep and the inclusive expiry endpoint.
    start_x, start_y = center_x + vx * candidates.active_from, center_y + vy * candidates.active_from
  end
  local end_x, end_y = center_x + vx * h, center_y + vy * h
  if max(start_x, end_x) + bound_x < player.x - reach
    or min(start_x, end_x) - bound_x > player.x + reach
    or max(start_y, end_y) + bound_y < player.y - reach
    or min(start_y, end_y) - bound_y > player.y + reach then return end
  stats.objects_relevant = stats.objects_relevant + 1
  if warning then stats.warning_lasers = stats.warning_lasers + 1 end
  for _, candidate in ipairs(candidates) do
    for _, segment in ipairs(candidate.segments) do
      stats.trajectory_tests = stats.trajectory_tests + 1
      local dx, dy = segment.x - x - vx * segment.start, segment.y - y - vy * segment.start
      local rvx, rvy = segment.vx - vx, segment.vy - vy
      if shape == HitType.RotatableRect then
        dx, dy = cos_a * dx + sin_a * dy, -sin_a * dx + cos_a * dy
        rvx, rvy = cos_a * rvx + sin_a * rvy, -sin_a * rvx + cos_a * rvy
      end
      local first, last, near_first, near_last
      if shape == HitType.Circle then
        first, last = circleInterval(dx, dy, rvx, rvy, radius, segment.duration)
        near_first, near_last = circleInterval(dx, dy, rvx, rvy, radius + margin, segment.duration)
      else
        local hi_x = (length or 0) + half_x
        first, last = rectInterval(dx, dy, rvx, rvy, -half_x, hi_x, -half_y, half_y, segment.duration)
        if not warning then
          near_first, near_last = rectInterval(dx, dy, rvx, rvy, -half_x - margin, hi_x + margin,
            -half_y - margin, half_y + margin, segment.duration)
        end
      end
      if candidates.protected_until > 0 then
        scoreExposure(candidate, first, last, near_first, near_last, segment.start, h,
          warning, cfg, candidates.protected_until)
      else
        local collision = exposure(first, last, segment.start, h)
        if first and not warning then candidate.collides = true end
        local near = exposure(near_first, near_last, segment.start, h)
        candidate.danger = candidate.danger + collision * (warning and cfg.warning_laser_cost or cfg.collision_cost)
          + max(0, near - collision) * cfg.near_miss_cost
      end
    end
  end
end

-- A confirmed post-C2 intent may reserve a short-route endpoint through the
-- ACTUAL protection expiry. Keep the original movement forecast unchanged;
-- this separate, hypothetical tail means "stop at its endpoint", not "hold
-- this direction until the shield ends". Replan on every real callback.
local function protectedRoutes(game_side, candidates, cfg, intent, stats, previous_lasers, frame)
  local sensor = game_side.player.sensor
  if not intent or intent.protected_followup ~= true or type(sensor) ~= "table"
    or sensor.apiVersion ~= 1 or sensor.valid ~= true or sensor.state ~= 3
    or sensor.cutIn == true or sensor.timeScale ~= 1 or sensor.movementEnabled == false then return end
  local until_time, h = candidates.protected_until, cfg.prediction_frames
  if not finite(until_time) or until_time <= 0 then return end
  local horizon = until_time + 4
  -- Beyond this bound no claim about an expiry route is made. If expiry plus
  -- its margin is already inside the normal forecast, normal geometry wins.
  if horizon <= h or horizon > 60 then return end
  local tail_cfg = {}
  for k, v in pairs(cfg) do tail_cfg[k] = v end
  tail_cfg.prediction_frames = horizon
  local tails = { protected_until = until_time, reach = candidates.reach, active_from = max(h, until_time) }
  local tail_stats = {}
  for k, v in pairs(stats) do tail_stats[k] = type(v) == "number" and 0 or false end
  local height = finite(intent.min_y) and clamp(intent.min_y, cfg.field.min_y, cfg.field.max_y) or nil
  -- Recovery from an already-illegal height can take more than one short
  -- route. Do not let an unavailable legal endpoint cancel that descent.
  if height and game_side.player.y < height then return end
  for _, candidate in ipairs(candidates) do
    tails[#tails + 1] = { danger = 0, collides = false,
      segments = { { start = h, duration = horizon - h,
        x = candidate.terminal_x, y = candidate.terminal_y, vx = 0, vy = 0 } },
      -- A forecast that later crosses the policy line is still a legal NEXT
      -- input, but it is not a legal place to stop and reserve an endpoint.
      endpoint_legal = not height or candidate.terminal_y >= height }
  end
  local unused_history = {}
  for _, kind in ipairs({ "enemies", "bullets", "exAttacks" }) do
    local tag = kind == "enemies" and "enemy" or (kind == "bullets" and "bullet" or "ex")
    for _, object in ipairs(game_side[kind]) do
      -- Every real hazard remains present. No predicted cancel circle or
      -- isErasable flag is allowed to delete an object from this safety pass.
      scoreObject(game_side.player, object, tag, tails, tail_cfg, tail_stats,
        previous_lasers, unused_history, frame)
    end
  end
  stats.protected_route_checked, stats.protected_route_horizon = true, horizon
  stats.protected_route_tests = tail_stats.trajectory_tests
  for i, tail in ipairs(tails) do
    local candidate = candidates[i]
    candidate.protected_route_collides = tail.collides
    candidate.protected_route_danger = tail.danger
    candidate.protected_route_usable = not tail.collides and tail.endpoint_legal
    if not candidate.protected_route_usable then
      stats.protected_route_rejected = stats.protected_route_rejected + 1
    end
  end
end

local function intentCost(candidate, player, cfg, intent)
  local cost = 0
  if type(intent.focus) == "boolean" and candidate.focus ~= intent.focus then
    local mismatch = finite(intent.focus_mismatch_cost) and intent.focus_mismatch_cost or 2
    cost = clamp(mismatch, 0, 8)
  end
  local height_limit = finite(intent.min_y) and clamp(intent.min_y, cfg.field.min_y, cfg.field.max_y) or nil
  if finite(intent.target_x) or finite(intent.target_y) or (height_limit and player.y < height_limit) then
    local target_x = clamp(finite(intent.target_x) and intent.target_x or player.x, cfg.field.min_x, cfg.field.max_x)
    local target_y = clamp(finite(intent.target_y) and intent.target_y or player.y, cfg.field.min_y, cfg.field.max_y)
    if height_limit then target_y = max(target_y, height_limit) end
    local weight = finite(intent.position_weight) and clamp(intent.position_weight, 0, 0.01) or 0.002
    local before = (player.x - target_x)^2 + (player.y - target_y)^2
    local after = (candidate.terminal_x - target_x)^2 + (candidate.terminal_y - target_y)^2
    -- Use the actual poison/wall-limited endpoint. Bounded signed improvement
    -- rewards approaching resources without assuming nominal travel occurs.
    cost = cost + clamp((after - before) * weight, -12, 12)
  end
  return cost
end

-- 3.0 human-like movement cap: a person cannot re-decide a movement direction
-- every frame. Direction changes are budgeted in a rolling window with a
-- minimum dwell time; when the cap is exhausted only the previous direction
-- remains eligible, so a wave that needs more micro-adjustments than the cap
-- allows can be missed. The result reports the forced state so the policy can
-- answer with a charge attack instead of out-microing the bullets forever.
local function directionId(vx, vy)
  local sx = (vx or 0) > 1e-9 and 1 or ((vx or 0) < -1e-9 and -1 or 0)
  local sy = (vy or 0) > 1e-9 and 1 or ((vy or 0) < -1e-9 and -1 or 0)
  return (sx + 1) * 3 + (sy + 1)
end

local function movementCap(state, cfg)
  local window = max(1, math.floor(cfg.move_change_window or 60))
  state.move_change_history = state.move_change_history or {}
  if state.move_change_window ~= window then
    state.move_change_history, state.move_change_index, state.move_changes = {}, nil, 0
    state.move_change_window = window
  end
  state.move_change_index = (state.move_change_index or 0) % window + 1
  state.move_changes = max(0, (state.move_changes or 0)
    - (state.move_change_history[state.move_change_index] or 0))
  state.move_change_history[state.move_change_index] = 0
  local budget = max(0, math.floor(cfg.move_change_budget or 6))
  local dwell = max(0, math.floor(cfg.move_change_min_frames or 5))
  local age = state.move_change_age or (dwell + 1)
  return (state.move_changes >= budget) or (age < dwell)
end

-- Only direction changes made while a real danger is present count against the
-- human-like budget; moving around a calm screen is free.
local function recordMove(state, vx, vy, dodging)
  local dir = directionId(vx, vy)
  if not dodging then
    state.last_move_dir = dir
    state.move_change_age = 1e9
    return
  end
  if state.last_move_dir ~= nil and dir ~= state.last_move_dir then
    state.move_changes = (state.move_changes or 0) + 1
    state.move_change_history[state.move_change_index] = 1
    state.move_change_age = 0
  else
    state.move_change_age = (state.move_change_age or 0) + 1
  end
  state.last_move_dir = dir
end

-- 3.1 human attention limit. A person cannot keep every bullet in mind: only a
-- few objects can be tracked at once, fast objects (accelerated EX sticks in
-- particular) cost more than slow ones, and the screen is re-read a few times
-- per second rather than every frame. Objects that are not admitted are never
-- scored, so the planner can walk into one exactly like a person can; the
-- overload is reported so the policy may answer with a charge attack instead.
local function attentionSettings(cfg)
  local a = cfg.attention
  if type(a) ~= "table" or a.enabled == false then return nil end
  if not finite(a.threat_per_second) or not finite(a.tracked_threat) then return nil end
  return a
end

-- Cost of one object in "standard white bullet" units. Lasers, poison, fairies
-- and the close reflex ring are handled by the caller and are never billed.
local function attentionCost(object, body, a)
  local vx, vy = object.vx, object.vy
  if not finite(vx) or not finite(vy) then return nil end
  local reference = finite(a.speed_reference) and a.speed_reference or 1.5
  if reference <= 0 then reference = 1.5 end
  local exponent = finite(a.speed_exponent) and a.speed_exponent or 1
  local speed = sqrt(vx * vx + vy * vy)
  local cost = ((speed > 0 and speed or 0) / reference) ^ exponent
  if body.type ~= HitType.Circle then
    -- A long EX stick denies more of the escape space than a point bullet.
    local width_reference = finite(a.width_reference) and max(1, a.width_reference) or 128
    local factor = clamp(1 + abs(body.width or 0) / width_reference, 1, a.width_max or 2.5)
    cost = cost * factor
  end
  return clamp(cost, a.min_cost or 0.5, a.max_cost or 6), speed
end

-- A sight estimate (priority/urgency), not the swept collision test: how soon
-- the object's own motion can reach a player who stands still.
local function sightRadius(body)
  if body.type == HitType.Circle then return abs(body.radius or 0) end
  if body.type == HitType.RotatableRect then return max(8, abs(body.height or 0)) end
  return 0.5 * max(abs(body.width or 0), abs(body.height or 0))
end

-- The cheap swept-box test scoreObject uses to decide whether an object can
-- interact with any candidate route inside the horizon. This -- not "would hit
-- a standing player" -- is what "in front of me" means: if the unlimited build
-- would score an object, the attention limit must at least consider it, or the
-- AI goes blind in a normal field (3.2.0/3.2.1 regression).
local function withinReach(player, body, object, reach, cfg)
  local x, y = body.x or object.x or 0, body.y or object.y or 0
  local vx, vy = object.vx or 0, object.vy or 0
  local center_x, center_y, bound_x, bound_y = collisionBounds(player, body, x, y, false, cfg)
  local end_x, end_y = center_x + vx * cfg.prediction_frames, center_y + vy * cfg.prediction_frames
  return max(center_x, end_x) + bound_x >= player.x - reach and min(center_x, end_x) - bound_x <= player.x + reach
    and max(center_y, end_y) + bound_y >= player.y - reach and min(center_y, end_y) - bound_y <= player.y + reach
end

-- Returns the time (in updates) until this object can hit the player who
-- stands still, and how much clearance it keeps. The clearance also tells the
-- planner how urgent the object is once it is in sight.
local function approach(player, body, object, radius, horizon)
  local x, y = body.x or object.x or 0, body.y or object.y or 0
  local vx, vy = object.vx or 0, object.vy or 0
  local half = 0.5 * abs(player.hitBodyRect and player.hitBodyRect.width or 0)
  local circle = player.hitBodyCircle and abs(player.hitBodyCircle.radius or 0) or 0
  local reach = radius + max(half, circle)
  local rx, ry = player.x - x, player.y - y
  local speed2 = vx * vx + vy * vy
  if speed2 < 1e-12 then
    local distance = sqrt(rx * rx + ry * ry)
    return (distance <= reach) and 0 or INF, distance - reach
  end
  local t = (rx * vx + ry * vy) / speed2
  if t < 0 then t = 0 end
  if t > horizon then
    local mx, my = rx - vx * horizon, ry - vy * horizon
    return INF, sqrt(mx * mx + my * my) - reach
  end
  local miss_x, miss_y = rx - vx * t, ry - vy * t
  local clearance = sqrt(miss_x * miss_x + miss_y * miss_y) - reach
  return (clearance <= 0) and t or INF, clearance
end

local function attentionKey(object)
  local id = object.id
  if finite(id) then return id end
  -- Without a stable ID, only the same object reference can retain attention.
  -- An array index can silently become a different bullet after a deletion.
  return object
end

local function overloadPanics(a)
  local action = a.overload_action
  return action == "panic" or action == "c_then_panic" or action == "c_then_panic_fallback"
end

local function overloadReleases(a)
  local action = a.overload_action
  return action == "c" or action == "c_then_panic" or action == "c_then_panic_fallback"
end

local PANIC_CANDIDATES = {
  stay = true, ["slow-stay"] = true,
  ["fast-left"] = true, ["fast-right"] = true, ["fast-up"] = true, ["fast-down"] = true,
}

local function planAttention(player, game_side, cfg, a, state, reach)
  -- The sight box must stay a superset of the route search's own cull: if the
  -- reported reach is missing or small, fall back to a generous fixed radius
  -- instead of going blind.
  reach = finite(reach) and max(reach, 48) or 48
  local horizon = max(1, math.floor(a.urgent_frames or 24))
  local interval = max(1, math.floor(a.plan_interval or 6))
  local capacity = max(0, a.tracked_threat or 0)
  local rate = max(0, a.threat_per_second or 0)
  local reflex = max(0, a.reflex_radius or 0)
  local sight_radius = max(0, a.sight_radius or 0)
  local limit = max(1, math.floor(a.blind_urgent_limit or 3))
  local frame = state.frame or 1
  -- A configuration change (preset switch, test override) starts over.
  if state.attention_config ~= a then
    state.attention_config = a
    state.attention_set, state.attention_tokens, state.attention_blind_frames = nil, nil, 0
    state.attention_blind, state.attention_tracked, state.attention_scan_frame = 0, 0, nil
  end
  local previous = state.attention_set or {}
  local seen = { bullet = {}, ex = {} }
  local result = { seen = seen, tracked = 0, blind = 0 }

  -- Free categories are always visible: warning/real lasers are few and huge,
  -- the Medicine field is terrain, and objects with an unusable velocity must
  -- never be silently hidden.
  local entries, free_objects = {}, {}
  for _, spec in ipairs({ { "bullets", "bullet" }, { "exAttacks", "ex" } }) do
    local list, tag = game_side[spec[1]], spec[2]
    for index, object in ipairs(list) do
      local raw_key = attentionKey(object, index)
      local key = type(raw_key) == "number" and tag .. ":" .. tostring(raw_key) or raw_key
      local body, free = object.hitBody, false
      -- Warning/real lasers (RotatableRect bullets) are free; an EX stick uses
      -- the same shape but is a billed, accelerating threat.
      local billed_shape = body and (body.type == HitType.Rect or body.type == HitType.Circle
        or (tag == "ex" and body.type == HitType.RotatableRect))
      if not billed_shape or (tag == "ex" and (object.hittable == false or medicine(object))) then
        free = true
      else
        local cost, speed = attentionCost(object, body, a)
        if cost == nil then
          -- An unreadable velocity must never be silently hidden.
          free = true
        else
          local x, y = body.x or object.x or 0, body.y or object.y or 0
          local distance = sqrt((player.x - x) ^ 2 + (player.y - y) ^ 2)
          local ttc, clearance = approach(player, body, object, sightRadius(body), horizon)
          -- "In front of me" is everything the route search could touch inside
          -- the prediction horizon (the same swept-box cull scoreObject uses),
          -- plus anything already passing close by. Restricting this to "would
          -- hit a standing player" made the AI nearly blind in real fields.
          if ttc ~= INF or clearance <= sight_radius or distance <= reflex
              or withinReach(player, body, object, reach, cfg) then
            entries[#entries + 1] = { key = key, tag = tag, raw_key = raw_key, object = object,
              cost = cost, speed = speed, reflex = distance <= reflex, ttc = ttc, imminent = ttc ~= INF }
          end
        end
      end
      -- Everything else (outside the sight set) is simply not scored: the route
      -- search culls it anyway, and pretending to see it is what made the
      -- attention limit meaningless.
      if free then seen[tag][raw_key] = true; free_objects[#free_objects + 1] = { object = object, tag = tag } end
    end
  end
  result.free_objects = free_objects
  -- Enemies are slow, few and visually obvious; they stay visible.
  if #game_side.enemies > 0 then
    local enemy_seen = {}
    for index, object in ipairs(game_side.enemies) do enemy_seen[attentionKey(object, index)] = true end
    seen.enemy = enemy_seen
  end

  -- Only re-read the screen every plan_interval callbacks; between reads the
  -- tracked set is kept, which is what makes a new bullet invisible for a
  -- moment after the last look.
  local last = state.attention_scan_frame
  if last == nil or frame - last >= interval or frame < last then
    state.attention_scan_frame = frame
    local ordered = {}
    for _, entry in ipairs(entries) do
      local continuing = previous[entry.key] == entry.tag
      entry.priority = entry.reflex and 0 or (continuing and 1 or 2)
      if entry.ttc == INF and not entry.reflex then entry.priority = 3 end
      ordered[#ordered + 1] = entry
    end
    table.sort(ordered, function(l, r)
      if l.priority ~= r.priority then return l.priority < r.priority end
      if l.ttc ~= r.ttc then return l.ttc < r.ttc end
      return l.cost > r.cost
    end)
    -- Acquisition credit refills continuously and never exceeds capacity, so a
    -- burst is possible but a sustained dense wave is not.
    local credit = state.attention_tokens
    if not finite(credit) then credit = capacity end
    credit = min(capacity, credit + rate * interval / 60)
    local budget, admitted, reflex_used = capacity, {}, 0
    -- The close reflex ring bypasses the budget only for a bounded number of
    -- objects: noticing what is already touching you must not become an
    -- unlimited second sight that threads a tight pack.
    local reflex_slots = max(1, math.ceil(capacity))
    for _, entry in ipairs(ordered) do
      local continuing = previous[entry.key] == entry.tag
      -- One object can always occupy the whole simultaneous capacity: a single
      -- very fast shot must never be permanently invisible.
      local cost = entry.cost
      if capacity > 0 and cost > capacity then cost = capacity end
      local fits = cost <= budget + 1e-9
      local paid = continuing or cost <= credit + 1e-9
      local admit = fits and paid
      if not admit and entry.reflex and reflex_used < reflex_slots then
        admit, reflex_used = true, reflex_used + 1
      end
      if admit then
        admitted[entry.key] = entry.tag
        if fits then budget = budget - cost end
        if not continuing then credit = max(0, credit - cost) end
      end
    end
    state.attention_set = admitted
    state.attention_tokens = clamp(credit, 0, capacity)
  end
  -- Bind selected identities to THIS callback's objects. Native tables are
  -- reused by array slot; keeping a table across looks can follow another ID
  -- after compaction. Rebuilding hosts need the same ID-to-current-object bind.
  -- New objects still wait for a scan and must pay the acquisition budget.
  local selected, present, scored = state.attention_set or {}, {}, {}
  local load, seen_cost, skipped, blind_cost, blind, tracked = 0, 0, 0, 0, 0, 0
  local nearest_ttc, nearest_cost, nearest_speed = INF, 0, 0
  for _, entry in ipairs(entries) do
    load = load + entry.cost
    if selected[entry.key] == entry.tag then
      present[entry.key] = entry.tag
      seen[entry.tag][entry.raw_key] = true
      scored[#scored + 1] = { object = entry.object, tag = entry.tag }
      tracked, seen_cost = tracked + 1, seen_cost + entry.cost
    else
      skipped = skipped + 1
      if entry.imminent then
        blind, blind_cost = blind + 1, blind_cost + entry.cost
        if entry.ttc < nearest_ttc then
          nearest_ttc, nearest_cost, nearest_speed = entry.ttc, entry.cost, entry.speed or 0
        end
      end
    end
  end
  state.attention_set, state.attention_scored = present, scored
  state.attention_blind, state.attention_tracked = blind, tracked
  state.attention_load, state.attention_seen_cost = load, seen_cost
  state.attention_skipped, state.attention_blind_cost = skipped, blind_cost
  state.attention_nearest_blind = nearest_ttc == INF and -1 or nearest_ttc
  state.attention_nearest_cost, state.attention_nearest_speed = nearest_cost, nearest_speed
  state.attention_budget, state.attention_credit = capacity, state.attention_tokens or 0
  state.attention_entries, state.attention_reach = #entries, reach
  result.tracked = state.attention_tracked or 0
  result.blind = state.attention_blind or 0
  result.load = state.attention_load or 0
  result.seen_cost = state.attention_seen_cost or 0
  result.skipped = state.attention_skipped or 0
  result.blind_cost = state.attention_blind_cost or 0
  result.nearest_blind = state.attention_nearest_blind or -1
  result.nearest_cost = state.attention_nearest_cost or 0
  result.nearest_speed = state.attention_nearest_speed or 0
  result.budget = state.attention_budget or 0
  result.credit = state.attention_credit or 0
  result.entries = state.attention_entries or 0
  result.reach = state.attention_reach or 0
  result.scored = state.attention_scored or {}
  result.free = result.free_objects or {}
  -- A short hysteresis keeps the overload state from flickering on a single
  -- calm frame while still clearing soon after the wave passes.
  local pressure = state.attention_blind_frames or 0
  if result.blind >= limit then pressure = min(limit * 4, pressure + 1) else pressure = max(0, pressure - 1) end
  state.attention_blind_frames = pressure
  result.overloaded = pressure >= max(1, math.floor(a.overload_frames or 6))
  result.escape = result.overloaded and overloadReleases(a)
  result.panic = result.overloaded and overloadPanics(a)
  return result
end

local function choose(game_side, state, cfg, intent)
  if type(intent) ~= "table" then intent = nil end
  -- Keep this boundary even when attention is disabled or a caller bypasses
  -- main.lua. Refiltering a shared visible snapshot is cheap and idempotent;
  -- no marker supplied by the native host is trusted to bypass hard sight.
  game_side = perceive(game_side, cfg)
  local player = game_side.player
  local stats = { warning_lasers = 0, objects_seen = 0, objects_relevant = 0, trajectory_tests = 0,
    laser_count = 0, tracked_lasers = 0, dynamic_lasers = 0, laser_sweep_tests = 0, laser_history_resets = 0,
    sensor_valid = 0, poison_clouds = 0, movement_segments = 0, protection_frames = 0,
    height_limited = false, height_recovering = false, height_rejected = 0,
    protected_route_checked = false, protected_route_horizon = 0,
    protected_route_tests = 0, protected_route_rejected = 0,
    attention_tracked = 0, attention_blind_urgent = 0, attention_overloaded = false,
    attention_panic = false, attention_escape = false, attention_load = 0, attention_seen_cost = 0,
    attention_skipped = 0, attention_blind_cost = 0, attention_nearest_blind = -1,
    attention_nearest_cost = 0, attention_nearest_speed = 0, attention_budget = 0, attention_credit = 0,
    attention_entries = 0, attention_reach = 0, attention_free = 0 }
  local model = movementModel(player, cfg, stats)
  local candidates = buildCandidates(player, cfg, model, stats, intent)
  candidates = heightCandidates(candidates, player, cfg, intent, stats)
  local frame = state.frame or ((state.laser_frame or 0) + 1)
  local previous_lasers, next_lasers = state.laser_history or {}, {}
  -- 3.1 attention limit decides which incoming objects this callback can see.
  local attention = attentionSettings(cfg)
  local attention_result = attention and planAttention(player, game_side, cfg, attention, state, candidates.reach) or nil
  if attention_result then
    stats.attention_tracked = attention_result.tracked
    stats.attention_blind_urgent = attention_result.blind
    stats.attention_overloaded = attention_result.overloaded
    stats.attention_escape = attention_result.escape
    stats.attention_panic = attention_result.panic
    stats.attention_load = attention_result.load
    stats.attention_seen_cost = attention_result.seen_cost
    stats.attention_skipped = attention_result.skipped
    stats.attention_blind_cost = attention_result.blind_cost
    stats.attention_nearest_blind = attention_result.nearest_blind
    stats.attention_nearest_cost = attention_result.nearest_cost
    stats.attention_nearest_speed = attention_result.nearest_speed
    stats.attention_budget = attention_result.budget
    stats.attention_credit = attention_result.credit
    stats.attention_entries = attention_result.entries
    stats.attention_reach = attention_result.reach
    stats.attention_free = #attention_result.free
  end
  if attention_result then
    -- Score exactly the objects the attention pass produced: admitted plus the
    -- genuinely free categories. No second lookup of the host object list.
    for _, item in ipairs(attention_result.free) do
      scoreObject(player, item.object, item.tag, candidates, cfg, stats, previous_lasers, next_lasers, frame)
    end
    for _, item in ipairs(attention_result.scored) do
      scoreObject(player, item.object, item.tag, candidates, cfg, stats, previous_lasers, next_lasers, frame)
    end
  end
  for _, kind in ipairs({ "enemies", "bullets", "exAttacks" }) do
    local tag = kind == "enemies" and "enemy" or (kind == "bullets" and "bullet" or "ex")
    for index, object in ipairs(game_side[kind]) do
      -- Unseen objects are not scored at all: the planner can walk into one.
      if not attention_result or tag == "enemy" then
        scoreObject(player, object, tag, candidates, cfg, stats, previous_lasers, next_lasers, frame)
      end
    end
  end
  state.laser_history, state.laser_frame = next_lasers, frame
  protectedRoutes(game_side, candidates, cfg, intent, stats, previous_lasers, frame)
  local stay = candidates[1]
  local last_direction = state.last_move_key
  if intent and last_direction ~= nil then
    last_direction = last_direction - math.floor(last_direction / keys.mask.shift) % 2 * keys.mask.shift
  end
  -- Selection is a pure function of the eligible pool so the movement cap can
  -- evaluate the same rules on a restricted pool.
  local function pick(pool)
    local best = pool[1]
    -- Hysteresis only applies while standing still faces danger. Empty screens
    -- therefore do not preserve a needless moving direction forever.
    for _, candidate in ipairs(pool) do
      candidate.cost = candidate.danger + candidate.position_cost
      -- A bloom capture window must be able to end without paying a direction
      -- change for releasing Shift. Geometry already scores its speed change.
      -- The nil-intent path retains the complete historical key comparison.
      local direction = candidate.key - (intent and candidate.focus and keys.mask.shift or 0)
      if stay.danger > 0 and last_direction ~= nil and direction ~= last_direction then
        candidate.cost = candidate.cost + cfg.direction_change_cost
      end
      -- A real collision cannot be outweighed by wall/position preferences or
      -- direction hysteresis, even if contact occurs exactly at the horizon.
      if (best.collides and not candidate.collides)
        or (best.collides == candidate.collides and candidate.cost < best.cost) then best = candidate end
    end
    if intent and not best.collides then
      local baseline, best_score = best, best.cost + intentCost(best, player, cfg, intent)
      -- Permit a small, nonzero soft-risk band so resource positioning is not
      -- restricted to exact floating-point ties. Never buy a collision, more
      -- boundary/wall exposure, or sustained near-miss danger with resources.
      -- Default allowance is 5.6 vs. 140 per near-miss exposure unit.
      local risk_budget = min(6, max(0, cfg.near_miss_cost or 0) * 0.04)
      local route_available = false
      if stats.protected_route_checked then
        for _, candidate in ipairs(pool) do
          if not candidate.collides and candidate.terrain_cost <= baseline.terrain_cost + 1e-9
            and candidate.danger <= baseline.danger + risk_budget + 1e-9
            and candidate.protected_route_usable then route_available = true; break end
        end
        if route_available then best_score = INF end
      end
      for _, candidate in ipairs(pool) do
        if not candidate.collides and candidate.terrain_cost <= baseline.terrain_cost + 1e-9
          and candidate.danger <= baseline.danger + risk_budget + 1e-9
          and (not stats.protected_route_checked or (route_available and candidate.protected_route_usable)) then
          local score = candidate.cost + intentCost(candidate, player, cfg, intent)
            + (route_available and candidate.protected_route_danger or 0)
          if score < best_score then best, best_score = candidate, score end
        end
      end
      if stats.protected_route_checked and not route_available then
        -- No same-risk endpoint can be reserved. Keep immediate geometric
        -- escape ordering; resource intent must not advertise a safe exit.
        best.intent_cost = 0
      else
        best.intent_cost = intentCost(best, player, cfg, intent)
        best.cost = best_score
      end
    elseif intent then
      -- If every path collides, retain the original escape ranking.
      best.intent_cost = 0
    end
    best.protected_route_safe = stats.protected_route_checked and not best.collides
      and best.protected_route_usable == true
    best.protected_route_collides = best.protected_route_collides == true
    best.protected_route_danger = best.protected_route_danger or 0
    return best
  end
  -- Overload panic: when the screen cannot be read at all, a person answers
  -- with a crude cardinal move (or freezes) instead of a fine route.
  local pool = candidates
  if stats.attention_panic then
    local coarse = {}
    for _, candidate in ipairs(candidates) do
      if PANIC_CANDIDATES[candidate.name] then coarse[#coarse + 1] = candidate end
    end
    if #coarse > 0 then pool = coarse end
  end
  local best = pick(pool)
  local cap_forced, cap_risk = false, false
  if movementCap(state, cfg) and stay.danger > 0 and state.last_move_dir ~= nil then
    -- Human-like cap: while the rolling change budget or the dwell time forbids
    -- a new direction, only candidates keeping the previous direction remain
    -- eligible. A wave that needs more micro-adjustments than this can be
    -- missed on purpose; move_cap_forced/move_cap_risk report that the cap
    -- overrode a better uncapped choice.
    local restricted = {}
    for _, candidate in ipairs(pool) do
      if directionId(candidate.vx, candidate.vy) == state.last_move_dir then
        restricted[#restricted + 1] = candidate
      end
    end
    if #restricted == 0 then
      -- No candidate keeps the previous direction; freezing in place is the
      -- human answer (the cap must not silently become a free direction change).
      for _, candidate in ipairs(pool) do
        if candidate.name == "stay" or candidate.name == "slow-stay" then
          restricted[#restricted + 1] = candidate
        end
      end
    end
    if #restricted > 0 then
      local kept = pick(restricted)
      if directionId(kept.vx, kept.vy) ~= directionId(best.vx, best.vy) then
        cap_forced = true
        cap_risk = (best.danger < kept.danger) or (not best.collides and kept.collides)
      end
      best = kept
    end
  end
  recordMove(state, best.vx, best.vy, stay.danger > 0)
  state.last_move_key = best.key
  best.move_changes = state.move_changes or 0
  best.move_cap_forced = cap_forced
  best.move_cap_risk = cap_risk
  best.attention_tracked = stats.attention_tracked or 0
  best.attention_blind_urgent = stats.attention_blind_urgent or 0
  best.attention_overloaded = stats.attention_overloaded == true
  best.attention_panic = stats.attention_panic == true
  best.attention_escape = stats.attention_escape == true
  best.attention_load = stats.attention_load or 0
  best.attention_seen_cost = stats.attention_seen_cost or 0
  best.attention_skipped = stats.attention_skipped or 0
  best.attention_blind_cost = stats.attention_blind_cost or 0
  best.attention_nearest_blind = stats.attention_nearest_blind or -1
  best.attention_nearest_cost = stats.attention_nearest_cost or 0
  best.attention_nearest_speed = stats.attention_nearest_speed or 0
  best.attention_budget = stats.attention_budget or 0
  best.attention_credit = stats.attention_credit or 0
  best.attention_entries = stats.attention_entries or 0
  best.attention_reach = stats.attention_reach or 0
  best.attention_free = stats.attention_free or 0
  for name, value in pairs(stats) do best[name] = value end
  return best
end

return { choose = choose, perceive = perceive, rectInterval = rectInterval, circleInterval = circleInterval,
  changingRectInterval = changingRectInterval }
