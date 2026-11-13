<p align="center">
  <img src="assets/brand/mooji-cut/app-icon-rounded-preview.png" width="144" alt="Mooji Cut Logo" />
</p>

<h1 align="center">Mooji Cut</h1>

<p align="center"><strong>这一幕，我截下了。</strong></p>
<p align="center">以 MoonBit 为核心的本地截图与录屏工具。</p>

Mooji Cut 面向日常沟通里的小片段：一张需要圈出重点的截图，一段需要说明操作的录屏。捕捉后编辑，确认后复制，再回到原来的工作。

**当前版本为 v0.1.0-alpha.2，原生桌面开发预览版。** 可以体验菜单栏／托盘、偏好设置和快捷键配置；截图与录屏的完整流程尚不可用。

## 下载与体验

前往 [v0.1.0-alpha.2 发布页](https://github.com/CoderSerio/moojicut/releases/tag/v0.1.0-alpha.2)，按系统下载预览包。各包附 SHA256 校验文件。

| 系统 | 支持范围 | 打开方式 |
| --- | --- | --- |
| Windows | Windows 10/11，Intel / AMD x64 | 解压 ZIP，双击 `MoojiCut.exe`；在任务栏托盘中双击图标打开设置 |
| Linux | Ubuntu 22.04/24.04 x86_64 及兼容发行版，glibc ≥ 2.35 | 解压 tar.gz，在目录中运行 `./launch.sh` 打开设置 |
| macOS | Apple Silicon，macOS 26.0 或更新版本 | 解压 ZIP，将 Mooji Cut 放入「应用程序」并打开 |

Windows 包免安装，无需另装 MoonBit、Python 或 Node；当前尚未代码签名，系统可能显示未知发布者提示。macOS 包采用本地签名（ad-hoc），尚未完成 Apple 公证，首次打开可能需要在「系统设置 → 隐私与安全性」中确认。

Linux 需要 GTK 3 和 Ayatana AppIndicator；Ubuntu 可执行 `sudo apt install libgtk-3-0 libayatana-appindicator3-1` 安装。部分 GNOME 桌面需要 AppIndicator 扩展才能显示托盘图标；未显示时，可再次运行 `./launch.sh` 打开设置。程序不会自动安装依赖或修改桌面配置。

| 部分 | 当前状态 |
| --- | --- |
| 原生菜单栏／托盘与设置 | 已可体验「通用／快捷键／关于」，偏好与按键配置保存在本机 |
| 快捷键配置 | 支持录入、清除、恢复默认和冲突提示；尚未接通全局采集动作 |
| 截图与录屏 | 采集、标注与剪辑、确认后复制的完整流程仍在开发中 |
| 桌面平台 | macOS、Windows 与 Linux 均提供预览包；采集与编辑流程仍在开发中 |

关闭设置不会退出应用；完全退出请使用菜单栏或托盘中的「退出 Mooji Cut」。

## 正在完善的使用流程

接下来围绕截图和录屏完成采集、编辑与分享，让捕捉后的内容能直接用于沟通。

### 截图：标出重点，再发出去

框选画面后，就在原处添加箭头、文字和高亮，遮住不想分享的信息。调整满意后确认，图片进入剪贴板，回到聊天或文档中直接粘贴。

**框选 → 标注 → 确认 → 复制图片**

### 录屏：剪掉多余，再分享过程

录下操作步骤，结束后裁掉首尾、删去等待片段、调整画面范围，或去掉声音。确认后生成视频文件，并把文件放到剪贴板。

**录制 → 裁剪与编辑 → 确认 → 复制视频文件**

## 日常使用，尽量少打扰

- **从菜单栏或托盘开始。** 截图与录屏有各自的快捷键；关闭设置后继续在后台待命。
- **编辑完成，再确认。** 捕捉之后留出调整内容的机会，确认的默认动作是复制到剪贴板。
- **围绕本地文件设计。** 素材、可编辑草稿和导出成品保存在本机，方便继续修改与再次分享。

首版视频编辑优先做好裁剪、删除片段、裁画面和静音，视频标注将在后续加入。

## 从源码构建

准备 MoonBit 工具链和 Python 3.12 或更新版本。macOS 需要 Xcode Command Line Tools，Windows 需要 MSVC C++ Build Tools 与 Windows SDK，Linux 需要 C 编译器、GTK 3 和 Ayatana AppIndicator 的开发包。在仓库根目录运行：

```sh
python3 scripts/desktop.py dev
```

构建后会启动 Mooji Cut 并打开设置。Windows 开发终端可将命令中的 `python3` 换成 `python`；macOS 与 Linux 也可使用 `make dev`。

仓库根目录是 MoonBit 项目，`src/` 中的编辑核心默认编译为 native。也可以单独运行 `moon check`、`moon test` 和 `moon build`，检查、测试与构建核心。各平台共用这一核心，并由各自的原生界面调用。

## 关于 Mooji Cut

Mooji Cut 使用 MoonBit 编写编辑核心，搭配各平台的原生界面。从日常截图与录屏出发，逐步完善捕捉、编辑与分享的体验。
