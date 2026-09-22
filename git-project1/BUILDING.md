# TH09-AI 0.1.9：源码构建

本页适用于 Git 源码仓库。完整玩家 ZIP 中的 `source/rebuild-from-package.ps1` 是另一条重建入口，需要保留 ZIP 的外层运行库、许可和文档；不要单独拿出它代替本仓库入口。

## 构建环境

- Windows，推荐使用系统自带的 Windows PowerShell 5.1。
- 完整的 **TinyCC 0.9.27 win32/i386** 工具目录；必须包含相邻的 `include`、`lib` 和运行库，不能只复制 `tcc.exe`，也不能用 win64 编译器代替。
- 首次准备上游依赖需要网络；准备完成后可以离线构建。
- Lua 回归另需 64 位 Python 3.9 或更高版本及 `lupa==2.8`。构建本项目原生模块与打包本身不需要游戏。

TinyCC 工具下载地址与哈希见 [PUBLIC-SOURCE-BUILD.md](PUBLIC-SOURCE-BUILD.md) 的编译器章节。该文档还保留随包重建和重新链接说明；其中历史版本号或旧目录示例不覆盖本页的 Git 仓库入口。

源码和 PowerShell 脚本使用 UTF-8；供 Windows PowerShell 5.1 执行的含中文脚本应保留 UTF-8 BOM。路径可以有中文或空格，命令行路径须加引号。TinyCC 上游自举批处理有自己的路径限制，修改编译器时另按其说明操作。

## 首次构建

在仓库根目录运行，替换示例工具路径：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-from-source.ps1 -CompilerPath 'C:\tools\tcc\tcc.exe'
```

入口调用 `scripts/prepare-dependencies.ps1`，下载锁定版本的上游运行库并核对 SHA-256，放入本地 `vendor/`。校验失败时应检查下载和锁定信息，不要跳过校验。随后从 `src/native/` 编译本项目的启动器与支持模块，执行原生自测，把 `src/ai/`、`src/launcher/`、`package/` 和 `licenses/` 组装成发行包并运行公开包验收。

默认版本为 `0.1.9`。产物为：

```text
dist/TH09-AI-v0.1.9.zip       含运行文件、项目源码及第三方材料的发行 ZIP
dist/TH09-AI/                 构建暂存目录
work/                        自测、临时文件和构建记录
vendor/                      已校验的上游依赖缓存
downloads/                   已校验的下载归档缓存
```

ZIP 外层包名为 `TH09-AI`。生成过程不安装到游戏目录，也不启动游戏。原生窗口自测可能创建自己的隐藏测试窗口。

已有同名 ZIP 时默认拒绝覆盖；需要覆盖本地构建产物时显式添加 `-Overwrite`。也可用 `-Version '0.1.9-local'` 标识自己的构建，这不表示原发行者审核了修改。

## 离线重建

先通过首次构建或依赖准备脚本获得完整、有效的本地缓存，再运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-from-source.ps1 -CompilerPath 'C:\tools\tcc\tcc.exe' -SkipDependencyDownload -Overwrite
```

`-SkipDependencyDownload` 只禁止下载，仍检查本地依赖是否符合要求。缺失文件或哈希不符会失败，不能用空文件或其他版本替代。

`inject.dll` 和旧 `ka_ai_duka.exe` 按锁定的上游发行版本原样使用。这里可重建的是本项目 Lua、启动脚本及原生模块，不能把构建成功描述成已从本项目源码重编译全部上游运行库。

## Lua 回归

在仓库根目录安装固定测试依赖，然后运行统一入口：

```powershell
python -m pip install --target work/lua-test-python lupa==2.8
python tests/run_all_lua.py
```

测试入口自动发现当前 `*_test.lua` 套件，每套使用独立的 Lua 5.1 进程；日志和结果 JSON 写入 `work/test-results/`。旧版性能对照依赖未公开的历史快照，缺失时明确报告 `SKIP`，当前版本检查仍运行；对照时间列的 0 不表示测得零耗时。微基准不是游戏 FPS。

失败时保留完整错误、命令和版本用于定位。离线 Lua 与原生自测通过，并不等于已经验证游戏中的生存表现。

## 可选：真实启动配置集成测试

以下测试需要自己合法持有的、版本兼容的游戏目录，且应先成功构建本仓库。示例目录须替换成包含 `th09.exe` 和 `th09.cfg` 的实际位置：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\runtime_settings_integration_test.ps1 -SourceGameRoot 'C:\Games\TH09'
```

该项通过启动器的 `-PrepareOnly` 路径生成测试配置并验证 Lua 读取结果，不启动游戏；测试生成文件保留在仓库 `work/`。它不属于无需游戏的默认构建流程。真实对战、输入与画面效果应另行试玩，并在测试报告中与离线结果分开记录。

## 发布与第三方材料

提交源码时保留 `src/`、`tests/`、`scripts/`、`package/`、根构建脚本和许可。不要提交 `work/`、`vendor/`、`downloads/`、生成的 `dist/`、游戏文件、运行日志或生成的绝对路径配置。发行 ZIP 可单独作为 Release 附件。

`licenses/tinycc/` 包含对应源码和许可材料，不能当普通构建缓存删除。修改 TinyCC 启动/辅助库并重新链接本项目模块的方法见 [PUBLIC-SOURCE-BUILD.md](PUBLIC-SOURCE-BUILD.md)；第三方再分发要求以相应许可和 [第三方说明](licenses/THIRD_PARTY_NOTICES.txt) 为准。
