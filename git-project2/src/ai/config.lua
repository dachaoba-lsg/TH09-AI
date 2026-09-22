-- TH09 AI behavior configuration.
-- This file is loaded once at the beginning of every battle.

return {
  -- AI operation duration is configured only by the top-level "seconds"
  -- value in launcher-settings.json. Do not duplicate that setting here.

  -- All characters share this deterministic bloom policy. Distances and
  -- scores are conservative planning heuristics, NOT game blast radii or
  -- guarantees that a particular chain refills the next C2.
  bloom = {
    c1_score = 3, c1_enemies = 2,
    -- C2 bullet thresholds count enemy/spirit-chain resources only. Directly
    -- swallowed or timing-contested white bullets provide zero budget.
    c2_score = 4.5, c2_enemies = 3, c2_bullets = 8,
    c2_future_ratio = 0.65, c2_future_enemies = 2, c2_future_bullets = 4,
    -- Prefer shots/C1 over an early C2 dominated by direct/contested erasure.
    -- The independent eight-second deadline still overrides this preference.
    c2_min_net_fraction = 0.35,
    shot_score = 2.2, shot_enemies = 2,
    future_wait_ratio = 1.35, future_wait_gain = 1,
    -- Prefer Shift released to preserve fairy-team supply. Capture windows
    -- have a dwell limit, a fast interval, and an ACTUAL Shift-output budget.
    focus_value = 0.7, focus_min_frames = 8, focus_max_frames = 32,
    fast_min_frames = 72, focus_budget_frames = 40, focus_budget_window = 180,
    focus_alignment = 42, focus_reach = 180,
    shot_burst_frames = 8, shot_settle_frames = 18,
    release_settle_frames = 12, recharge_observe_frames = 150,
    -- Release goal: one C2 per 8 seconds of game time when chargeable/funded.
    -- C1 never resets this clock; below 200 energy C1 keeps the same cadence.
    -- Deadline charges may proceed without an ideal chain. No danger trigger.
    max_c_interval_frames = 480, cadence_margin_frames = 2,
    -- Dense, shape-valid fields may use a shorter C2 cadence. The deadline
    -- remains bounded and the observer still supplies the actual ignition.
    bloom_c2_interval_frames = 260,
    bloom_c2_hot_interval_frames = 200,
    bloom_c2_enemies = 2, bloom_c2_bullets = 4, bloom_c2_score = 2.5,
    bloom_c2_min_net_fraction = 0.15, bloom_c2_hot_bullets = 16,
    position_weight = 0.002, focus_mismatch_cost = 8,
    -- Local field is y=0..448. Highest allowed position is one third from
    -- the top, i.e. two thirds above the bottom. Physical walls stay unchanged.
    min_y = 150, idle_y = 320, c2_position_lead_frames = 90,
    -- Post-C2 route preferences: y grows toward the bottom. These do not
    -- remove hazards or override the existing height line.
    post_c2_low_y = 360, post_c2_mid_y = 285,
    post_c2_pressure_bullets = 12, post_c2_phase_frames = 72,
    post_c2_position_weight = 0.003,
    -- Preserve the selected chain through capture/overlap preparation. Armed
    -- charges may wait briefly for shape, but never cross the next C level.
    prepare_max_frames = 90, armed_max_frames = 24,
    -- Fast travel precedes a brief capture; a blocked route cannot lock fire
    -- forever. A post-C2 request must acquire real native confirmation.
    capture_approach_frames = 60, followup_confirm_frames = 8,
    protected_focus_fast_min_frames = 24,
    c1_return_advantage = 1.25,
    observer = {
      -- Adjacency/resource neighbourhoods; these do not modify game physics.
      link_radius = 64, bullet_radius = 48, focus_radius = 64,
      above_range = 250, below_range = 8, alignment_width = 24,
      -- main uses remaining charge time for a 12..60-update local forecast.
      max_enemies = 128, max_candidates = 12,
      release_min_y = 150, release_step = 48,
      swallow_weight = 0.08, travel_weight = 0.002,
      -- Search all release sites every six callbacks. Actual/cached-site
      -- resources are still assessed from the current snapshot each callback.
      position_search_interval = 6,
      -- Reimu: bounded verified custom-motion forecast incl. 40-Timer delay;
      -- damage/activation gates and impact-time resources still limit credit.
      reimu_c1_prediction_updates = 90,
    },
  },

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
