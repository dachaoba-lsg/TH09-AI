# TH09-AI

《东方花映塚》日文版 v1.50a 的本地对战 AI 源码，包含三个独立版本。Lua 负责决策，原生启动器与支持模块负责输入、窗口和只读感知；运行时使用上游 ka_ai_duka v1.7。

## 选择版本

| 目录 | 版本 | 主要功能与逻辑 |
| --- | --- | --- |
| [git-project1](git-project1/) | 0.1.9 | 偏被动的局部避弹，随机选择 C1～C4；Spell Point 达到 500000 后停 Z 尝试断分，归零后恢复。 |
| [git-project2](git-project2/) | 2.0.6 | 主动经营大连爆，以 C2 循环为主，配合普通射击和 C1；取消第一代的 50W 停枪锁。 |
| [git-project3](git-project3/) | 3.3.0-test | 少弹时养资源、密集时更积极循环 C2；开放变向上限、圆形视野、注意力容量和恢复速度，供玩家自定义难度。 |

各版本详细说明：[第一代](git-project1/版本功能与逻辑说明.md)、[第二代](git-project2/版本功能与逻辑说明.md)、[第三代](git-project3/版本功能与逻辑说明.md)。第三代的默认预设和参数范围见 [参数套装文档](git-project3/docs/PARAMETER-PRESETS.md)。

三个目录是独立源码快照，应分别构建并使用配套配置。第三代当前没有“达到 50W 后按压力断分”的状态机，也没有主动选择 C3／C4 的策略；难度名称不保证固定存活秒数。

## 使用范围与已知限制

- 用于日文版 TH09 v1.50a，在 Match Mode → Human vs Human 中控制 2P；2P 的 Charge Type 必须为 Slow。
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

`vendor/`、`downloads/`、`work/`、`dist/` 等生成目录由各版本的 `.gitignore` 排除。源码下载包不是可直接启动的完整发行包；完整发行包可另行提供于 GitHub Releases。

## 许可与来源

原创部分使用 [MIT License](LICENSE.txt)。第三方组件遵守各自许可，项目的 MIT 许可不替代它们；上游许可、来源和 TinyCC 对应源码保留在各版本的 `licenses/` 中。

第三方说明：[第一代](git-project1/licenses/THIRD_PARTY_NOTICES.txt)、[第二代](git-project2/licenses/THIRD_PARTY_NOTICES.txt)、[第三代](git-project3/licenses/THIRD_PARTY_NOTICES.txt)。
