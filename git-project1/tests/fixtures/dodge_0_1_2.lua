local keys = dofile("keyutils.lua")

local SQRT2 = math.sqrt(2)

local DIRECTIONS = {
  { name = "right",     dx =  1, dy =  0, key = keys.mask.right },
  { name = "left",      dx = -1, dy =  0, key = keys.mask.left },
  { name = "down",      dx =  0, dy =  1, key = keys.mask.down },
  { name = "up",        dx =  0, dy = -1, key = keys.mask.up },
  { name = "down-right",dx =  1, dy =  1, key = keys.mask.down + keys.mask.right },
  { name = "down-left", dx = -1, dy =  1, key = keys.mask.down + keys.mask.left },
  { name = "up-right",  dx =  1, dy = -1, key = keys.mask.up + keys.mask.right },
  { name = "up-left",   dx = -1, dy = -1, key = keys.mask.up + keys.mask.left },
}

local function copyTable(source)
  local result = {}
  for key, value in pairs(source) do
    result[key] = value
  end
  return result
end

local function clamp(value, min_value, max_value)
  return math.max(min_value, math.min(max_value, value))
end

local function buildCandidates(player, previous_key, cfg)
  local candidates = {
    { name = "stay", key = 0, vx = 0, vy = 0, cost = 0 },
  }
  local speeds = {
    { name = "fast", value = player.speedFast, shift = 0 },
    { name = "slow", value = player.speedSlow, shift = keys.mask.shift },
  }

  for _, speed in ipairs(speeds) do
    for _, direction in ipairs(DIRECTIONS) do
      local diagonal = direction.dx ~= 0 and direction.dy ~= 0
      local factor = diagonal and (1 / SQRT2) or 1
      table.insert(candidates, {
        name = speed.name .. "-" .. direction.name,
        key = direction.key + speed.shift,
        vx = direction.dx * speed.value * factor,
        vy = direction.dy * speed.value * factor,
        cost = 0,
      })
    end
  end

  if previous_key ~= nil then
    for _, candidate in ipairs(candidates) do
      if candidate.key ~= previous_key then
        candidate.cost = candidate.cost + cfg.direction_change_cost
      end
    end
  end
  return candidates
end

local function expandBody(body, margin)
  local expanded = copyTable(body)
  if body.type == HitType.Circle then
    expanded.radius = (expanded.radius or 0) + margin
  else
    expanded.width = (expanded.width or 0) + margin * 2
    expanded.height = (expanded.height or 0) + margin * 2
  end
  return expanded
end

local function playerBodyAt(player, object_body, kind, x, y)
  local use_circle = kind == "ex" and object_body.type == HitType.Circle
  local body = copyTable(use_circle and player.hitBodyCircle or player.hitBodyRect)
  body.x = x
  body.y = y
  return body
end

local function isWarningLaser(body, cfg)
  return body.type == HitType.RotatableRect
    and (body.width or 0) >= cfg.warning_laser_min_length
    and math.abs(body.height or 0) <= cfg.warning_laser_max_half_thickness
end

local function isRelevant(player, body, cfg)
  -- Rotated rectangles are lasers and may cross the player while their origin
  -- is far away, so they must always pass the broad phase.
  if body.type == HitType.RotatableRect then
    return true
  end
  local extent_x = body.radius or ((body.width or 0) * 0.5)
  local extent_y = body.radius or ((body.height or 0) * 0.5)
  return math.abs((body.x or 0) - player.x) <= cfg.broad_phase_radius + extent_x
    and math.abs((body.y or 0) - player.y) <= cfg.broad_phase_radius + extent_y
end

local function scoreObject(player, object, kind, candidates, cfg, stats)
  local source_body = object.hitBody
  if source_body == nil then
    return
  end
  if kind == "ex" and object.hittable == false then
    return
  end
  if not isRelevant(player, source_body, cfg) then
    return
  end

  local warning_laser = kind == "bullet" and isWarningLaser(source_body, cfg)
  if warning_laser then
    stats.warning_lasers = stats.warning_lasers + 1
  end

  local base_x = source_body.x or object.x or 0
  local base_y = source_body.y or object.y or 0
  local vx = object.vx or 0
  local vy = object.vy or 0

  for frame = 1, cfg.prediction_frames do
    local body = copyTable(source_body)
    body.x = base_x + vx * frame
    body.y = base_y + vy * frame

    if warning_laser then
      body.height = math.max(math.abs(body.height or 0), cfg.warning_laser_virtual_half_thickness)
    end
    local near_body = expandBody(body, cfg.safety_margin)
    local time_weight = (cfg.prediction_frames - frame + 1) / cfg.prediction_frames

    for _, candidate in ipairs(candidates) do
      local field = cfg.field
      local raw_x = player.x + candidate.vx * frame
      local raw_y = player.y + candidate.vy * frame
      local x = clamp(raw_x, field.min_x, field.max_x)
      local y = clamp(raw_y, field.min_y, field.max_y)
      local player_body = playerBodyAt(player, body, kind, x, y)

      if warning_laser then
        if hitTest(player_body, body) then
          candidate.cost = candidate.cost + cfg.warning_laser_cost * time_weight
        end
      elseif hitTest(player_body, body) then
        candidate.cost = candidate.cost + cfg.collision_cost * time_weight
      elseif hitTest(player_body, near_body) then
        candidate.cost = candidate.cost + cfg.near_miss_cost * time_weight
      end
    end
  end
end

local function addPositionCosts(player, candidates, cfg)
  local field = cfg.field
  local horizon = cfg.prediction_frames
  for _, candidate in ipairs(candidates) do
    local raw_x = player.x + candidate.vx * horizon
    local raw_y = player.y + candidate.vy * horizon
    local x = clamp(raw_x, field.min_x, field.max_x)
    local y = clamp(raw_y, field.min_y, field.max_y)

    if raw_x ~= x or raw_y ~= y then
      candidate.cost = candidate.cost + cfg.boundary_cost
    end

    local wall_distance = math.min(
      x - field.min_x,
      field.max_x - x,
      y - field.min_y,
      field.max_y - y
    )
    if wall_distance < cfg.wall_margin then
      candidate.cost = candidate.cost + (cfg.wall_margin - wall_distance) * cfg.wall_cost
    end

    local dx = x - cfg.preferred_x
    local dy = y - cfg.preferred_y
    candidate.cost = candidate.cost + (dx * dx + dy * dy) * cfg.position_cost
  end
end

local function scoreList(player, objects, kind, candidates, cfg, stats)
  for _, object in ipairs(objects) do
    scoreObject(player, object, kind, candidates, cfg, stats)
  end
end

local function choose(game_side, state, cfg)
  local player = game_side.player
  local candidates = buildCandidates(player, state.last_move_key, cfg)
  local stats = { warning_lasers = 0 }

  scoreList(player, game_side.enemies, "enemy", candidates, cfg, stats)
  scoreList(player, game_side.bullets, "bullet", candidates, cfg, stats)
  scoreList(player, game_side.exAttacks, "ex", candidates, cfg, stats)
  addPositionCosts(player, candidates, cfg)

  local best = candidates[1]
  for index = 2, #candidates do
    if candidates[index].cost < best.cost then
      best = candidates[index]
    end
  end
  state.last_move_key = best.key
  best.warning_lasers = stats.warning_lasers
  return best
end

return {
  choose = choose,
}

