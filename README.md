<p align="center">
  <img src="assets/brand/mooji-cut/app-icon-rounded-preview.png" width="96" alt="Mooji Cut logo" />
</p>

<h1 align="center">Mooji Cut</h1>

<p align="center"><strong>简体中文</strong> · <a href="README.en.md">English</a></p>

<p align="center"><strong>这一幕，我截下了。</strong></p>

<p align="center">简洁的截图与录屏工具，MoonBit 驱动。截取画面、标出重点、剪辑录屏，让日常操作保持直接。</p>

<p align="center"><a href="https://github.com/CoderSerio/moojicut/releases">下载预览版</a> · <a href="https://github.com/CoderSerio/moojicut/issues">反馈问题</a> · <a href="https://github.com/CoderSerio/moojicut">查看源码</a></p>

## 为什么选择 Mooji Cut

- **简洁优先。** 围绕截图、标注和基础剪辑，做好每天都会用到的操作。平时留在菜单栏或托盘，需要时随手唤起。
- **工具按需调整。** macOS 开发版可独立启用、停用和排列内置与插件截图工具，让常用操作更顺手。
- **本地完成。** 截图、录屏与编辑在本机进行，处理后的内容由你决定如何保存和分享。

## 捕捉与编辑

| 场景 | 用 Mooji Cut |
| --- | --- |
| 截图说明 | 框选画面，用箭头、矩形和文字标出重点，遮住敏感内容，复制到聊天或文档。 |
| 贴图参考 | 将截图固定在屏幕上，调整大小和透明度，方便对照与参考。 |
| 录屏演示 | 记录操作过程，裁掉首尾、删除多余片段、调整画面范围，再导出视频。 |

编辑支持撤销与重做，可以边试边调整。

Mooji Cut 目前处于早期预览阶段。本文介绍 `0.1.0-alpha.15` 开发候选的功能，已发布的安装包可能尚未包含全部能力。各平台的具体支持范围与已知限制，请查看对应版本的发布说明。

## 工具与插件

macOS 开发版可在「设置 → 插件管理 → 截图工具」中管理矩形、箭头、文字、遮挡（填充覆盖）和贴图五项内置工具。勾选启用，选中一项后用「上移」「下移」调整顺序；截图工具栏随之更新，设置自动保存。

点击「导入插件…」可导入预编译的插件 ZIP，新增工具也可在同一列表中启停和排序。选好截图区域后，从截图工具栏运行插件，在结果窗口查看文本，需要时点击「复制文本」。当前插件只接收截图尺寸、格式等信息，不读取图像像素，不支持网络访问、文件访问或自定义界面。

**插件宿主目前仅在 macOS Apple Silicon 上验证。** Windows 与 Linux 的应用功能仍按使用指南中的范围提供，尚未接入用户插件和此管理界面。导入步骤与示例打包方法见[使用与构建指南](docs/guide.zh-CN.md)。

## 开始使用

前往 [发布页](https://github.com/CoderSerio/moojicut/releases)，下载适合你系统的版本。安装方式、权限设置和版本变化均随发布说明提供。开发版的完整操作说明见[使用与构建指南](docs/guide.zh-CN.md)。

## 开发与贡献

Mooji Cut 的标注与剪辑核心使用 **MoonBit** 编写，搭配各平台的原生界面与系统采集能力。

开始开发前，请参考[源码构建说明](docs/guide.zh-CN.md#从源码构建)。

欢迎提交问题、改进交互、贡献代码，也欢迎一起讨论插件应该怎样融入日常使用。

## 许可

[MIT License](LICENSE)。第三方组件遵循各自的许可。
