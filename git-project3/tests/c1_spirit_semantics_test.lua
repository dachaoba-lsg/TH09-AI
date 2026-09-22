-- Regression of the observer's conservative C1 target model, not proof of
-- every character's real damage rules, enemy kills or returned energy.
-- Fixture shapes follow bloom_followup_observer_test.lua.
local observer = dofile('bloom_observer.lua')
local checks = 0
local function check(value, message)
  checks = checks + 1
  assert(value, message)
end
local function contains(list, id)
  for _, value in ipairs(list) do if value == id then return true end end
  return false
end
local function enemy(id, x, spirit, activated)
  return { id=id, enabled=true, x=x, y=220, vx=0, vy=0,
    isSpirit=spirit==true, isActivatedSpirit=activated==true,
    isBoss=false, isLily=false, isPseudoEnemy=false }
end
local function world(enemies, active)
  local template = { supported=true, spawnTick=0, offsetX=0, offsetY=-100,
    width=20, height=20, speed=0, angle=0, type=3, damage=10, piercing=true }
  local current = { supported=true, currentGeometryOnly=true, damageReady=true,
    x=0, y=220, width=20, height=20, vx=0, vy=0, type=3, damage=10, piercing=true }
  return { player={ x=0, y=320, character=1, speedFast=4,
    sensor={ followupApiVersion=1, timeScale=1, moveScaleX=1, moveScaleY=1,
      c1ActionActive=false, c1ActionAge=0, c1ActionDuration=30,
      commonWavesValid=true, commonWaves={},
      c1Profile={ valid=true, limited=false, activeValid=true,
        shots=active and {} or {template}, activeShots=active and {current} or {} } } },
    enemies=enemies,
    bullets={{ id='white', enabled=true, x=30, y=220, vx=0, vy=0, isErasable=true }} }
end
local function observe(scene)
  return observer.observe(scene, {}, { prediction_frames=20, link_radius=64 })
end

for _, active in ipairs({false, true}) do
  local source = active and 'current AABB' or 'prospective template'

  -- A supported shot directly covers the spirit centre. Unactivated spirits
  -- still cannot become C1 seeds; capture and C2 have separate eligibility.
  local r = observe(world({enemy('spirit', 0, true, false)}, active))
  check(r.c1.valid, source..': profile must be valid, not an unknown-profile fallback')
  check(not r.c1.has_ignition and r.c1.hit_count == 0,
    source..': unactivated spirit became a direct C1 ignition')
  check(#r.c1.seed_ids == 0 and r.c1.chain_enemies == 0,
    source..': ineligible direct spirit generated a C1 chain')
  check(r.c1.chain_spirits == 0 and r.c1.chain_bullets == 0,
    source..': unignited spirit was credited as C1 resources')
  check(r.capture.has_target, source..': direct-C1 rejection erased capture opportunity')
  check(r.c2.has_ignition, source..': C1 restrictions leaked into independent C2 eligibility')

  -- Changing only activation status makes the same geometric contact eligible.
  r = observe(world({enemy('spirit', 0, true, true)}, active))
  check(r.c1.has_ignition and r.c1.hit_count == 1,
    source..': activated spirit failed to become a C1 seed')
  check(#r.c1.seed_ids == 1 and contains(r.c1.seed_ids, 'spirit'),
    source..': activated-spirit seed identity was lost')
  check(r.c1.chain_enemies == 1 and r.c1.chain_activated == 1 and r.c1.chain_spirits == 0,
    source..': activation classification was not preserved')

  -- The fairy is covered; the unactivated spirit lies outside the shot AABB
  -- but inside the heuristic chain link. It is a relay, never a direct seed.
  r = observe(world({enemy('fairy', 0), enemy('relay', 30, true, false)}, active))
  check(r.c1.has_ignition and r.c1.hit_count == 1,
    source..': connected relay changed the number of direct hits')
  check(#r.c1.seed_ids == 1 and contains(r.c1.seed_ids, 'fairy')
      and not contains(r.c1.seed_ids, 'relay'),
    source..': unactivated relay was mislabeled as a direct seed')
  check(r.c1.chain_enemies == 2 and r.c1.chain_fairies == 1 and r.c1.chain_spirits == 1,
    source..': valid fairy ignition lost the unactivated relay')
  check(contains(r.c1.chain_ids, 'fairy') and contains(r.c1.chain_ids, 'relay'),
    source..': chain omitted a participating identity')
  check(r.c1.chain_bullets == 1, source..': potential chain white bullet was lost or double-counted')

  -- Eligibility alone cannot replace supported shot geometry. Unknown custom
  -- behavior must not be assigned the generic rectangle's predicted effect.
  local scene = world({enemy('spirit', 0, true, true)}, active)
  local profile = scene.player.sensor.c1Profile
  local shot = active and profile.activeShots[1] or profile.shots[1]
  shot.supported = false
  r = observe(scene)
  check(r.c1.model_limited, source..': unsupported behavior lost the limited marker')
  check(not r.c1.has_ignition and r.c1.hit_count == 0,
    source..': unsupported shot invented C1 coverage')
  check(#r.c1.seed_ids == 0 and r.c1.chain_bullets == 0,
    source..': unsupported shot funded a C1 chain')
end

-- The native bridge can expose a type-2 shot's geometry on a non-damage tick.
-- This tests the exported flag contract, not the game's native tick scheduler.
do
  local scene = world({enemy('spirit', 0, true, true)}, true)
  local shot = scene.player.sensor.c1Profile.activeShots[1]
  shot.type, shot.damageReady = 2, false
  local r = observe(scene)
  check(r.c1.valid, 'damageReady=false must not invalidate the entire profile')
  check(not r.c1.has_ignition and r.c1.active_hit_count == 0,
    'type-2 damage gap was treated as an active hit')
  check(#r.c1.seed_ids == 0 and r.c1.chain_bullets == 0,
    'type-2 damage gap funded a chain')
  shot.damageReady = true
  r = observe(scene)
  check(r.c1.has_ignition and r.c1.active_hit_count == 1,
    'damage-ready type-2 current geometry failed the positive control')
  check(contains(r.c1.seed_ids, 'spirit'), 'damage-ready seed identity was lost')
end

print('c1_spirit_semantics_test: PASS ('..checks..' checks; model rules only, no live damage guarantee)')
