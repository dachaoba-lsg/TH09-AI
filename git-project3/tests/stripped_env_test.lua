-- The game host (ka_ai_duka) runs Lua with a stripped environment: print is nil
-- and the os table may be missing entries. main.lua must still load and run,
-- otherwise the whole AI silently stops (regression: 3.2.0 died on a print call).
HitType = { Rect = 0, Circle = 1, RotatableRect = 2 }
player_side = 2
local real_print, real_dofile, real_open = print, dofile, io.open
local output, opened, sent = {}, {}, {}
local function columns(line)
  local result = {}
  for value in (line:gsub('\n', '') .. ','):gmatch('(.-),') do result[#result + 1] = value end
  return result
end
local cfg = real_dofile('config.lua')
cfg.debug_log, cfg.debug_log_interval_frames = true, 1
dofile = function(path)
  if path == 'config.lua' then return cfg end
  return real_dofile(path)
end
io.open = function(path, mode)
  if path == 'runtime-settings.lua' then return nil end
  if mode == 'r' then return nil end          -- numbered-fallback existence probe
  assert(type(path) == 'string' and path:match('^ai_debug_.+%.csv$'), 'unexpected I/O: ' .. tostring(path))
  opened[#opened + 1] = path
  return { write = function(_, text) output[#output + 1] = text end,
    flush = function() end, close = function() end }
end
function sendKeys(mask) sent[#sent + 1] = mask end
local player = { x = 0, y = 320, life = 10, spellPoint = 0, combo = 0,
  currentCharge = 0, currentChargeMax = 0, chargeSpeed = 10, speedFast = 4, speedSlow = 2,
  hitBodyRect = { type = HitType.Rect, width = 4, height = 4 }, hitBodyCircle = { radius = 2 },
  sensor = { apiVersion = 1, valid = true, state = 0, protectionFrames = 0, canCharge = true,
    chargeBlockFrames = 0, baseScaleX = 1, baseScaleY = 1, moveScaleX = 1, moveScaleY = 1,
    poisonClouds = {} } }
game_sides = { [2] = { player = player, bullets = {}, enemies = {}, exAttacks = {} } }
-- Strip the optional globals exactly like the host does.
print = nil
if type(os) == 'table' then os.date, os.clock = nil, nil end
local ok, err = pcall(function()
  real_dofile('main.lua')
  main()
  main()
end)
io.open, dofile = real_open, real_dofile
print = real_print
assert(ok, 'stripped environment broke main.lua: ' .. tostring(err))
assert(#opened == 1, 'debug csv must still be created without a clock: ' .. tostring(#opened))
assert(opened[1]:match('^ai_debug_custom%-%d+%.csv$'), 'expected the numbered fallback name, got ' .. tostring(opened[1]))
assert(#output == 3 and #sent == 2, 'main loop did not run twice under the stripped host')
local header = columns(output[1])
assert(#header == 162, 'column count changed under the stripped host: ' .. tostring(#header))
assert(header[1] == 'frame' and header[134] == 'hits_total' and header[149] == 'c2_ready_updates'
    and header[#header] == 'attention_enabled',
  'unexpected header shape')
print('PASS: stripped host environment (print/os.date/os.clock nil) still loads main.lua, writes a numbered debug csv and keeps running')
