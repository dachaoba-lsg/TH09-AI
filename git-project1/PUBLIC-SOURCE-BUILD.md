# TH09-AI 0.1.9 随包源码与重建

本文件在玩家压缩包中位于 `TH09-AI/source/BUILD.md`。同目录的 `README.md` 是开发说明；玩家使用方法在上一级 `README.md` 和 `使用说明.txt`。

随包源码包含我们编写的 Lua AI、启动脚本、原生启动器、窗口支持、练习模式和激光感知修正代码，以及构建脚本和项目许可。0.1.8 的 `source/src/native/laser_sensor.c/.h` 与动态激光 Lua 预测需要配套使用；只复制新 `dodge.lua` 不会带上原生几何修复。`source/src/native/window_resize_selftest.c` 是构建时运行的原生窗口测试。原工程里的 Python/Lua 完整回归套件未随包提供，也不是重新编译所必需的文件。这里不包含游戏、开发机路径、vendor/work/tests 目录或运行日志。

0.1.9 是首轮毒雾测试包，新增 `player_sensor.c/.h`，只读感知中毒移动倍率、临时保护及回充相关状态，配合 Lua 的非致死减速地形和保护结束后风险预测。移动倍率依据当前毒云与位置重算，不是上一更新的实测位移。感知不修改游戏状态或2P生命，也不加入自适应主动C攻击；请使用整套原生与Lua源码构建，不把新版脚本单独混入旧运行包。实战效果仍待玩家使用梅蒂欣测试，不能把编译成功视为实战验收。

原生模块导出 `player.sensor` 接口版本1；Lua遇到缺失、无效或不匹配的快照会释放全部AI输入并在控制台报错，不回退到忽略毒雾的旧策略。原生安装失败则阻止本次游戏继续启动。详细字段和成功／失败日志见 `source/src/native/README.md`，玩家CSV列说明见上一级 `README.md`。本版不增加用户配置项。

重建后测试仍要求游戏Option中2P的`Charge Type = Slow`（长按Z蓄力，Shift低速）。相反的Charge模式不支持，检测到时AI停键并提示切回Slow；不自动更改1P设置，也不是新增JSON参数。

激光感知模块在暂停启动阶段核验上游 DLL 的原函数与 vtable，仅修正 AI 读取到的 hitBody 起点偏移；不会改写游戏真实激光物理、HP 或磁盘上的原版 DLL。新增模块属于本项目新增代码，第三方组件仍按原许可处理，不因这个 hook 被重新授权。

## 从下载包重新编译

需要 Windows、Windows PowerShell 5.1 或更新版，以及完整的 **TinyCC 0.9.27 win32/i386** 便携工具目录。不要只复制 `tcc.exe`，它还需要相邻的 `include`、`lib` 和运行库文件。官方工具下载：

[tcc-0.9.27-win32-bin.zip](https://download.savannah.gnu.org/releases/tinycc/tcc-0.9.27-win32-bin.zip)

该官方 ZIP 的 SHA-256：

```text
02E2BFE8C272A549B15E4BFA4507BD7E05304692AF1761DB6C1E8E88AF675651
```

完整解压 TH09-AI，保留其 `source`、`runtime`、`licenses` 和玩家文档的相对位置。在 `TH09-AI/source` 打开 PowerShell，例如工具解压到 `C:\tools\tcc` 后运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\rebuild-from-package.ps1 -CompilerPath 'C:\tools\tcc\tcc.exe'
```

脚本首先检查输入，然后只向当前 `source/dist` 和 `source/work` 写入。它从上一级发行目录复制未修改的 `runtime/ka_ai_duka.exe` 与 `runtime/inject.dll`、第三方许可/源码包、玩家文档、版本、配置和发布说明作为构建基线；不会递归复制上一级 `source`，也不会复制游戏或运行生成的 INI、日志。之后从本包 C 源码重新生成 `th09ai-launcher.exe` 与 `window_support.dll`，运行自建隐藏窗口测试、隔离的激光感知自测，以及自机／毒云状态与x86桥接自测，再复制 Lua/启动脚本并打包。

`laser_sensor_selftest.c` 故意不加载上游 DLL 来验证安全拒绝路径，因此会先输出 `laser_sensor: install=FAILED reason=verified upstream inject.dll is not loaded`，随后输出 PASS。这是隔离测试的预期输出，不等于真实游戏启动失败；若实际启动的 `runtime/native-window.log` 出现感知安装失败，仍应停止并排查，不能忽略。

输出是：

```text
source/dist/TH09-AI/                    重建的可运行包
source/dist/TH09-AI-v0.1.9.zip           含源码的新压缩包
source/work/native-tests/              本机构建测试文件
```

默认版本是 `0.1.9`。已有同名 ZIP 时默认拒绝覆盖；可用 `-Version 0.1.9-local` 指定另一个名字，或明确添加 `-Overwrite`。自定义版本仅标识本地构建，不表示原发行者审核了修改。再次生成源码快照时，旧的生成目录会移到 `source/work/public-source-backups`，不会悄悄删除。旧 `0.1.8` ZIP 请保留为独立回退副本。

改动 `source/src` 后重新运行上面的命令即可重新编译和链接；源文件可审阅、修改、供个人使用。重建不需要游戏本体，也不会修改上一级原发行目录或任何游戏配置。若要试玩，请把**新生成的** `source/dist/TH09-AI` 另行放到你的 TH09 游戏附近；重建脚本本身不启动游戏。

维护者在完整工程中使用 `build-native.ps1 -CompilerPath ...` 编译，然后用 `build-public-package.ps1 -Version 0.1.9` 生成带源码的发行包。后者严格选择所需源文件，不复制项目根目录中的其他资料。缺少许可、源码或上级发行必需文件时，脚本会明确失败；不要用空文件绕过检查。

## 修改 TinyCC 启动库并重新链接

本包原生模块静态链接了 TinyCC 0.9.27 的启动/辅助代码，包括 `win32/lib/crt1.c`、`win32/lib/dllcrt1.c` 和 `win32/lib/chkstk.S`。这部分适用其独立的 LGPL 2.1 许可；许可正文和说明位于上一级 `licenses/tinycc`。完整对应源码在：

```text
../licenses/tinycc/tcc-0.9.27.tar.bz2
SHA-256 DE23AF78FCA90CE32DFF2DD45B3432B2334740BB9BB7B05BF60FDBFC396CEB9C
```

源码归档中个别文件具有自己的许可声明，例如 `lib/libtcc1.c` 的 GPL 2 或更新版本及其编译后链接例外；应保留并遵守这些声明。同目录还提供 `GPL-2.0.txt`，不能把链接例外理解成源码再分发也不受其许可约束。

你可以修改这些库并重新链接我们的模块，也可以为个人使用、调试该修改或排查兼容性问题进行必要的分析和逆向工程；本项目不会用额外限制阻碍第三方许可授予的这些权利。第三方组件继续各自遵守其许可，项目主许可不会取代它们。本包提供构建我们的两个原生模块所需的完整源文件和脚本，因此重新链接修改后的库无需向我们索要专用 `.obj` 文件。

下面的参数依据随包源码中的 `win32/build-tcc.bat` 和 `win32/tcc-win32.txt`。请在单独的开发目录解压源码，修改目标库文件，然后从解压后的 `win32` 目录构建。示例中路径刻意不带空格，以兼容上游批处理的参数处理：

```powershell
# 把源码归档解压到一个新建的独立开发目录（路径可自行调整）。
New-Item -ItemType Directory -Path C:\tcc-src-0.9.27
tar -xjf ..\licenses\tinycc\tcc-0.9.27.tar.bz2 -C C:\tcc-src-0.9.27
Set-Location C:\tcc-src-0.9.27\tcc-0.9.27\win32

# 先编辑 lib\crt1.c、lib\dllcrt1.c、lib\chkstk.S 等需要修改的源文件。
# 使用位于另一个目录的现成 win32 编译器自举，并输出到新的完整工具目录。
cmd.exe /d /c build-tcc.bat -c C:\tools\tcc\tcc.exe -t 32 -i C:\tools\tcc-modified
```

`-c` 选择现成的构建编译器，`-t 32` 强制默认目标为 i386，`-i` 把产物、头文件和库安装到指定的新目录。**不要加 `-x`**：它只生成编译器可执行文件，会跳过库。上游脚本会用新编译器编译 `crt1.o`、`dllcrt1.o`、`chkstk.o` 等，并用 `-m32 -ar` 生成 `lib/libtcc1-32.a`；它同时还构建 64 位交叉产物，但我们的模块仍使用 i386 编译器。

该上游批处理会清理其源码 `win32` 目录内已有的编译输出，所以应在上面单独解压的开发副本中运行，并把现成编译器放在不同目录。构建成功后检查新目录中的 `tcc.exe`、`lib/libtcc1-32.a` 和 `include` 均已生成。然后回到本包 `TH09-AI/source`，用新的完整编译器目录重建：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\rebuild-from-package.ps1 -CompilerPath 'C:\tools\tcc-modified\tcc.exe' -Version 0.1.9-modified
```

编译器会从自身目录查找刚修改并重建的启动库，两个原生模块会重新链接该库。请保留你的库源码修改和相应许可，在分发修改版本时一并处理适用许可要求。上述操作不需要安装系统级编译环境，也无需提供或打包 TH09 游戏文件。
