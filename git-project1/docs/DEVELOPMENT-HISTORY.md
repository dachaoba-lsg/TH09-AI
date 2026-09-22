# TH09-AI

TH09-AI is a local 2P AI package for Touhou Kaeidzuka / Phantasmagoria of
Flower View v1.50a. It uses the redistributable ka_ai_duka v1.7 runtime and a new
Lua decision layer under `src/ai`.

Author: 圣诞老人的驯鹿-xunlu. The Chinese player manual is
`dist/TH09-AI/README.md`. Version 0.1.9 is the first Medicine-poison test release:
it adds read-only effective-speed and temporary-state sensing for route planning,
while retaining the 0.1.8 laser geometry correction and prediction.
Run `build-public-package.ps1` for a release that
includes the project source and third-party notices.

## License scope

The root MIT license applies to this project's original AI, launcher, native
helper source, build scripts and documentation. It does not relicense ka_ai_duka,
Lua, Boost, TinyCC runtime code, THprac material or the original Touhou game.
Third-party notices and exact applicable texts are in
`dist/TH09-AI/licenses/THIRD_PARTY_NOTICES.txt`. In particular, ka_ai_duka's author
permits redistribution with its LICENSE.txt; that file's Lua MIT notice is not
a blanket MIT grant for all of ka_ai_duka. The TinyCC startup code linked into
our EXE/DLL has separate LGPL terms; the public package includes corresponding
TinyCC source plus our buildable source and relinking instructions.

## Project layout

- `src/ai`: editable AI source.
- `dist/TH09-AI`: ready-to-copy test package.
- `vendor/ka_ai_duka-ver1.7-source`: exact upstream v1.7 source snapshot.
- `vendor/ka_ai_duka-src`: newer upstream master snapshot used for comparison.
- `vendor/ka_ai_duka_1_7_20150712.zip`: upstream release archive.

The package is designed to be copied as a `TH09-AI` subfolder beside
`th09.exe`. The launcher searches upward from its own parent directory for the
nearest `th09.exe`, allowing additional ZIP extraction wrapper directories.
It regenerates ka_ai_duka's absolute-path INI from the current location on every
launch, so moving the game/package does not retain an old installation path.

## Behavior contract

- Match Mode, Human vs Human, AI controls 2P.
- 2P must use the game's Option Charge Type = Slow: hold Z to charge and
  Shift for slow movement. The reversed Charge mode is unsupported; detecting
  it releases AI input and requests Slow mode. This does not change 1P's
  preference or add a JSON setting.
- Local limited-horizon bullet avoidance; it is intentionally not globally
  optimal and can be surrounded by converging C3 attacks.
- Uniform random C1/C2/C3/C4 by default. While energy is insufficient, tap Z
  on alternating frames for normal shots without deliberately charging.
- No X input under any circumstances.
- Stop shooting at Spell Point 500,000; resume only after it reaches zero.
- Stop all AI input at the configured battle limit (600 seconds by default),
  remaining stopped until the next battle. Count AI battle callbacks / 60,
  not wall-clock time. A limit of 0 disables the timer. Pause-menu scheduling
  has not been separately verified and is controlled by the original game.
- Treat every zero-height laser record as a soft warning; add configurable
  virtual thickness only when the warning meets warning_laser_min_length.

## Laser perception correction (0.1.8)

The upstream Laser::Update export omits the raw.length1 offset when positioning
hitBody and reports laser vx/vy as zero. The new laser_sensor.c/.h support checks
the original runtime function and vtable before installing an in-memory export
hook during suspended startup. It corrects the AI-facing hitBody origin to
`origin + length1 * (cos(angle), sin(angle))`. It does not alter the game's actual
laser physics, collision rules, HP, or the upstream DLL file on disk.
The original exported vx/vy remain unchanged; Lua derives motion from the
corrected hitBody history. Failed sensor validation prevents that launch from
resuming. See `runtime/native-window.log` for `laser_sensor: install=ok` or
`laser_sensor: install=FAILED reason=...`.

Lua associates stable laser IDs across consecutive frames and predicts short-term
changes in hitBody origin, length, thickness and angle. Rotation uses a bounded
number of adaptive time intervals for conservative sweeps. Ordinary bullets keep the
fast continuous trajectory path. Marisa EX's non-hittable white-light emitter is
not treated as a solid projectile; zero-thickness lasers remain soft warnings.

Upgrade with the complete 0.1.9 package: replacing dodge.lua alone omits the
native perception corrections and state sensing. Retain the old 0.1.8 ZIP as a separate rollback
copy. Random charge selection, tap shooting while energy is insufficient,
500,000-point shooting lock, no-X input, the default 600-second callback budget,
input isolation, practice options and window behavior are unchanged.

## First poison test release (0.1.9)

The native module reads effective poisoned movement speed, temporary protection
and recharge-related state without changing those game values. Lua treats
Medicine poison as nonlethal slowing terrain, predicts travel using effective
speed, and considers danger after temporary protection expires. This sensing
does not alter 2P HP, grant invincibility or remove poison.

The native/Lua snapshot must be valid and use apiVersion 1. A missing or invalid
snapshot releases all AI input and prints an error instead of silently falling
back to poison-blind movement. Recognized state-3 protection uses a conservative
remaining duration of max(floor(raw frames) - 1, 0) for avoidance; unknown states do not
grant assumed protection. Poison/protection handling adds no user configuration.

Random charge selection remains fixed; adaptive proactive C attacks and
high-level energy planning are not implemented. This is the first poison test
package, not a claim of completed real-battle acceptance or guaranteed survival.
Test with Medicine and retain a video, ai/ai_debug.csv and
runtime/native-window.log if the behavior is wrong. Existing game installations
are not automatically replaced when this release is packaged.

## Upstream runtime

The original inject.dll and legacy ka_ai_duka.exe in `dist/TH09-AI/runtime`
are copied unmodified from the author's release `ver1.7`. The additional
th09ai-launcher.exe and window_support.dll are built from this project's
src/native. Source and upstream license are included for audit.

## Launcher and controls (0.1.9)

`src/native` contains the x86 launcher, checked machine-code patches and native
window subclass. `src/launcher` contains the user-facing startup scripts.
The game ignores saved key maps in keyboard mode, so the native launcher
remaps its LEFT reader to WASD + J/K/L for selection while preserving 1P FULL.
The 2P runtime OR instruction becomes MOV in memory; physical input no longer
leaks into AI battles, including the configured time-limit stop latch. Logical shot is
still called Z in Lua. Original game and upstream DLL disk files are unchanged.

`launcher-settings.json` is the entry point for the top-level `seconds` field:
an integer from 0 through 86400, default 600; 0 means unlimited. It also controls
window size and optional 1P practice protection. Restart the AI launcher after
changing JSON settings. The launcher generates `ai/runtime-settings.lua` on each
start; do not edit that generated file by hand.

The default window is 960x720 with native edge/corner dragging and a 4:3 aspect
constraint. The DLL handles hit testing, cursor, sizing and limits on the game's
GUI thread. It detects startup HWND destruction and reattaches to replacement
windows without repeatedly resetting a user's chosen size. Internal resolution
remains 640x480. Use custom.exe for windowed mode. Native events are logged to
runtime/native-window.log.

`practice.player1_no_damage` and `practice.player1_invincible` both default to
false and affect only 1P. No-damage preserves normal hit reactions and leaves HP
completely unchanged on every hit, including at 1 HP. Invincible prevents the
hit reaction and HP loss while contact still breaks the Spell Point combo. If
both are enabled, invincible takes precedence. Do not inject thprac at the same
time. See src/native/README.md for build and diagnostic details.

## Performance and tests

The planner retains the 0.1.3 continuous swept intersection intervals and
conservative velocity-aware filtering. Candidate paths are clamped to the field;
poison entry, exit and lifetime changes can split them into additional
effective-speed segments, with adjacent equal-speed segments merged.
It scans all hazards, does not cap bullet lists, and prefers collision-free
paths before scoring soft preferences. Direction hysteresis reduces jitter.

Run `python tests/run_native_lua.py tests/mock_ai_test.lua` and
`python tests/run_native_lua.py tests/dodge_perf_test.lua` from this project.
The runner requires Lua 5.1 via lupa (local test dependency under work).
The benchmark compares against tests/fixtures/dodge_0_1_2.lua, with the exact
upstream hitTest shape convention implemented in the test. It measures the Lua
planner, not full game FPS or native memory-to-Lua export costs.

Optional ai_debug.csv includes decision milliseconds and work counters for
real battle diagnosis. In 0.1.8 it also includes laser_count, tracked_lasers,
dynamic_lasers, laser_sweep_tests and laser_history_resets; the player README
defines their scope. These counters distinguish available geometry history from
the amount of candidate-trajectory work, not the game's total frame time.
Version 0.1.9 adds sensor_valid, move_scale_x, move_scale_y, protection_frames,
can_charge, charge_block_frames, poison_clouds, movement_segments and player_state.
protection_frames preserves the recognized raw remaining protection for diagnosis;
avoidance conservatively restores danger one update earlier. The timeScale value
is sensed, but there is no dedicated low-frame-rate or time-stop strategy.
Windows launcher compatibility includes CMD CRLF,
PowerShell 5.1 UTF-8 BOM, and literal paths containing brackets and Chinese.

Prior releases passed launcher, Lua, machine-code and owned-window regressions;
the user confirmed window dragging and invincibility, with no-damage logs showing
two protected hits at HP 10. Those results do not constitute real-battle
acceptance for 0.1.9 poison handling.

Completed 0.1.9 checks include 432 player-sensor selftest assertions, owned-window
and laser selftests, 6 real upstream x86 player-export relocation cases, 36 laser
machine-code cases, 256 single-key and 128 input-combination isolation cases,
65,536 set-key cases, 12 two-sided practice combinations, and 4 suspended-start
support combinations with both sensors installed successfully. These suspended
checks did not create a game window or send game input. Launcher regression
passed 497 assertions and path regression passed 65; JSON seconds through the
real launcher to Lua's 60-active-callback stop latch also passed.

This first test release has no new poison-handling real-battle acceptance yet.
Test with Medicine; do not treat earlier videos, isolated simulations or
suspended startup as verification of every new in-game behavior. Automated
tests and live play remain distinct.
