# TH09-AI 0.1.9

简明功能与逻辑见 [版本说明](版本功能与逻辑说明.md)。

《东方花映塚》日文版 v1.50a 的本地 2P AI 源码。Lua 负责决策，本项目的原生启动器和支持模块提供输入隔离、窗口处理及只读感知，运行时使用上游 ka_ai_duka v1.7。

这是第一代避弹测试版本，保留随机 C1～C4、毒减速感知和激光预测。需要自行准备游戏；仓库不包含游戏本体。

## 三个源码版本

| 源码目录 | 版本 | 主要用途 |
| --- | --- | --- |
| git-project1 | 0.1.9 | 第一代避弹、随机 C、毒与激光感知 |
| git-project2 | 2.0.6 | 以 C1/C2、固灵和连爆资源经营为核心的开花测试 |
| git-project3 | 3.3.0-test | 开花策略基础上的圆形视野、注意力和变向限制 |

三者是独立源码快照，配置和发行文件应与各自版本配套。本文说明第一代的现行行为。

## 行为与边界

- 在 Match Mode → Human vs Human 中控制 2P。2P 的 `Charge Type` 必须为 `Slow`；相反的 Charge 模式不支持。
- 使用局部短期路线规划；读取毒造成的实际减速和已有保护状态，预测动态激光。缺失必要感知时释放输入并报错。
- 默认随机选择 C1/C2/C3/C4；能量不足时交替点按 Z。AI 不使用 X。
- Spell Point 达到 500000 时停止射击，归零后恢复。这是第一代规则，不适用于后两代。
- `launcher-settings.json` 顶层 `seconds` 默认 600；0 表示关闭接管时限。这里的时限是停止 AI 操作的配置，不是保证存活时长。

原生感知修正作用于 AI 读取的数据，不修改游戏的子弹生成、碰撞物理、2P HP 或能量。局部规划可能遭遇长期围堵，毒与激光测试通过也不代表任何对局都能存活。

## 从源码构建

在仓库根目录运行，示例编译器路径请替换为自己的完整 TinyCC 0.9.27 win32 工具目录：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-from-source.ps1 -CompilerPath 'C:\tools\tcc\tcc.exe'
```

入口准备固定版本且校验哈希的上游依赖，构建本项目原生模块，执行原生自测并验收发行包。输出为 `dist/TH09-AI-v0.1.9.zip`，不会自动安装或启动游戏。完整依赖、离线构建和测试方法见 [BUILDING.md](BUILDING.md)。

玩家使用方法见 [package/README.md](package/README.md)。完整发行包可放在 GitHub Releases；`dist/`、`vendor/`、`downloads/`、`work/` 是本地生成目录，不作为源码提交。

## 目录与许可

| 路径 | 内容 |
| --- | --- |
| `src/ai/` | Lua 决策与配置 |
| `src/native/` | 原生启动器、窗口与感知支持 |
| `src/launcher/` | 启动脚本 |
| `package/` | 玩家文档和默认配置模板 |
| `tests/` | 离线回归及可选集成测试 |
| `scripts/` | 固定依赖准备脚本 |
| `licenses/` | 第三方许可、TinyCC 对应源码与说明 |

原创部分的许可见 [LICENSE.txt](LICENSE.txt)，第三方组件各自遵守 [licenses/THIRD_PARTY_NOTICES.txt](licenses/THIRD_PARTY_NOTICES.txt) 及相应许可。项目 MIT 不替代上游组件的许可。上游 `inject.dll` 和 `ka_ai_duka.exe` 来自未修改的发行文件，本项目构建命令不重新编译这两个上游文件。

贡献和问题报告见 [CONTRIBUTING.md](CONTRIBUTING.md)。开发历史保存在 [docs/DEVELOPMENT-HISTORY.md](docs/DEVELOPMENT-HISTORY.md)，其中旧版说明不覆盖本页和当前代码。
