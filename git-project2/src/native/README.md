# TH09-AI native support (0.1.9 compatibility layer, extended read-only for 2.0.5)

Only the known Japanese v1.50a executable and original ka_ai_duka v1.7 DLL
are supported. Their original disk files remain unchanged. The launcher creates
its own suspended process, verifies every original instruction, loads the
original AI DLL, applies checked memory patches, injects window_support.dll,
then resumes the main thread. Any mismatch ends only that newly-created launch.

The laser correction introduced in 0.1.8 remains: laser_sensor.c/.h compensates
for upstream Laser::Update positioning the
AI-facing hitBody without raw.length1 and exports fixed-zero vx/vy. After checking
the expected original function and vtable in the loaded inject.dll, the sensor
hook corrects the exported origin to `origin + length1 * (cos(angle), sin(angle))`.
Installation happens during suspended startup. This changes only perception
passed to the AI: game laser physics, damage/HP and the original DLL on disk
are not modified by the sensor.

Only managed hitBody.x/y are corrected. Width remains length2-length1, height
remains raw thickness/2, angle and Bullet.x/y remain unchanged, and exported
vx/vy remain zero. Lua must use corrected hitBody history rather than the
unchanged object origin to estimate movement. The support worker installs the
sensor before practice initialization and before signaling the launcher's ready
event; failure prevents the launcher from resuming the game.

Diagnostics are written to runtime/native-window.log:

```text
laser_sensor: install=ok managed segment anchor corrected; game physics unchanged
laser_sensor: install=FAILED reason=...
```

The CSV adds laser_count (all bullet RotatableRect records), tracked_lasers
(valid consecutive-frame identity/history, including stationary lasers),
dynamic_lasers (tracked records with nonzero effective geometry change),
laser_sweep_tests (dynamic laser candidate/interval tests), and
laser_history_resets (continuous histories rejected for excessive geometry
jumps). First sightings or missing-frame history do not count as resets.
The first three counts include distant lasers; sweep tests count one tested
candidate interval even when it includes both hard-collision and near-miss
checks. No new player-facing
configuration fields are required; debug_log remains false by default.

The matching Lua layer tracks stable IDs across consecutive frames to estimate
hitBody origin, length, thickness and angle changes for limited-horizon laser
prediction. Rotation uses conservative sweeps over a bounded number of adaptive
time intervals. Regular bullets retain the optimized continuous path. Non-hittable
Marisa EX white-light emitters are not solid obstacles, and zero-thickness lasers
remain soft warnings at every length; warning_laser_min_length only controls
additional virtual thickness, never whether a zero-height record is a hard
collision. The native sensor and Lua change must ship together;
replacing dodge.lua alone is incomplete. Use the complete 2.0.5 package (including the bloom Lua modules) and keep
the old 2.0.4, 2.0.3, 2.0.2, 2.0.1, 2.0.0 and 0.1.9 ZIPs separately.

Version 0.1.9 adds read-only sensing of effective poisoned movement speed,
temporary protection and recharge-related state. The corresponding Lua planner
models Medicine poison as nonlethal slowing terrain, uses effective speed for
candidate paths, and accounts for danger after protection expires. The sensor
does not change game poison, protection, recharge or HP values and does not
grant 2P protection. The user confirmed the 0.1.9 poison test passed; this
historical feedback does not validate the 2.0.1 bloom correction in live play.

player_sensor.c/.h appends a Lua-owned `player.sensor` table after the verified
upstream player export. It never writes the raw game player, poison or EX
objects. The interface is:

| Field | Meaning |
| --- | --- |
| `apiVersion`, `valid` | Interface version 1 and snapshot validity. The AI requires both the matching version and a valid snapshot. |
| `state` | Raw player state. Only recognized state 3 supplies temporary protection; state 4 does not automatically grant it. |
| `protectionFrames` | Raw nonnegative state-3 remaining protection, otherwise zero. Game timer units, not wall-clock seconds. Avoidance uses `max(floor(value) - 1, 0)`: round down, then restore danger one update early because the game decrements before movement. A raw value of 1 does not exempt a collision. |
| `baseScaleX`, `baseScaleY` | Persistent additional movement multipliers before local poison overlap is applied. |
| `moveScaleX`, `moveScaleY` | Movement multipliers recomputed at the current snapshot position using active poison clouds; not measured displacement or proof of the multiplier applied in the previous update. |
| `canCharge` | Whether the current action/cut-in/game gates permit charging, independent of whether Z is held. |
| `chargeBlockFrames` | Remaining action-related charge block in game timer units; excludes initial held-Z warm-up. A still-set block reports at least one unit. |
| `chargeWarmupFrames` | Remaining initial held-Z warm-up, exported separately from the action block. |
| `cutIn`, `movementEnabled` | Cut-in flag and recognized movement gate. |
| `timeScale` | Current game timer scale; exported for diagnosis. The current planner uses effective update units, without a dedicated low-frame-rate or time-stop strategy. |
| `poisonClouds` | Settled Medicine clouds for this side, each with `x`, `y`, `radius`, `age`, `ageInt`, `framesLeft`, `active`. Flying seeds and faded clouds are not damage obstacles. |

Cloud radius is 64 internal units with a strict interior test. An active cloud
multiplies movement by 0.4, including multiplicative overlap. Integer age must
be greater than 20 and less than 300 to apply poison. Lua predicts local entry,
exit, activation and expiry across its existing horizon, merging equal-speed
route segments. Future activation/expiry uses the floating age at 21 and 300.
Poison motion uses at most 12 prediction steps; a configured horizon longer than
the default 12 uses coarser steps, not more steps. Other EX hazards retain their
existing damage handling.

Missing/invalid/version-mismatched snapshots release all AI keys and print
`TH09-AI: player sensor unavailable/invalid; AI input released.` with package
and log guidance. This is not a fallback to the old poison-blind policy. The
operation-limit latch still takes precedence. A runtime invalid-snapshot frame
does not produce a normal decision CSV row; retain the console error as well.
Installation logs are:

```text
player_sensor: install=ok api=1 readonly snapshot; poison recomputed, C gate exported
player_sensor: install=FAILED reason=...
```

An installation failure prevents game resumption. This differs from a transient
runtime-invalid snapshot, which releases AI inputs rather than terminating the
running game. No new user-facing configuration fields are introduced.

The CSV adds sensor_valid, move_scale_x, move_scale_y, protection_frames,
can_charge, charge_block_frames, poison_clouds, movement_segments and player_state.
protection_frames retains the recognized raw value for diagnosis, not the
planner's one-update-shorter protection. poison_clouds counts reachable clouds
that can be active within the horizon; movement_segments totals parsed route
segments for all movement candidates (17 in the baseline, 18 with bloom intent).
These are not total scene cloud counts or
executed movement counts.

## C2 follow-up read-only extension (2.0.5)

The core player.sensor apiVersion remains 1. followupApiVersion=1 adds the
following Lua-owned values without writing game state:

| Field | Meaning |
| --- | --- |
| canPressZ | Input/global/state gate ignoring only the C1 charge-block bit 4; all other checks remain. Distinct from canCharge; it does not prove a new C1 was created. |
| c1ActionActive, c1ActionAge, c1ActionDuration | Current role-action status, age and feature duration in game Timer units. |
| commonWavesValid, commonWaves | Independent snapshot of this player's circular common type-1/type-4 effects. Each has slotId, type, x, y, radius, growth, life, delay, enabled and listed. |
| c1Profile.valid, limited, actionDuration, shots | Selector-1 SHT firing records for this role. Each record has spawnTick, offsetX/Y, width/height, angle, speed, damage, type, supported and piercing. |
| c1Profile.activeValid, activeShots | Current shots whose template pointer belongs to that selector. Entries have slotId, x/y, width/height, vx/vy, age, type, damage, supported, damageReady, piercing and currentGeometryOnly=true. |

The effect collector validates pool bounds/alignment, duplicates, pointer-table
counts and a separate fallback slot. listed distinguishes effects currently
linked into the engine's update list from an enabled fallback outside it.
Ordinary count excludes that fallback; reading count alone would miss it.
At most 512 effects are exported; slotId is a reusable pool slot, not an event
ID. life and delay are remaining integer circle updates.
These are common effects, not unique C2 event IDs. Delayed/unlisted effects must
not be treated as a currently clearing circle. Each sub-snapshot has its own
validity; unreadable waves/profile/active shots do not become an empty safe
scene, nor invalidate unrelated valid poison/movement data.

Template prospective coverage requires supported generic records without custom
spawn/motion/hit callbacks. Active-shot current AABBs can support custom motion
only when the current hit callback is generic; they do not promise a future
linear path. A supported active object must also have damageReady=true to
contribute a current hit. In particular, type-2 attacks skip damage on odd
integer Timer ticks; geometry alone must not promise an immediate ignition.
The AABB is axis-aligned; template angle describes projectile
motion, not a rotated damage box. Damage/HP, custom callbacks and propagation
are not simulated into guaranteed kills. Non-piercing shots cannot claim every
enemy along a lane. Partial profiles retain explicit limited flags/fallbacks.

The original Marisa selector-1 record uses custom spawn/update callbacks, so
its unfired template remains limited. After emission, its generic hit callback
allows the current AABB (including callback-updated dimensions) to contribute
only on damage-ready updates. This is not a complete prospective Marisa C1
model or a claim that all 16 characters have exact future coverage.

When c1ActionActive is true, elapsed spawn records are not replayed. Existing
active shots plus remaining spawns describe this action's remaining effect;
obs.c1.remaining_only cannot fund a fresh 100-charge C1. A new Z request is
logged separately from charge release requests and is not proof of re-spawning
the complete selector-1 pattern. Only the real canCharge gate permits charging.

C2 release requests create pending association only. Fresh charge reset plus
new protection/action or a matching new common wave establishes the follow-up
window; old protection, stale charge or a request alone does not. The normal
72-update fast interval may fall to 24 only in a confirmed C2 window with enough
live protection; actual Shift budget 40/180 and single-window maximum 32 remain.
Protection comes exclusively from live state3 and max(floor(raw)-1,0). Other states do not
inherit a planned C2 shield. Hit/reset and expired live protection end the window.

Actual active listed type-1 wave geometry excludes potentially swallowed whites
from resource accounting. The ordinary isErasable field is not a reliable C2
cancelability flag: C2 clearing has its own conditions. No such estimate removes
an EX, laser, ordinary bullet or enemy from dodge. The fixed C2 common wave grows
by 4, last active radius is 188 and life is 48; radius 192 is a conservative
contested-yield envelope, never proof of cleared space.

For intent.protected_followup=true, valid apiVersion1/state3 at timeScale=1 may
add an endpoint reservation check through live protection expiry plus 4 updates,
bounded at 60. The original 12-update physical movement segments are unchanged;
the separate tail means hold that endpoint, not continue the direction for 48
updates. Current collision-free/terrain/soft-risk eligibility is preserved.
Protected hard hazards can be culled before expiry, but expiry tangency and
warning lasers are preserved; poison determines the actual short endpoint.
No verified endpoint falls back to immediate geometric evasion. Above-limit
height recovery, non-normal time scales, missing/expired protection and windows
outside the bound use the existing path without certifying an endpoint. This
finite forecast cannot guarantee survival in later unseen patterns.

The observer separately ranks capture chains, ordinary ignition, actual C1
coverage and suggested C1 positions. Actual and proposed yields do not alias.
Fast capture approach is bounded at 60 updates with retry spacing, total
preparation at 90, and optional charge-band holding at 24. The independent
480-Timer C2 deadline overrides optional capture/shape waiting; C1 never resets
it. C2 charged+chargeSpeed reaching 300 (C1 reaching 200) ends waiting regardless
of current Max. Y>=150, no X, C1/C2-only decisions and original game physics
remain. Version 3.0 is postponed.

Version 2.0.5 has 104 CSV columns, retaining the prior 88 and adding:
`capture_preferred`, `capture_value`, `capture_chain_bullets`, `c1_model_valid`, `c1_model_limited`, `c1_chain_bullets`, `c1_hit_count`, `common_waves_valid`, `common_wave_count`, `can_press_z`, `c1_action_active`, `followup_confirmed`, `followup_z_requests`, `followup_protection`, `protected_route_checked`, `protected_route_collides`.

Capture and C1 fields are planning estimates; model_limited reports incomplete
coverage. Common-wave counts describe eligible active listed type-1 circles,
not every effect or a native clear count. can_press_z and can_charge are distinct
gates. followup_confirmed associates a release request with live changes;
followup_z_requests is a separate Z-request counter, never an extra confirmed C1.
followup_protection is floor(raw protection)-1, clamped at zero.

protected_route_checked must be true before interpreting the endpoint result;
false collides with checked=false does not certify safety. The module also
returns protected_route_safe, horizon and work counters outside this CSV schema.
Old release counters remain requests. Position yields, chain timing and recharge
estimates are not observed kills/returns. A -1 exit time means no reliable
estimate, not unlimited waiting. Phase changes, releases and preparation
cancellation add event rows alongside the configured logging interval.

Final 2.0.5 regression/build/rebuild results must be taken from this delivery's
final record. This document does not predeclare the complete run passed or
claim user live acceptance, all-character exact C1 geometry or guaranteed FPS.

The game ignores saved VK/DIK arrays in keyboard modes. input_patches.h remaps
only LEFT (type 3) to J/K/L plus WASD in both native keyboard paths. FULL (type 2)
is unchanged. The launcher requires 1P FULL and selects 2P LEFT in a backed-up
configuration. Do not change Type inside the running game: its original Option
UI assumes FULL and LEFT conflict. The remapping exists only when AI is launched.

The 2P Lua send wrapper's RVA 0x1DAAE changes exactly one opcode, OR to MOV.
Its input transition calculations remain intact; 1P, replay, and original DLL
on disk are unchanged. Therefore physical Z/X/directions and also physical
2P keys cannot add actions to a successfully running AI battle, including after
the configured battle-limit zero-input latch. Selection menus still use separate
physical keys.

2P must use Option Charge Type = Slow (hold shot/Z to charge; Shift selects
slow movement). Charge mode reverses that behavior and is unsupported. Lua
releases AI input when it detects explicit Charge mode and asks the player to
switch 2P to Slow; it does not change 1P's setting or add a JSON field.

The top-level launcher-settings.json field seconds is an integer from 0 through
86400, default 600. Zero disables the time limit. The AI counts battle
callbacks / 60; reaching the limit releases all AI input until
the next battle. Restart after changing JSON settings. The launcher generates
ai/runtime-settings.lua at startup; this file is not a user-editable setting.

The native window module publishes its subclass from a worker in the same
process; the window procedure continues to run on the owning GUI thread. It
handles native edge/corner hit tests, resize cursors, and sizing messages,
preserving unrelated original messages. TH09 can destroy its initial HWND
during startup, so the worker checks every 500 ms, waits for three stable
observations, and retries after invalid handles. Destruction of an attached
window triggers discovery and attachment of its replacement. The initial size
is applied once per new HWND; ordinary monitoring never undoes the user's drag.

Window installation and completed sizing events are logged to
runtime/native-window.log. The old one-shot PowerShell window helper is not
started. Default client size is 960x720. Native edge and corner dragging keeps
4:3 by default; window.keep_aspect=false permits independent width and height.
window.resizable=false disables dragging; window.enabled=false skips window
adjustments. Change settings with the game closed and restart the AI launcher.

Optional practice settings in launcher-settings.json affect only 1P:

```json
"practice": {
  "player1_no_damage": false,
  "player1_invincible": false
}
```

Both default to false. player1_no_damage preserves normal hit reactions and
leaves 1P's HP completely unchanged on every hit, including at 1 HP; it does not
merely clamp depleted health to 1. player1_invincible prevents the hit reaction
and damage, but contact still breaks the Spell Point combo. If both are true,
invincible takes precedence. Neither option grants protection to the 2P AI.
Practice patches are independent of window.enabled and apply only to the
AI-launched process; restart after changing either option. Do not inject thprac
alongside this package: both can modify the same game instructions and window
procedure.

For the public package, start with `source/BUILD.md` and the supplied
`rebuild-from-package.ps1`. From the original developer workspace, build using
`powershell -File build-native.ps1`, then `build-public-package.ps1`.
Compiler: portable TinyCC 0.9.27 **win32**, extracted under
work/win32-toolchain/tcc. Official package:
https://download.savannah.gnu.org/releases/tinycc/tcc-0.9.27-win32-bin.zip
SHA256: 02E2BFE8C272A549B15E4BFA4507BD7E05304692AF1761DB6C1E8E88AF675651
No compiler executable or game assets are redistributed in the player package.
TinyCC startup runtime objects are linked into our binaries. The public package
therefore includes the matching complete TinyCC source archive and LGPL terms,
plus this project's source/build scripts for relinking; see the third-party
notices and source/BUILD.md. The TinyCC source is not covered by our MIT license.

Version 2.0.7 additionally appends `enemy.sensor` through the verified upstream
SetEnemyFields bridge, bound to that exported enemy rather than matched by
screen position. It supplies health, current shot collision/damage gates,
damage divisor and primary hitbox. Unknown secondary collision geometry and
mixed protection rules are explicitly limited. Reimu selector-1 records expose
`motionModel=reimu_c1_homing`; the C1 profile exposes validated current homing
coordinates (enemy hitbox centre). Generic template support remains false for
this custom callback. Lua uses a separate bounded damage/trajectory forecast.
Both player/enemy bridges and game fingerprints must match before installation.
Upgrade Lua and this module together; these fields are estimates' inputs, not
native-confirmed future kills. Current C1 active objects still supply only their
current AABB to the conservative damage check.

Tests: tests/native_input_test.py emulates the real game reader; tests/
native_setkeys_test.ps1 executes the real patched input instructions in private
test memory; native window tests exercise only their own hidden windows.
build-native.ps1 also builds and runs laser_sensor_selftest.c. Its isolated
missing-library test deliberately prints
`laser_sensor: install=FAILED reason=verified upstream inject.dll is not loaded`
before reporting PASS. That expected rejection tests failure handling; the same
failure in an actual game's native-window.log still means startup must stop.
The build also compiles and runs player_sensor_selftest.c for read-only cloud
collection, lifetime/radius/overlap boundaries, protection and charge-gate
separation, invalid-input rejection, Lua table output, and the real x86 bridge
using isolated test memory. No game battle is run by these selftests.
window_resize_selftest.c also supports loading the implementation from a real
DLL and installing it from another thread. Tests cover all eight edges/corners,
4:3 and free sizing, destruction during installation, attachment to a replacement
HWND, and retaining changed dimensions on repeated installation checks.
`th09ai-launcher.exe <game-path> --verify-suspended` verifies the complete
injection path but never resumes the game or creates its game window. This is
not a replacement for a real selection/battle/mouse-drag acceptance test.
Earlier releases passed launcher, Lua, machine-code simulation and owned-window
regressions. Earlier user acceptance confirmed dragging and invincibility, with
two protected hits still at HP 10 in no-damage logs. These are prior-version
observations. The user subsequently confirmed the 0.1.9 poison test passed;
none of these results establish live acceptance of the 2.0.1 C2 correction.

Completed 0.1.9 checks: 432 player-sensor selftest assertions; owned-window and
laser selftests; 6 real upstream x86 player-export relocation cases; 36 laser
machine-code cases; input isolation over 256 single keys and 128 combinations;
65,536 set-key cases; 12 two-sided practice combinations; 4 suspended-start
support combinations with successful player/laser sensor installation; 497
launcher assertions and 65 path assertions. JSON seconds propagated through
the real launcher to the Lua 60-active-callback input-stop latch successfully.
The suspended-start checks never created a game window or sent game input.
The 2.0.1 C2 ignition/yield correction still needs live checks. Collect video,
ai/ai_debug.csv and runtime/native-window.log for failures.
Geometry/prediction simulations cannot guarantee survival against every attack.
