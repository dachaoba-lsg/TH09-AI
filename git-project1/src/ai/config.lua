-- TH09 AI behavior configuration.
-- This file is loaded once at the beginning of every battle.

return {
  -- AI operation duration is configured only by the top-level "seconds"
  -- value in launcher-settings.json. Do not duplicate that setting here.

  -- Stop shooting at this Spell Point value and wait until it returns to 0.
  spell_point_stop = 500000,
  spell_point_resume = 0,

  -- Relative chances for C1, C2, C3 and C4. 25/25/25/25 is uniform.
  charge_weights = { 25, 25, 25, 25 },
  charge_thresholds = { 100, 200, 300, 400 },
  -- The threshold frame itself releases Z, so no extra release frames are
  -- needed by default. Increase this only if a specific setup misses releases.
  charge_release_cooldown_frames = 0,

  -- Local, deliberately limited-horizon dodge planning. This keeps the AI
  -- fallible against long-term traps such as several converging C3 shots.
  dodge = {
    prediction_frames = 12,
    -- Swept bounds automatically include object velocity and player travel.
    safety_margin = 4,
    warning_laser_virtual_half_thickness = 12,
    -- Minimum length for virtual padding; shorter zero-thickness lasers are
    -- still only soft warnings, never hard collisions.
    warning_laser_min_length = 36,
    -- Only exactly zero-height lasers are soft warnings. Any positive
    -- thickness is an active collision and cannot be ignored as a warning.
    collision_cost = 100000,
    near_miss_cost = 140,
    warning_laser_cost = 900,
    boundary_cost = 50000,
    wall_margin = 12,
    wall_cost = 8,
    direction_change_cost = 8,
    movement_cost = 0.03,
    preferred_x = 0,
    preferred_y = 320,
    position_cost = 0.00002,
    -- Laser-only history estimates consecutive-frame geometry changes.
    -- Linear motion/growth is continuous; rotating beams use up to 12 swept
    -- intervals (plus at most two dimension-zero boundaries). Ordinary
    -- bullets keep their constant-time analytic trajectory test.
    field = {
      min_x = -136,
      max_x = 136,
      min_y = 16,
      max_y = 432,
    },
  },

  -- Optional CSV diagnostics written beside main.lua.
  debug_log = false,
  debug_log_interval_frames = 30,
}
