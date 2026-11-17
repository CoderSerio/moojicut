<p align="center">
  <img src="assets/brand/mooji-cut/app-icon-rounded-preview.png" width="96" alt="Mooji Cut logo" />
</p>

<h1 align="center">Mooji Cut</h1>

<p align="center"><strong>简体中文</strong> · <a href="README.en.md">English</a></p>

<p align="center"><strong>这一幕，我截下了。</strong></p>

<p align="center">简洁的截图与录屏工具，MoonBit 驱动。截取画面、标出重点、剪辑录屏，让日常操作保持直接。</p>

<p align="center"><a href="https://coderserio.github.io/moojicut/">官网</a> · <a href="https://github.com/CoderSerio/moojicut/releases/latest">下载最新版</a> · <a href="https://github.com/CoderSerio/moojicut/issues">反馈问题</a> · <a href="https://github.com/CoderSerio/moojicut">查看源码</a></p>

## 下载与开始使用

当前版本：**[0.1.0-alpha.20](https://github.com/CoderSerio/moojicut/releases/tag/v0.1.0-alpha.20)**。Mooji Cut 仍处于 alpha 阶段，三端功能尚未完全对齐。

| 系统 | 下载 | 运行要求与安装 |
| --- | --- | --- |
| macOS | [Apple Silicon · ZIP](https://github.com/CoderSerio/moojicut/releases/download/v0.1.0-alpha.20/moojicut-0.1.0-alpha.20-macos-arm64.zip) | macOS 26+；解压后将 Mooji Cut 放入「应用程序」。 |
| Windows | [Intel / AMD x64 · ZIP](https://github.com/CoderSerio/moojicut/releases/download/v0.1.0-alpha.20/moojicut-0.1.0-alpha.20-windows-x64.zip) | Windows 10/11；解压全部文件，运行 `MoojiCut.exe`。 |
| Linux | [x86_64 · tar.gz](https://github.com/CoderSerio/moojicut/releases/download/v0.1.0-alpha.20/moojicut-0.1.0-alpha.20-linux-x64.tar.gz) | Ubuntu 22.04+ 兼容环境；安装[系统依赖](docs/guide.zh-CN.md#下载与开始使用)，解压后运行 `./launch.sh`。 |

无需安装 MoonBit、Node.js 或 Python。安装包附带 SHA256 校验文件。macOS 包已使用开发证书签名，尚未完成 Apple 公证；Windows 包尚未签名，首次打开可能出现系统确认提示。

已安装的 macOS 版本可在「设置 → 更新 → 检查更新」中升级。Windows / Linux 可检查、下载并校验更新，之后退出旧版本，手动解压换装。详细操作见[使用与构建指南](docs/guide.zh-CN.md)。

## 为什么选择 Mooji Cut

- **简洁优先。** 围绕截图、标注和基础剪辑，做好每天都会用到的操作。平时留在菜单栏或托盘，需要时随手唤起。
- **工具按需调整。** macOS 可独立启用、停用和排列截图工具，让常用操作更顺手。
- **本地完成。** 截图、录屏与编辑在本机进行，处理后的内容由你决定如何保存和分享。

## 捕捉与编辑

| 场景 | 用 Mooji Cut |
| --- | --- |
| 截图说明 | 框选画面，用箭头、矩形、椭圆和文字标出重点，通过实心覆盖或马赛克处理画面，复制到聊天或文档。 |
| 贴图参考 | 将截图固定在屏幕上，调整大小和透明度，方便对照与参考。 |
| 提取文字 | macOS 支持本机 OCR 与系统翻译，结果可编辑并复制。 |
| 录屏演示 | 选取录制范围，倒计时后开始录制；macOS / Windows 可继续剪辑，Linux 保存 WebM 文件。 |

编辑支持撤销与重做，可以边试边调整。

### 录屏与视频编辑

| 平台 | 录屏 | 录后编辑 |
| --- | --- | --- |
| macOS | 区域、窗口或整屏，可选系统声音，输出 MP4 | 片段切分、调序、删除与合拢空隙，音轨展开/解除关联、音频波形、片段变速、裁画面、静音和导出。 |
| Windows | 自由框选、可取消倒计时；静音 MP4，最高 1920 × 1080 / 15 fps | 原有原生编辑器：修剪首尾、删除片段、裁画面、撤销与重做。 |
| Linux | X11 自由框选；Wayland 使用系统录屏门户选源；静音 WebM，最高 1920 × 1080 / 15 fps | 保存录制文件，尚未接入视频编辑器。 |

macOS 时间线支持缩放与撤销/重做，编辑预览保留原片，保存时才导出成片。预览倍率只改变观看速度，片段倍率会改变导出时长。当前围绕单一录屏编辑，尚未支持导入多个素材、字幕、转场或缩放聚焦关键帧。

Windows / Linux 的录制流程共用 MoonBit 状态与倒计时规则，暂不支持音频录制或暂停。Windows 与 Linux X11 的自动录制和媒体检查已通过；Wayland 系统授权、多显示器和混合 DPI 仍需实机验收。滚动截图入口继续默认关闭。

## 工具与插件

macOS 可在「设置 → 插件管理 → 截图工具」中管理矩形、箭头、文字、遮挡和贴图。勾选启用，选中一项后用「上移」「下移」调整顺序，设置自动保存。标注与用户工具排列在左侧功能组；贴图、取消和完成位于右侧操作组。

点击「导入插件…」可导入预编译的插件 ZIP，新增工具也可在同一列表中启停和排序。选好截图区域后，从截图工具栏运行插件，在结果窗口查看文本，需要时点击「复制文本」。当前插件只接收截图尺寸、格式等信息，不读取图像像素，不支持网络访问、文件访问或自定义界面。

**用户插件宿主目前仅在 macOS Apple Silicon 上验证。** Windows / Linux 尚未接入用户插件与此管理界面，录制控制和视频编辑也尚未开放用户插件扩展。导入步骤与示例打包方法见[使用与构建指南](docs/guide.zh-CN.md#插件管理选择工具和导入插件)。

## 开发与贡献

Mooji Cut 使用 **MoonBit** 实现共享界面、交互与编辑核心，平台适配层提供窗口、绘图、采集和媒体能力；目前仍有原生产品界面需要迁移。

开始开发前，请参考[源码构建说明](docs/guide.zh-CN.md#从源码构建)。

目录、插件机制、跨平台边界和 CLI 优先的自动化方案统一记录在[架构与实施规划](docs/architecture.md)。文档区分当前实现与目标，后续架构讨论和迁移以此为依据。

欢迎提交问题、改进交互、贡献代码，也欢迎一起讨论插件应该怎样融入日常使用。

## 许可

[MIT License](LICENSE)。第三方组件遵循各自的许可。
