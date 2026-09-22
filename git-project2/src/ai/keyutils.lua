-- Key masks used by ka_ai_duka. X is intentionally never exposed.

local M = {
  z = 2 ^ 0,
  shift = 2 ^ 2,
  up = 2 ^ 4,
  down = 2 ^ 5,
  left = 2 ^ 6,
  right = 2 ^ 7,
}

local function removeX(mask)
  mask = math.floor(mask or 0)
  -- X is bit 1 (numeric value 2). Strip it defensively even if a future
  -- caller accidentally includes it.
  if math.floor(mask / 2) % 2 == 1 then
    mask = mask - 2
  end
  return mask
end

local function withShot(move_mask, press_z)
  local mask = removeX(move_mask)
  if press_z then
    mask = mask + M.z
  end
  return removeX(mask)
end

local function send(move_mask, press_z)
  sendKeys(withShot(move_mask, press_z))
end

return {
  mask = M,
  removeX = removeX,
  withShot = withShot,
  send = send,
}

