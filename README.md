<p align="center">
  <img src="assets/brand/mooji-cut/app-icon-rounded-preview.png" width="96" alt="Mooji Cut logo" />
</p>

<h1 align="center">Mooji Cut</h1>

<p align="center"><strong>简体中文</strong> · <a href="README.en.md">English</a></p>

<p align="center"><strong>这一幕，我截下了。</strong></p>

<p align="center">用 MoonBit 构建的开源截图与录屏工具。截图标注、视频剪辑、插件扩展，以及面向 AI Agent 的自动化设计。</p>

<p align="center"><a href="https://coderserio.github.io/moojicut/">官网</a> · <a href="https://github.com/CoderSerio/moojicut/releases/latest">下载最新版</a> · <a href="docs/guide.zh-CN.md">使用指南</a> · <a href="https://github.com/CoderSerio/moojicut/issues">反馈问题</a></p>

## 截图与标注

框选画面，直接标出重点，完成后复制到聊天、文档或演示稿。

- **画出重点**：矩形、椭圆、箭头和文字，调整颜色、线宽、字号与不透明度。
- **处理遮挡**：实心矩形、椭圆覆盖与马赛克，可调整马赛克颗粒大小。
- **继续修改**：选中已有标注，移动、缩放、重新编辑文字，支持撤销与重做。
- **贴在屏幕上**：把截图固定为浮动参考图，缩放、调透明度、隐藏或启用鼠标穿透；再次截图也能把贴图截进去。

## 录屏与剪辑

选好录制范围，倒计时后开始。录完直接进入编辑，把一次操作整理成能分享的演示。

- **剪掉多余**：切分片段、修剪边界、调整顺序、删除片段，选中空隙即可合拢。
- **看清细节**：缩放和移动时间轴，逐帧定位，快速前进或后退。
- **调整节奏**：设置片段实际倍率，把三分钟的操作压缩成一分钟；预览倍率单独控制观看速度。
- **处理声音**：查看音频波形、展开音轨、解除音视频关联并独立调整位置，也可以一键静音。
- **保留原片**：剪辑即时预览，保存时导出成片；支持撤销、重做和继续编辑草稿。

## AI 与自动化

**识别画面中的文字。** 对截图进行 OCR，把图片里的内容变成可编辑、可复制的文本；继续选择目标语言即可翻译。识别与翻译在本机处理，结果可以修改后再使用。

**让 Agent 复用编辑能力。** MoonBit 核心已提供结构化的视频编辑命令、会话快照、导出计划与录制能力查询接口，为代码调用和自动化提供基础。

面向 AI Agent 的完整操作入口正在按 **CLI first** 推进：发现可用功能、定位会话、提交编辑、查询或取消任务，让脚本和 Agent 使用与界面一致的操作规则。独立 CLI 尚未随安装包发布；接口与实施进度见[自动化设计](docs/architecture.md#cli-和-agent)。

## 插件：把常用能力放进工具栏

在「设置 → 插件管理」中启用、停用和排列工具，让工具栏符合自己的工作习惯。内置截图工具和导入的用户工具在同一个列表中管理，新增工具默认追加，设置会自动保存。

**编写 MoonBit → 编译为 Wasm → 打包 ZIP → 导入使用。**

- **一个插件，多个工具**：通过清单声明插件信息和工具入口，每个工具可以分别开关、排序。
- **按约定扩展**：实现固定入口，接收宿主参数并返回结果，无需依赖项目私有 SDK。清单、Wasm 和可选图标一起分发。
- **即装即用**：导入 ZIP 后从截图工具栏调用，结果窗口展示并支持复制文本；安装插件无需重新编译应用。
- **独立执行**：插件运行在单独的 worker 进程中，宿主负责包校验、调用限额、取消与结果检查。

仓库提供可运行的 [Capture Info 示例](plugins/examples/capture-info/README.md)：一个 MoonBit 插件提供「截图信息」和「查看尺寸」两个工具。可以从它开始制作自己的扩展，详见[插件运行与协议说明](plugins/user-runtime/README.md)。

目前用户插件支持截图元信息输入和文本输出。像素处理、标注写入，以及录屏和视频编辑扩展将继续沿统一插件机制推进，详见[插件设计](docs/architecture.md#插件机制)。

## 下载与兼容性

当前版本：**[0.1.0-alpha.20](https://github.com/CoderSerio/moojicut/releases/latest)**。项目仍在 alpha 阶段，各系统的已交付能力如下；上文介绍完整产品功能，具体可用范围以此表为准。

| 平台与下载 | 运行要求 | 当前功能范围 |
| --- | --- | --- |
| [macOS · Apple Silicon ZIP](https://github.com/CoderSerio/moojicut/releases/download/v0.1.0-alpha.20/moojicut-0.1.0-alpha.20-macos-arm64.zip) | macOS 26+ | 截图标注、贴图、OCR/翻译、插件管理与导入；区域/窗口/整屏录制、系统声音及上述时间线编辑。 |
| [Windows · x64 ZIP](https://github.com/CoderSerio/moojicut/releases/download/v0.1.0-alpha.20/moojicut-0.1.0-alpha.20-windows-x64.zip) | Windows 10/11，Intel / AMD | 截图标注、贴图、区域静音录屏；现有编辑器支持修剪首尾、删除片段和裁画面。 |
| [Linux · x86_64 tar.gz](https://github.com/CoderSerio/moojicut/releases/download/v0.1.0-alpha.20/moojicut-0.1.0-alpha.20-linux-x64.tar.gz) | Ubuntu 22.04+ 兼容环境及[系统依赖](docs/guide.zh-CN.md#下载与开始使用) | 截图标注、贴图、静音 WebM 录屏；X11 自由框选，Wayland 通过系统门户选源。尚无录后编辑器。 |

Windows / Linux 暂未接入 OCR/翻译、用户插件或共享时间线编辑器；录屏最高 1920 × 1080 / 15 fps，暂不支持录制声音或暂停。Wayland 的置顶、定位与输入受桌面环境约束；系统授权、多显示器和混合 DPI 仍待实机验收。

滚动截图入口暂时关闭。视频编辑目前使用单一录屏，暂未支持导入多个素材、字幕、转场或缩放聚焦关键帧。当前用户插件不开放图像像素、网络、文件或自定义界面能力；CLI 和录屏/剪辑插件扩展仍在开发中。

下载的应用无需安装 MoonBit、Node.js 或 Python，安装包附带 SHA256 校验文件。macOS 解压后移入「应用程序」，可在设置中检查并安装更新；Windows / Linux 下载校验后需手动解压换装。macOS 包使用开发证书签名，尚未 Apple 公证；Windows 包尚未签名。安装步骤与权限设置见[使用指南](docs/guide.zh-CN.md)。

## 用 MoonBit 构建

MoonBit 承载共享交互、图像文档、录制状态和视频编辑规则，平台适配层提供窗口、输入、采集与媒体能力。用户插件编译为 WebAssembly，在应用自带的运行时中执行。

- [源码构建](docs/guide.zh-CN.md#从源码构建)
- [架构与实施规划](docs/architecture.md)
- [制作第一个插件](plugins/examples/capture-info/README.md)

欢迎提交问题、改进交互、开发插件或贡献代码。

## 许可

[MIT License](LICENSE)。第三方组件遵循各自的许可。
