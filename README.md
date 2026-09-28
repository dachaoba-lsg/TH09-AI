# TH09-AI

《东方花映塚》日文版 v1.50a 的本地对战 AI 源码，包含三个独立版本。Lua 负责决策，原生启动器与支持模块负责输入、窗口和只读感知；运行时使用上游 ka_ai_duka v1.7。

## 选择版本

| 目录 | 版本 | 主要功能与逻辑 |
| --- | --- | --- |
| [git-project1](git-project1/) | 0.1.9.2 | 随机选择 C1～C4；达到 50W 后尝试断分。进一步强化对毒，在近程避弹安全优先的前提下，主动寻找低毒浓度安全区。 |
| [git-project2](git-project2/) | 2.0.8 | 开花机兼容毒优化：中毒时优先向低毒浓度方向移动，保留原开花、固灵、灵梦 C1 和 C2 循环策略。 |
| [git-project3](git-project3/) | 3.9.0-test | 合并 3.8／3.9 优化：非 mech 密弹低速、减少快慢频繁切换、优先宽路；所有难度（含 mech）优先寻找低毒浓度安全区。 |

各版本详细说明：[第一代](git-project1/版本功能与逻辑说明.md)、[第二代](git-project2/版本功能与逻辑说明.md)、[第三代](git-project3/版本功能与逻辑说明.md)。第三代的默认预设和参数范围见 [参数套装文档](git-project3/docs/PARAMETER-PRESETS.md)。

三个目录是独立源码快照，应分别构建并使用配套配置。第三代当前没有“达到 50W 后按压力断分”的状态机，也没有主动选择 C3／C4 的策略；难度名称不保证固定存活秒数。

## 使用范围与已知限制

- 用于日文版 TH09 v1.50a 的 Match Mode → Human vs Human。第一、二代沿用原接管方式；第三代默认控制 2P，可在配置中通过有效 `ai.side_key` 启用 1P。被接管侧的 Charge Type 必须为 Slow；1P key 缺失或错误时按 2P 启动。
- 需要自行准备游戏。本仓库不包含游戏本体、实战录像、调试日志或本机运行配置。
- 会结合毒造成的实际减速预测路线，没有额外毒抗性或免疫。魔理沙激光、多条激光交叉或重合的实战处理仍有局限。
- 感知与策略不改变游戏的子弹生成、碰撞物理、2P HP 或能量；局部路线规划不保证长期无伤。

## 从源码构建

安装 Git、Python 和完整的 TinyCC 0.9.27 win32 工具目录。以第三代为例，在总仓库根目录打开 PowerShell：

```powershell
Set-Location .\git-project3
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-from-source.ps1 -CompilerPath 'C:\tools\tcc\tcc.exe'
```

将编译器路径换成自己的实际路径。构建其他版本时，先进入对应的 `git-project1` 或 `git-project2` 目录。各版本文档中的“仓库根目录”均指该版本目录。

构建入口准备固定版本并校验哈希的上游依赖，执行原生自测和发行包检查，输出到对应版本的 `dist/`。不会自动安装或启动游戏。

完整步骤与离线测试：[第一代 BUILDING](git-project1/BUILDING.md)、[第二代 BUILDING](git-project2/BUILDING.md)、[第三代 BUILDING](git-project3/BUILDING.md)。玩家使用方法位于各版本的 `package/README.md`。

`vendor/`、`downloads/`、`work/`、`dist/` 等生成目录由各版本的 `.gitignore` 排除。源码下载包不是可直接启动的完整发行包；本仓库根目录另提供下方完整发行 ZIP，可直接下载；源码目录与完整发行包请分别使用。

## 许可与来源

原创部分使用 [MIT License](LICENSE.txt)。第三方组件遵守各自许可，项目的 MIT 许可不替代它们；上游许可、来源和 TinyCC 对应源码保留在各版本的 `licenses/` 中。

第三方说明：[第一代](git-project1/licenses/THIRD_PARTY_NOTICES.txt)、[第二代](git-project2/licenses/THIRD_PARTY_NOTICES.txt)、[第三代](git-project3/licenses/THIRD_PARTY_NOTICES.txt)。


# 开箱即用的编译后的包

| 版本 | 完整包下载 |
| --- | --- |
| 0.1.9.2 | [TH09-AI-v0.1.9.2.zip](TH09-AI-v0.1.9.2.zip) |
| 2.0.8 | [TH09-AI-v2.0.8.zip](TH09-AI-v2.0.8.zip) |
| 3.9.0-test | [DS-TH09-AI-v3.9.0-test.zip](DS-TH09-AI-v3.9.0-test.zip) |

本次更新见 [更新日志](CHANGELOG.md)。**2.0.8：开花机兼容毒优化。** 已经处于生效毒雾时，在原安全约束和相同高／低速状态下，优先选择毒层暴露更少的方向；固灵、普通射击、灵梦 C1、C2 节奏及连爆经营继续使用原策略。无合格路线时保留原避险选择，不增加毒抗性。

第三代保持 3.9，包含以下两版优化：

- **3.8：更接近人的移动方式，仅对非 mech 生效。** 圈内已识别的近场弹持续密集时倾向低速；快慢模式有短暂保持，遇到危险可以打断；在原有安全候选中优先选择缓冲较宽的路线。
- **3.9：全难度主动避毒，包括 mech。** 优先选择毒云叠加更少的区域，目标失效时及时重选；仍遵守原有避弹安全、视野、高度、变向次数和保护结束条件。

原 `set-difficulty.cmd` 操作、四项玩家参数、放 C 策略、输入映射及原生 1P 授权保持。unlimited/infinite 默认 `plan_interval=1`，其他档位默认6；旧 JSON 显式设置仍优先。公开 `side_key` 为空。新的站位可能间接影响资源与放 C 时机，低毒区也不保证没有子弹。

3.9 已由作者确认验收通过。离线 42 套 Lua、79 项菜单检查及正式包／源码重建各 318 项包检查通过；不保证特定存活时长。本次第一代 0.1.9.2 和第三代 3.9 保持原版本。

发布包哈希见 [SHA256SUMS.txt](SHA256SUMS.txt)。旧 2.0.7、3.7 完整包保留在 Git 提交历史中。请完整解压新包，不混装旧 Lua 或原生模块；3.9 新增 `poison_navigation.lua`。

## 历史网盘链接

下方网盘分享保留原版本；本次新版请使用上方GitHub完整包下载。

~~~~~

通过网盘分享的文件：TH09-AI-v0.1.9.2.zip
链接: https://pan.baidu.com/s/1K9lM6VC82QAucCoiZHAMXA?pwd=d664 提取码: d664 
--来自百度网盘超级会员v3的分享

版本：0.1.9.2。AI现在可以打毒机了，有望成为最难打的AI。


~~~~

通过网盘分享的文件：TH09-AI-v2.0.8.zip
链接: https://pan.baidu.com/s/1LxlH4qdKtnbEEYoEe_PPhQ?pwd=bbj7 提取码: bbj7 
--来自百度网盘超级会员v3的分享



版本：2.0.8。AI去除停枪，随机C行为，主动打连爆，主动放C2，可以成为开花机练习器 对毒优化

~~~~
通过网盘分享的文件：3.9包.zip
链接: https://pan.baidu.com/s/1DYXjFGpLtKMQtCUguiI0iA?pwd=q2xc 提取码: q2xc 
--来自百度网盘超级会员v3的分享

~~~~
