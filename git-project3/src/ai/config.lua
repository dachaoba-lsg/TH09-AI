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
    -- Keep a mature C1 briefly only when measured, ongoing stock gain can
    -- fund a wanted C2 soon. Static near-200 energy never proves a refill.
    c2_reserve_margin = 10, c2_reserve_max_frames = 18, c2_reserve_samples = 3,
    position_weight = 0.002, focus_mismatch_cost = 8,
    -- Local field is y=0..448. Highest allowed position is one third from
    -- the top, i.e. two thirds above the bottom. Physical walls stay unchanged.
    min_y = 150, idle_y = 320, c2_position_lead_frames = 90,
    -- Preserve the selected chain through capture/overlap preparation. Armed
    -- charges may wait briefly for shape, but never cross the next C level.
    prepare_max_frames = 90, armed_max_frames = 24,
    -- Recheck original C1 seeds at release. Already mature charges have only
    -- a short recovery window, always ending before the next charge level.
    c1_revalidate_max_frames = 8,
    -- 3.0 bloom (energy) mode. While the own field is dense, keep a PVP-style
    -- C2 rhythm (one release per few seconds) instead of waiting for an ideal
    -- chain. Observed PVP recordings: both players released a charge attack
    -- every 3.2-4.8 s and the denser the field, the faster the rhythm. The
    -- opponent gauge is a read-only native sub-snapshot and only relaxes the
    -- entry threshold when our gauge is clearly ahead; it never triggers an
    -- attack. These are observed candidates, not a net-energy guarantee.
    bloom_enter_bullets = 160, bloom_exit_bullets = 110,
    bloom_c2_interval_frames = 260, bloom_energy_floor = 100,
    bloom_exit_cycles = 2, bloom_min_net_fraction = 0.15,
    bloom_c2_enemies = 2, bloom_c2_bullets = 4, bloom_c2_score = 2.5,
    bloom_opponent_margin = 100, bloom_opponent_lead_bullets = 40,
    -- Entry timing: the game rank is unreadable and player-specific, so use the
    -- field. After bloom_late_seconds of battle time, entry/exit thresholds
    -- drop; earlier, a self-calibrated mean erasable-bullet speed ratio
    -- (relative to the slowest observed) acts as a rank proxy.
    bloom_late_seconds = 180, bloom_late_bullets = 60, bloom_late_exit_bullets = 40,
    bloom_speed_ratio = 1.35, bloom_speed_bullets = 90, bloom_speed_exit_bullets = 60,
    -- Movement-cap coupling (see dodge.move_change_*): consecutive frames the
    -- cap overrode a better escape before the policy answers with a charge
    -- attack, and the shortened C2 deadline used while that pressure holds.
    move_cap_escape_frames = 4, move_cap_pressure_max = 30, move_cap_decay = 1,
    move_cap_escape_interval = 120,
    -- 3.1 attention-overload pressure (dodge.attention): how many consecutive
    -- overloaded callbacks precede the charge-attack answer.
    attention_escape_frames = 6, attention_pressure_max = 30, attention_pressure_decay = 1,
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
    },
  },

  -- Local, deliberately limited-horizon dodge planning. This keeps the AI
  -- fallible against long-term traps such as several converging C3 shots.
  dodge = {
    prediction_frames = 12,
    -- 3.0 human-like movement cap. The uncapped planner would re-decide a
    -- direction almost every frame; a person cannot. Direction changes are
    -- limited by a rolling budget plus a minimum dwell time, and the dodge
    -- result reports when the cap overrode a better escape (move_cap_forced /
    -- move_cap_risk) so the bloom policy can answer with a charge attack.
    move_change_window = 60, move_change_budget = 6, move_change_min_frames = 5,
    -- Shared perception for dodge AND C resource/target selection. TH09's
    -- single playfield is 448 units high, independent of window scaling.
    vision_radius = 448 / 3,
    -- 3.1 human attention limit: a person can only keep a few incoming objects
    -- in mind at a time, and fast objects cost more attention than slow ones.
    -- Objects that are not admitted are invisible to the route search, so a
    -- wave that needs more attention than this can be missed on purpose; the
    -- overload is also reported so the policy can answer with a charge attack.
    -- Explicit attention_capacity/attention_recovery_per_second settings
    -- override presets. mech disables attention, but still obeys vision/movement.
    -- 3.2 difficulty scale. Tiers are named after the survival time they are
    -- originally intended for, not guaranteed lifetimes. Capacity and acquisition rate are
    -- in "standard white bullet" units. Measured on a real 101 s match, a
    -- typical loaded bullet of the field costs about 1.4 units and the dodge
    -- sees 11 relevant objects at the median and 31 at p90 (15 / 44 units), so
    -- the old 5-unit budget was several times too small.
    attention = {
      enabled = true,
      difficulty = "human200",
      -- plan_interval 1: look at the field every callback. The "a person re-reads
      -- the screen a few times a second" effect comes from threat_per_second
      -- (acquisition rate), which is host-independent. Larger intervals delay
      -- selection of new targets; selected IDs still bind to fresh geometry
      -- every callback, including hosts that reuse or rebuild object tables.
      threat_per_second = 19.0, tracked_threat = 26.0, plan_interval = 1,
      reflex_radius = 10, urgent_frames = 24, blind_urgent_limit = 3,
      -- "In front of me": an object matters when it passes within this radius
      -- (game units) during the horizon, even if it would miss a standing player.
      sight_radius = 20,
      overload_frames = 6, overload_action = "c_then_panic",
      -- Cost of one object in "standard white bullet" units:
      --   clamp((( |v| ) / speed_reference) ^ speed_exponent, min_cost, max_cost)
      --   times a width factor for long objects (EX sticks block more space).
      speed_reference = 1.5, speed_exponent = 1.0,
      width_reference = 128, width_max = 2.5, min_cost = 0.5, max_cost = 6,
    },
    -- Survival-time tiers (Lunatic baseline). "unlimited" keeps the human shape
    -- (sight radius, look interval) but not the budget; "mech" removes the limit
    -- altogether and is the calibration reference.
    -- Anchored on the measured demand of a real 10-minute match (mech, 627 s):
    -- objects_relevant median 21 / p90 41 -> about 29 / 57 threat units, with
    -- minute 1 already at 24 and minute 10 at 32. A tier is therefore usable
    -- only if its capacity approaches that demand, which is why the 3.2.0
    -- ladder (4..36) was far too small.
    attention_presets = {
      mech = { enabled = false },
      human45 = { tracked_threat = 6, threat_per_second = 5 },
      human90 = { tracked_threat = 9, threat_per_second = 7 },
      human120 = { tracked_threat = 12, threat_per_second = 9 },
      human150 = { tracked_threat = 16, threat_per_second = 12 },
      human180 = { tracked_threat = 20, threat_per_second = 15 },
      human200 = { tracked_threat = 26, threat_per_second = 19 },
      human240 = { tracked_threat = 32, threat_per_second = 24 },
      human300 = { tracked_threat = 40, threat_per_second = 30 },
      human480 = { tracked_threat = 55, threat_per_second = 40 },
      unlimited = { tracked_threat = 120, threat_per_second = 90 },
    },
    -- 3.1 names kept working for existing settings files.
    attention_aliases = {
      novice = "human45", casual = "human120", human = "human200",
      veteran = "human300", pro = "human480", infinite = "unlimited",
    },
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
