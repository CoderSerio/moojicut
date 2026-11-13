# Mooncap

一个先把截图、录屏和简单剪辑做顺手的桌面工具。

项目处于基础框架阶段。正式产品希望平时只驻留菜单栏/托盘：截图在桌面选区内就地完成，录屏停止后才打开编辑窗。可直接修改的 [交互初稿](docs/interaction-design.md) 记录了完整流程、图标与文字的分工、取消和恢复行为。

**当前大窗口是开发工作台（workbench），不是正式产品界面。** 它用于验证采集、编辑和导出链路；桌面选区覆盖层、就地工具条、倒计时和独立紧凑预览窗尚未实现。界面暂用 HTML、JavaScript 和手写 CSS；MoonBit 编辑核心编译为 JavaScript ESM，由 Electron 宿主调用。

## 当前框架能力

以下能力通过开发工作台接入；它们不代表交互初稿已经落地。自动化验证与实机验证的状态单独记录。

| 场景 | 功能 |
| --- | --- |
| 截图 | 选择屏幕或窗口，采集后框选裁剪；添加矩形、箭头、文字、不透明遮挡，撤销编辑 |
| 图片保存 | 复制 PNG 到剪贴板，或保存为 PNG 文件 |
| 录屏 | 可选系统声音和麦克风；提供常驻停止浮窗与 `⌘ / Ctrl + Shift + X` 快捷键 |
| 视频编辑 | 裁去首尾、删除中间片段、按像素填写画面裁切范围、静音 |
| 分享 | 导出 MP4；轻量分享默认以 25 MiB 估算码率，实际文件大小不保证低于目标 |
| 本机历史 | 查看保留在本机的原始录像，重新打开已完成的录像继续剪辑 |

当前尚无桌面覆盖层截图、录制前自由框选区域、MP4 文件剪贴板分享或正式系统安装包。Windows / Linux 尚未完成实机验证；系统声音是否可用取决于平台能力与权限，当前 Linux 入口不开放系统声音。复制文件与复制路径的产品语义见 [交互初稿](docs/interaction-design.md#5-mp4-分享与文件语义)。

## 技术边界

- **MoonBit**：保留片段、裁切范围、导出预算和录制状态转换等纯逻辑，输出 JavaScript ESM。
- **Electron 45.3.1**：桌面窗口、原生采集、快捷键、剪贴板和文件操作。
- **FFmpeg**：视频处理与 MP4 编码，需要本机安装。
- **HTML / JavaScript / CSS**：当前开发工作台和交互接线；当前不引入独立 UI 框架。

MoonBit 不负责原生采集，也不意味着当前产品已经具备全 Wasm 或跨平台原生实现。详细职责见 [架构说明](docs/architecture.md)。

## 本地开发

准备 Node.js 22 或更新版本、npm、[MoonBit 官方工具链](https://www.moonbitlang.com/download/)，以及可在终端执行的 FFmpeg（包含 ffprobe）：

```sh
ffmpeg -version
ffprobe -version
```

新 clone 的仓库不附带 MoonBit 或 FFmpeg。构建脚本优先使用本地 `.tools/moon`，其次使用 `MOON_HOME`，最后查找 `PATH` 中的 `moon`；详见 [核心构建说明](core/README.md)。本次开发安装位于 `.tools`，该目录被 Git 忽略，不属于产品源码，也不会随 clone 出现。

构建、启动和测试命令：

```sh
npm install
npm run build:core
npm start
npm run dev
npm test
npm run check
```

`build:core` 构建 MoonBit 编辑核心；`start` 默认仅显示菜单栏/托盘；`dev` 通过 `--workbench` 显式打开开发工作台。关闭工作台后进程继续驻留，退出需使用菜单栏/托盘菜单。

`test` 先运行 MoonBit JS 后端单测，再运行宿主与集成测试；`check` 检查仓库中的 JavaScript 语法。正式截图/录屏覆盖层不在这次基础框架中实现；需要验证现有采集链路时使用 `npm run dev`。

首次采集时，需要在系统设置中允许 Electron / Mooncap 录制屏幕；使用麦克风时还需要相应权限。权限变更后可能需要重启应用。

原始录像保存在 Electron 的本机用户数据目录中，可通过“打开原始录像文件夹”进入。编辑导出产生新的 MP4，不覆盖原始 WebM。

## 验证状态

2026-11-13 模块拆分后的验证结果：

| 检查 | 结果 |
| --- | --- |
| `npm test`：MoonBit JS 后端 | 14/14 通过 |
| `npm test`：Node 宿主、核心契约和写入集成 | 9/9 通过 |
| `npm run check`：JavaScript 语法 | 24 个文件全部通过 |
| macOS 后台生命周期 | 默认启动 0 窗口；显式工作台 1 窗口；关闭工作台后 0 窗口且进程继续 |

MoonBit native 后端曾在模块拆分前通过 14/14；拆分后尚未重跑 native。当前实际发行的 JS 后端已重新验证。

## 已知限制与实机验证范围

- 在 macOS 26.4.1 / Electron 45.3.1 上，曾出现 PNG 系统保存对话框的 **Save 按钮禁用**，尚未定位并解决。因此不能声称 PNG 保存或完整 UI 导出链路已经验收通过。
- 模块拆分前曾成功验证「真实窗口采集 → 矩形标注 → PNG 复制」；拆分后只重新检查了上述三个后台生命周期场景，尚未重跑这条采集链路。
- 自动化媒体测试使用测试素材；屏幕/窗口来源、系统权限、真实录制停止和最终 MP4 播放仍需桌面验收，不能由逻辑测试或窗口数量检查代替。

## UI 的后续方向

先沿 [交互初稿](docs/interaction-design.md) 迭代产品，再从实际重复中提取组件。图标替换与菜单栏流程不意味着现在建设一个 UI 库。组件目录、API、可运行示例、视觉质量和偏 TSX 的声明式写法等要求，已记录在 [GitHub Issue #1](https://github.com/CoderSerio/mooncap/issues/1)，仓库保留 [需求正文](docs/issues/001-ui-components.md)。
