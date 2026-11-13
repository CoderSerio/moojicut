# Mooncap

**实现方向已调整为 MoonBit native + 原生 macOS 菜单栏工具，见 [原生路线决策](docs/native-direction.md)。** 下文记录已完成的 Electron 参考实现；完整原生迁移尚未完成，独立首页不再属于目标产品形态。

原生入口：`npm run dev:native`。当前可运行菜单栏与 AppKit 设置面板，外观选项会保存；`npm run test:native` 验证 MoonBit 原生核心与 Objective-C 嵌入。构建方式和已实现范围见 [native/README.md](native/README.md)。

供人和 Agent 共用的本地截图与录屏工具。平时驻留菜单栏或系统托盘；截图框选后原地标注，确认复制图片；录屏停止后编辑，确认生成并复制 MP4 文件。

当前已经接通截图、录屏、编辑、历史和 Agent 服务，不再使用早期的大窗口工作台作为产品入口。[PRD](docs/prd.md) 定义产品范围和验收条件，[架构说明](docs/architecture.md) 记录当前实现。代码中的能力与实机验收分开记录，首版完整验收仍在进行。

## 当前功能

| 场景 | 已接入的功能 |
| --- | --- |
| 截图 | 当前显示器区域或全屏截图、窗口截图、导入 PNG / JPEG / WebP；区域截图在同一冻结画面中选区与标注 |
| 标注 | 矩形、椭圆、直线与箭头、画笔、荧光笔、实色遮挡、实际像素化马赛克、文字、整对象橡皮擦 |
| 对象编辑 | 单对象选择、移动、适用对象缩放、修改样式、删除和普通标注排序；选区调整保留原始坐标；会话内最多 100 步撤销重做 |
| 图片完成 | 默认确认复制 PNG 图片；也可保存 PNG 或贴图；已完成截图保留可编辑对象，可从最近记录重开 |
| 录屏 | 区域或全屏、声音选项、3 秒倒计时、独立采集视图、停止浮条和全局停止快捷键；区域在录制编码前裁出 |
| 视频编辑 | 首尾裁剪、重复删除多个区间、拖动画面裁切框、静音、撤销重做；预览跳过删除区间，草稿保存在本机 |
| 视频完成 | FFmpeg 生成 MP4，默认向剪贴板写入文件；支持另存为、取消编码和再次复制已生成文件 |
| 最近记录与设置 | 重开截图和录像草稿、显示文件位置、明确删除原件或导出文件、修改快捷键和默认声音设置 |
| Agent | CLI 与 MCP 共享截图文档：静默采集、标注、裁剪、撤销重做、预览、导出和复制；显式展示或贴图才打开窗口 |

截图工具栏保留十三个入口：形状、线条、画笔、荧光笔、遮挡、文字、橡皮擦、撤销、重做、取消、贴图、保存、确认。对象选择和选区调整通过 `V`、`C` 或右键菜单进入。文字编辑保留输入法与多行输入行为，不把输入中的 Enter 当作整张截图的确认。

视频文字、箭头和遮挡属于 **P1**，当前未实现；模糊、局部擦除笔迹、多选与图层面板也不属于本次 P0。轻量视频分享默认按 25 MiB 估算编码预算，实际文件大小可能超过预算。

## 技术边界与常驻开销

- **MoonBit 核心**：图片文档与命令、裁剪、版本校验、撤销重做，以及视频文档、保留片段、时间映射、裁切和导出计划；编译为 JavaScript ESM。
- **Rabbita 0.17.0**：以 MoonBit 编写截图工具栏、属性区和视频编辑控件。JavaScript 仍承担 DOM 事件、Canvas 绘制、文字输入、媒体播放与宿主接口适配；准备录屏、最近记录等页面也保留标准 Web 实现。
- **Electron 45.3.1**：当前开发宿主，处理托盘、窗口、采集、权限、快捷键、剪贴板和文件。编辑器、准备页和临时渲染视图按需创建，关闭后销毁；录制视图独立于编辑窗，收尾后释放。
- **FFmpeg / ffprobe**：处理和校验媒体；macOS 原生剪贴板辅助程序负责文件剪贴板。

默认启动没有主窗口，但 Electron 仍有 Chromium 和主进程的空闲开销，尚不能称为轻量原生常驻程序。后续可将宿主替换为系统 WebView 与原生采集，保留 MoonBit 文档、Rabbita 界面和受限宿主接口；这项迁移尚未完成，也未承诺时间。

## 本地开发

需要 Node.js 22 或更新版本、npm、MoonBit 工具链，以及 FFmpeg（包含 ffprobe）。macOS 构建原生剪贴板组件还需要 Xcode Command Line Tools 提供的 `clang`。

构建脚本依次查找 `.tools/moon`、`MOON_HOME` 和 `PATH` 中的 MoonBit；`.tools` 被 Git 忽略，新 clone 不包含工具链。详细说明见 [core/README.md](core/README.md)。UI 依赖在各自 `ui/*/moon.mod` 中固定为 Rabbita 0.17.0，首次构建需要获取 MoonBit 包。

```sh
npm install
ffmpeg -version
ffprobe -version
npm run build
npm start
```

| 命令 | 用途 |
| --- | --- |
| `npm run build:core` | 编译 MoonBit 核心到 `dist/core/core.mjs` |
| `npm run build:ui` | 编译截图、视频 Rabbita 界面到 `dist/ui/` |
| `npm run build:native` | macOS 编译文件剪贴板辅助程序；其他平台不执行该编译 |
| `npm run build` | 依次构建核心、界面和原生组件 |
| `npm start` | 构建后启动，默认只显示菜单栏/托盘入口 |
| `npm run dev` | 构建后启动并打开最近记录与设置；保留的 `--workbench` 参数现在指向此页面 |
| `npm run package` | 构建当前架构的 macOS 本地 `.app`，包含媒体工具及其依赖，输出到 `release/` |
| `npm test` | MoonBit JS 后端单测与 Node 核心契约、宿主、存储和 Agent 测试 |
| `npm run check` | 检查 JavaScript 语法 |
| `npm run agent -- status` | 通过 CLI 读取本地应用状态 |
| `npm run mcp` | 启动 stdio MCP 服务 |

默认快捷键为 `⌘ / Ctrl + Shift + 1` 截图、`⌘ / Ctrl + Shift + 2` 录屏、`⌘ / Ctrl + Shift + X` 停止录屏，可在设置中修改。关闭编辑或历史窗口后回到托盘，完全退出使用托盘菜单。

首次采集需要系统屏幕录制权限；麦克风和系统声音也受平台权限与能力限制。改变权限后可能需要重启。开发模式由 Electron 进程申请权限，本地打包应用使用自己的应用身份。

本地打包脚本目前只支持 macOS，默认从 `/opt/homebrew/bin` 取 FFmpeg 与 ffprobe，也可通过 `MOONCAP_FFMPEG`、`MOONCAP_FFPROBE` 指定用于打包的可执行文件。运行时可用 `MOONCAP_MEDIA_BIN` 指定媒体工具目录。脚本会搬移依赖并验证 H.264 / AAC 编码、探测和解码，但不执行 Developer ID 签名或公证；产物是本地测试包，不是已完成分发验收的正式安装包。

## Agent 接入

先构建项目。CLI 和 MCP 会连接托盘应用；应用未运行时尝试后台启动，可用 `MOONCAP_AUTOSTART=0` 禁止自动启动，用 `MOONCAP_EXECUTABLE` 指定应用可执行文件。

```sh
npm run agent -- status
npm run agent -- list_windows '{"types":["window"]}'
npm run agent -- list_captures
```

CLI 格式为 `npm run agent -- <方法名> '[JSON 参数]'`。MCP 客户端应直接以 `node` 启动本仓库的 `agent/mcp.mjs`，参数使用文件绝对路径；使用 stdio 传输。不要把 npm 输出混入客户端的协议流。

Agent 使用与人工编辑相同的 `captureId` 和文档 `revision`。修改时携带 `expectedRevision`，遇到冲突重新读取；坐标始终以当前底图的物理像素为准。人工确认会裁定底图范围并转换坐标，之后需要重新读取文档。Agent 的普通复制不关闭人工编辑层。录屏控制与视频编辑的 Agent 工具属于 P1。

## 本机数据

默认使用系统应用数据目录：macOS 为 `~/Library/Application Support/mooncap`，Windows 为 `%APPDATA%/mooncap`，Linux 为 `${XDG_CONFIG_HOME:-~/.config}/mooncap`。设置 `MOONCAP_HOME` 可覆盖该路径；桌面应用、CLI 和 MCP 必须使用同一个值，例如：

```sh
MOONCAP_HOME="$PWD/.artifacts/local-profile" npm start
MOONCAP_HOME="$PWD/.artifacts/local-profile" npm run agent -- status
```

- `images/`：已完成截图的最终选区底图和可编辑标注；普通 PNG 输出只包含最终像素。
- `recordings/`：原始录像、录制元数据和剪辑草稿。
- `exports/`：托管导出文件；用户另存为的文件保存在其选择的位置。
- `preferences.json`：设置；`agent/connection.json`：本机服务连接信息与令牌。

未确认的新截图只在当前会话保留；完成后重开仍可编辑对象，但不能恢复最终选区外的画面，撤销栈也不跨重开保留。原始录像与导出文件分开保存；关闭窗口、退出应用或开始下一次录制不会自动删除已复制的 MP4。清理必须由用户明确执行。

## 验证状态与限制

2026-11-13 当前自动化记录：MoonBit JS 后端 **14 / 14**，Node 测试 **29 / 29** 通过。另有隔离素材的截图 UI 检查覆盖选区、标注、中文组合输入防护、历史重开、贴图同步及最终裁剪前后的像素一致性；它不等于真实输入法、桌面采集或跨应用粘贴验收。

macOS 自建窗口采集已验证：640 × 480 逻辑窗口、缩放 1，输出 640 × 480 PNG，关闭后的来源会被拒绝。原生文件剪贴板与较新复制内容保护通过独立命名剪贴板验证，未改动用户剪贴板。Electron 45 完整宿主的 10 项集成检查以及截图、视频、区域录制和准备页烟测通过。

macOS 是首轮验收平台，以下项目仍需按 [PRD 验收场景](docs/prd.md) 记录实际结果：不同实际应用窗口、多显示器和混合缩放、屏幕/音频权限、系统声音、10 分钟连续采集与音画同步、PNG 保存对话框、图片与 MP4 文件在目标聊天应用中的粘贴。编码期间若剪贴板已变化或无法可靠判断，应用保留成片并提示主动复制，避免覆盖新内容。

Windows / Linux 的平台适配尚未完成实机验收；Linux 当前不开放系统声音，文件剪贴板兼容性也不能从 macOS 结果外推。自动化逻辑测试、测试素材编码和本地打包成功都不能替代完整平台验收。
