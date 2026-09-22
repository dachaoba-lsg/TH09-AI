# DS-TH09-AI 3.3.0-test

本版将视野、注意力和避弹变向上限开放给玩家，暂缓按固定生存秒数标定难度；原预设名称继续兼容。

双击 `set-difficulty.cmd` 打开中文能力设置菜单，可以修改数值、切换预设、保存或放弃修改。下次通过启动脚本启动时生效。

| 设置 | 默认值 | 可调范围 |
| --- | --- | --- |
| 每秒避弹变向上限 | 6 | 1～10，整数 |
| 视野半径 | 149.333333333333 | 16～640 |
| 注意力容量 | 跟随预设；human200 为 26 | 1～256 |
| 每秒新纳入注意力额度 | 跟随预设；human200 为 19 | 0.1～256 |

视野以自机为圆心，默认半径为单侧游戏场地高度 448 的三分之一，使用游戏坐标单位，独立于窗口像素大小。避弹、放 C 的起爆目标、连爆收益与压力判断都只读取圈内对象。只要长激光／长条 EX 的真实当前形状伸进圆内就能看见；圈外对象不会因未来可能飞入而提前可见。已经跟踪的对象离圈后立即退出判断，视野圈随自机移动。自己的气槽、动作门、保护和对手气槽等状态读取保持正常。

“每秒”沿用 60 次战斗回调滚动窗口（正常 60Hz 约一秒），限制被感知危险下的方向切换；持续向同一方向移动不重复计数，平静走位不消耗该预算。原有最短变向间隔继续生效，因此开放到 10。圆形视野约束可用信息，连续移动仍可横穿场地。

注意力容量控制同时跟踪的威胁总成本；每秒新纳入额度控制发现新目标的速度。它们是速度、形状加权的威胁单位，不等于物理子弹颗数。激光、毒云和敌人沿用原有免预算处理，但同样受圆形视野限制。调低注意力会增加漏看，已有压力反馈仍受真实能量和蓄力动作门约束，不保证必放 C 或必定存活。

手动设置的注意力值优先于普通预设；通过菜单切换预设会清除这两个手动覆盖，保留视野、变向和其他设置。mech 默认关闭注意力限制，视野与变向仍有效；不再把 human200／300／480 名称作为存活秒数承诺。

也可在 `launcher-settings.json` 的现有 `ai` 对象中修改：

```json
{
  "difficulty": "human200",
  "move_change_budget": 6,
  "vision_radius": 149.333333333333,
  "attention_capacity": 26,
  "attention_recovery_per_second": 19
}
```

默认发行配置不写死两个注意力覆盖值，以便切换预设直接生效。手动只设置其中一个时，另一个继续跟随预设。原有 `sight_radius` 是近身威胁相关性参数，新圆形视野参数是 `vision_radius`。

CSV 扩为 162 列，前 149 个字段位置保持，追加视野半径、圈内／圈外对象数、实际变向预算和注意力设置。原始 bullets/enemies/ex_attacks 数量用于诊断对照；field_erasable 及链条收益现在来自圈内快照。保留 3.2.5 的计时、分轮与有界 C1 保蓄优化。

验证：30 套 Lua 回归通过，含硬圆视野 129 断言、玩家参数 12 场景／402 断言、真实主循环视野集成 9 场景／632 断言及 162 列 CSV。Windows PowerShell 5.1 设置菜单 67 项通过；实际 JSON→启动器→runtime→Lua 为 13 场景／413 断言，另有 27 项启动器边界检查。原生构建／自测通过，含 player sensor 58357 项。发行包与随包源码重建验收见最终交付记录。

发行包名称：`DS-TH09-AI-v3.3.0-test.zip`。旧发行包保留，2.0 不变。离线验证不代替实战测试。

---

以下为 3.2.5 及更早历史记录；当前参数、列数和范围以上文为准。

# DS-TH09-AI 3.2.5-test

本版修正开花计时、分轮状态与接近 C2 时的蓄力决策，保留 3.2.4 的视野身份和真实形状修复。

晚期开花的 180 秒现在对应 10800 个游戏 Timer 单位；切入与时停不累计有效时间。CSV 的 `battle_seconds` 改为真正的游戏秒数，旧日志同名列记录的是 Timer 单位，比较旧数据时须先除以 60。

检测到有效的 state5 分轮信号时，清除上一轮的规划、跟踪与统计缓存；整个接管会话的操作期限继续累计，不因分轮重新获得一份时限。CSV 扩为 149 列，原 134 个字段的名称和位序不变，新字段追加；`battle_seconds` 的单位修正是明确的语义变化。

C1 接近 C2 时只允许有界等待：必须已经持有蓄力、stock 至少 190，且连续 3 次观察到真实 stock 正增，C2 有用途，并按观测趋势预计 18 个 Timer 单位内能达到 200，才保留这次蓄力短暂等待。回能停止、动作门关闭、暂停、受击或达到等待上限都会退出；只有实际观察到 stock 达到 200 才能升级 C2。趋势不是回能来源或未来收益的保证，不能据此承诺必达 200 或必能保命。

当前 C1 模型把妖精和已固灵作为直接起爆候选；未固灵不能作为 C1 直接种子，但可作为已起爆连通链的潜在爆风中继。几何覆盖、链条收益与回能都不是确认击杀。新增回归约束的是当前模型规则，不证明所有角色真实 C1 都必杀或都不能直接打未固灵。

难度预算、新目标 6 帧纳入扫描设置与移动限制不变：human200 仍为同时跟踪 26／每秒新纳入 19，human300 为 40／30。扫描之间仍逐回调绑定已跟踪对象和刷新当前诊断。200／300 秒是待实战校准目标；本版不调整 2.0 或已有发行 ZIP。

验证：27 套 Lua 回归通过，包括 C1 目标语义 39 断言、分轮与诊断 129 断言、C2 保蓄 25 场景／367 断言、计时与阈值 8 场景／41 断言，以及 149 列 CSV、精简宿主和视野回归。原生构建与自测通过，含 player sensor 58357 项。发行包与随包源码重建的最终校验结果见交付验证报告；离线通过不等于实战存活时间已达标。

发行名称继续使用 `DS-TH09-AI`，目标文件为 `DS-TH09-AI-v3.2.5-test.zip`。

源码构建显式指定版本与包名：

```powershell
.\build-public-package.ps1 -Version 3.2.5-test -PackageName DS-TH09-AI
```

完整公开包在 `DS-TH09-AI/source` 内重建：

```powershell
.\rebuild-from-package.ps1 -CompilerPath '<完整 TinyCC win32 安装中的 tcc.exe 路径>' -Version 3.2.5-test
```

替换编译器占位符，保留外层 `DS-TH09-AI` 名称与完整目录结构；脚本从外层目录识别包名。构建脚本的旧默认版本不代表本版，须显式传入上述版本。

## 3.2.4 与更早版本记录

以下原文保留用于追溯；旧版参数、单位、列数、版本号和测试结论不表示 3.2.5 的现行结果，当前行为以上述说明为准。

# DS-TH09-AI 3.2.4-test

本版修复两处注意力视野问题：已跟踪对象按稳定 ID 在每次回调绑定到当前快照；视野相关性与避弹路线统一使用真实形状的扫掠边界，避免长条 EX 被中心／半径近似漏掉。新目标仍受扫描间隔、纳入额度和注意力预算限制；两次纳入扫描之间的当前诊断也逐回调更新。

本轮不调整难度数值：human200 仍为同时跟踪 26／每秒新纳入 19，human300 仍为 40／30。C 策略、阈值、移动限速和 134 列 CSV 格式保持。200／300 秒仍是待实战标定的目标，不能把修复或 mech 长局统计视为已达到目标的证明。

已完成 23 套 Lua 回归，包括新增 `attention_identity_geometry_test.lua` 的 14 场景／186 断言、既有注意力 91 断言、精简运行环境、主循环 134 列 CSV 和毒／激光覆盖；原生构建自测通过，含 player sensor 58357 项。最终打包／源码重建校验待本轮交付记录确认。本轮不改 2.0、不安装、不启动游戏。

沿用 `DS-TH09-AI` 名称以兼容旧安装，发行文件名为 `DS-TH09-AI-v3.2.4-test.zip`。

源码构建显式指定本版和包名：

```powershell
.\build-public-package.ps1 -Version 3.2.4-test -PackageName DS-TH09-AI
```

从完整公开包的 `source` 目录重建时，运行 `rebuild-from-package.ps1 -CompilerPath <本机完整 TinyCC win32 安装中的 tcc.exe 路径> -Version 3.2.4-test`，将占位符替换为实际编译器路径。脚本从外层目录识别 `DS-TH09-AI` 包名，请保留完整 `DS-TH09-AI/source` 目录结构。

## 历史说明

下文保留旧版背景；旧版本号、默认值、包名示例、诊断列数及测试结论仅作历史参考，当前版本以上述说明为准。

# TH09-AI

TH09-AI is a local 2P AI package for Touhou Kaeidzuka / Phantasmagoria of
Flower View v1.50a. It uses the redistributable ka_ai_duka v1.7 runtime and a new
Lua decision layer under `src/ai`.

Author: 圣诞老人的驯鹿-xunlu. The Chinese player manual is
`dist/TH09-AI/README.md`. Version 2.0.5 is the bloom follow-up test release. It replaces
random C1-C4 and the 500,000-point firing lock with resource-aware C1/C2 play
for every character, retaining the established poison and laser avoidance.
Run `build-public-package.ps1` for a release that
includes the project source and third-party notices.

## Capture approach and C2 follow-up (2.0.5)

All characters retain deterministic bloom behavior, short selective Shift
windows and high-speed fairy supply. The observer now evaluates spirit capture
separately from ordinary ignition, including its connected chain and nearby
white bullets. A useful off-axis capture gets a bounded high-speed approach
before Shift; an existing preparation lock no longer prevents capture after
alignment. Merely having 200 energy cannot overwrite that goal with an
unprofitable C2 position. Approach is bounded at 60 updates with retry spacing;
the retained whole preparation/shape wait remains bounded at 90 updates.

Read-only C1 information combines the current role's selector-1 firing records
with current AABBs belonging to those records. Supported generic templates
contribute prospective coverage; supported active objects contribute only their
present geometry, and only damageReady objects can contribute a current hit.
Custom spawn/motion/hit callbacks can leave a partial model.
Unknown effects use limited coverage and existing fallbacks, not invented exact
all-character skill shapes. Current-action remainder cannot fund a new C1 charge.
A materially better fresh C1 return can beat an early C2; the C2 deadline wins.

After a C2 release request, charge reset plus associated new protection/common
wave observations establish a follow-up window. A useful Z edge may be requested
when canPressZ permits it, including pre-holding a planned next charge while its
separate action gate is closed. This has its own request counter; it is not a
second confirmed C1 release or proof that pressing Z respawns every C1 projectile.
Only live state-3 protection supplies safety; no release request grants 48 frames.

The normal fast interval remains 72 updates. A confirmed C2 window with enough
live protection may start a brief capture after 24 fast updates instead. Actual
Shift use stays capped at 40 per 180 updates and 32 per capture; alignment,
resources and action gates still apply. This exception does not keep Shift held.

Actual common circles are read with fixed centre, radius, growth, delay and
remaining lifetime. Conservative yield exclusion avoids budgeting whites likely
to be swallowed, but never removes hazards from dodge. Common type-1/type-4
effects are not exclusive C2 identifiers. isErasable describes explosion
resources and is not a verified C2-cancelability flag.

Confirmed follow-up movement keeps its original 12-update poisoned/wall-limited
trajectory. At normal time scale it may additionally check holding that actual
endpoint until conservative protection expiry plus four updates, bounded at 60.
It uses the same current collision-free, terrain and soft-risk candidate band;
no verified endpoint means immediate geometric evasion, not a safe-route claim.
This does not extrapolate the chosen direction throughout the entire shield or
weaken ordinary avoidance. Expiry contact, persistent EX/lasers and warning
lasers retain their geometry; neither a predicted circle nor unobserved next C2
grants safety. Above-limit height recovery and unsupported timing stay on the
existing path.

## Retained bloom bounds

The player stays at Y >= 150 (below roughly the top third), with original
physical bounds y=16..432. Ordinary-shot/C1 approach does not chase upward;
selective spirit capture remains height-limited. Actual-position obs.c2 and
at-most-nine lower/side proposals remain separate. Full search defaults to every
six observe calls; only coordinates are cached and actual yields are refreshed.
Early C2 normally needs net/(net+direct+contested) >= 0.35. Direct C2 erasure
gives neither recharge nor returned whites; enemy/spirit chains provide that
potential yield. Common C2 growth is 4, last active radius 188, lifetime 48;
the 192 contested envelope is a conservative accounting bound, not cleared space.

C2 has an independent 480-game-Timer deadline (eight seconds at normal speed).
C1 never resets it. Warm-up, remaining charge/speed and margin start charging
before the deadline; energy/action/hit gates may delay it while retaining debt.
Cut-ins/time stops freeze cadence. Optional shape holds stay within C2 200..299
or C1 100..199 and at most 24 updates. Urgency, preparation bounds, the deadline
or charged+chargeSpeed reaching the next level ends waiting. Current Max below
the next level is not permission to risk crossing it.

No X, random C selection, 500000-point firing lock, emergency danger-triggered
C, or deliberate C3/C4 is added. A refill to 2/3 is an observed outcome, not a
mandatory trigger or guaranteed continuation. Version 3.0 remains postponed.
Core player.sensor apiVersion stays 1; followupApiVersion=1 adds read-only data.
Game physics, spawn counts, energy and 2P protection are not modified.

Final 2.0.5 regression, packaging, source-rebuild and file-verification results
belong to this delivery's final validation record; this document does not
predeclare them passed. User live acceptance remains pending. Historical 2.0.2
acceptance and other old passes do not validate this version or guarantee FPS.

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
- All characters use bloom behavior: observe fairy formations, inactive and
  activated spirits, and erasable bullets as connected spatial resources.
- Preserve useful formations until an ordinary shot, C1 or C2 can start a useful
  chain. Resource-qualified C2 is usual; a materially better fresh C1 yield
  can take priority before the C2 deadline, even with enough C2 energy.
- Only deliberately charge/release C1 or C2. There is no random C3/C4 selection,
  no Spell Point firing lock, and no X input. Natural score-triggered attacks
  generated by the game are not deliberate C3/C4 input.
- Plan the next C2 from explosion-converted resources and observed recharge;
  do not count white bullets swallowed directly by C2. Poor resources
  can mean waiting before the independent cadence deadline, even at risk of a
  hit. The deadline can override resource gates; danger never triggers emergency
  C2. Ordinary dodge remains active while waiting.
- Prefer high-speed mode to preserve fairy supply; use short low-speed windows
  when spirit capture is useful. Standing still does not require Shift. The
  user's three-teams-versus-one observation is an empirical design premise,
  not a verified spawn formula or a change to the game's spawn rules.
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

Upgrade with the complete 2.0.5 package and retain the 2.0.4, 2.0.3, 2.0.2,
2.0.1, 2.0.0 and 0.1.9 ZIPs separately. Lua and native modules must match;
copying a single Lua file is insufficient. The core player sensor apiVersion 1
is retained with the read-only followupApiVersion 1 extension.
The default 600-second callback budget, input isolation, 1P practice options,
fail-closed sensor checks and window behavior are preserved.

## Preserved poison and state sensing (introduced in 0.1.9)

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

The user confirmed the 0.1.9 poison test passed before 2.0 development began.
That feedback does not validate the new bloom strategy for every character.
Spatial chain ranges and recharge estimates in 2.0 are heuristics, not verified
engine formulas; they do not guarantee that every C2 funds another C2.
There is no dedicated low-frame-rate or time-stop strategy. Existing game
installations are not automatically replaced when this release is packaged.

## Upstream runtime

The original inject.dll and legacy ka_ai_duka.exe in `dist/TH09-AI/runtime`
are copied unmodified from the author's release `ver1.7`. The additional
th09ai-launcher.exe and window_support.dll are built from this project's
src/native. Source and upstream license are included for audit.

## Launcher and controls

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

The 0.1.9 baseline includes user-confirmed poison testing as well as earlier
window and 1P practice feedback. Version 2.0.0 changes the attack policy and its
interaction with positioning, so those historical results are not bloom
acceptance. Run the current offline suites and package/rebuild checks for every
release; do not carry forward their historical pass status.

Completed 0.1.9 checks include 432 player-sensor selftest assertions, owned-window
and laser selftests, 6 real upstream x86 player-export relocation cases, 36 laser
machine-code cases, 256 single-key and 128 input-combination isolation cases,
65,536 set-key cases, 12 two-sided practice combinations, and 4 suspended-start
support combinations with both sensors installed successfully. These suspended
checks did not create a game window or send game input. Launcher regression
passed 497 assertions and path regression passed 65; JSON seconds through the
real launcher to Lua's 60-active-callback stop latch also passed.

Version 2.0.5 remains a bloom test release awaiting user acceptance. Offline regression and successful
source rebuilds cannot establish all-character live acceptance. Check fairy
formation preservation, selective spirit capture, C1 setup, C2 recharge and
the independent C2 deadline and resource-starved waiting in real battles; preserve video, ai/ai_debug.csv and
runtime/native-window.log for unexpected behavior. No new 2.0 test results are
claimed by this historical baseline section.

## 2.0 policy regression and diagnostics

Run the observer, policy and movement suites through `tests/run_native_lua.py`:
`tests/bloom_observer_test.lua`, `tests/bloom_policy_test.lua`, and
`tests/bloom_movement_test.lua`. Version 2.0.4 adds `tests/bloom_observer_timing_test.lua`
and `tests/bloom_timing_test.lua` for chain-window observations and bounded prepare/armed
state transitions. Version 2.0.5 adds `tests/bloom_followup_policy_test.lua`,
`tests/bloom_followup_observer_test.lua`, `tests/bloom_followup_integration_test.lua`
and `tests/bloom_protected_route_test.lua` for follow-up input/capture, partial C1
coverage, main-loop gates and protection-expiry endpoints. These developer regression suites are not included in the public
source whitelist. `tests/mock_ai_test.lua` covers their main-loop
integration with input faults and timing. Existing poison and laser regressions
still apply. The all-character policy cases cover the 16 exported enum entries,
not a claim of individually verified field geometry or live wins.

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

Resource-planned C2 preparation locks the original chain's node IDs. A disappearing lead fairy
does not lose a surviving connected chain, but unrelated replacement resources
cannot silently justify the attack. If that chain disperses before C2 matures,
release below C1 cancels; an already charged C1 ends there. Under the retained timing rules, an already sampled C2 may briefly wait for a clearly better retained
chain within 200..299, subject to the bounds above. A lost chain, urgent leak,
deadline or predicted crossing into C3 ends that wait.
Deadline-driven C2 bypasses the chain resource recheck/cancellation; energy and
action gates still apply, and it retains overdue debt when blocked.
