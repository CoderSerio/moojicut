# Mooji Cut 使用与构建指南

[English overview](../README.md) · [返回中文首页](../README.zh-CN.md)

本指南介绍 `main` 分支中的开发版能力。发布包可能尚未包含这些功能；安装前请先查看对应版本的[发布说明](https://github.com/CoderSerio/moojicut/releases)。

## 下载与开始使用

前往 [发布页](https://github.com/CoderSerio/moojicut/releases)，选择已提供的安装包，并核对该版本的功能范围与运行要求。发布包随附 SHA256 校验文件。下表说明开发版的运行方式；若尚无适用的发布包，可参考下方的源码构建说明。

| 系统 | 运行要求 | 打开方式 |
| --- | --- | --- |
| Windows | Windows 10/11，Intel / AMD x64 | 解压 ZIP，双击 `MoojiCut.exe`，从任务栏托盘菜单开始截图或录屏 |
| macOS | Apple Silicon，macOS 26.0 或更新版本 | 解压 ZIP，将 Mooji Cut 放入「应用程序」并打开，从菜单栏图标进入 |
| Linux | Ubuntu 22.04/24.04 x86_64 及兼容发行版，glibc ≥ 2.35 | 解压 tar.gz，在目录中运行 `./launch.sh`，打开设置后点击「截图并标注」 |

下载的应用无需安装 MoonBit 或 Python。关闭设置会继续在后台待命；完全退出请使用菜单栏或托盘中的「退出 Mooji Cut」。

Windows 包免安装，目前尚未进行代码签名，系统可能显示未知发布者提示。macOS 预览包尚未完成 Apple 公证，首次打开可能需要在「系统设置 → 隐私与安全性」中确认。

Linux 需要 GTK 3 和 Ayatana AppIndicator。Ubuntu 22.04 可运行：

```sh
sudo apt install libgtk-3-0 libayatana-appindicator3-1
```

部分 GNOME 桌面需要 AppIndicator 扩展才能显示托盘；没有图标也可运行 `./launch.sh` 打开设置，或运行 `./moojicut --capture` 直接截图。Wayland 还需要桌面提供可用的 `xdg-desktop-portal` 截图服务。

## 开发版功能范围

| 功能 | macOS | Windows | Linux |
| --- | --- | --- | --- |
| 截图 | 系统框选 | 冻结桌面后框选，支持多显示器 | X11 冻结框选；Wayland 通过系统截图门户选择 |
| 图片标注 | 矩形、箭头、文字、实心遮挡，支持撤销与重做 | 同左 | 同左 |
| 录屏范围 | 通过系统选择一个显示器或窗口 | 主显示器，最高 1920 × 1080、15 fps | 暂未支持 |
| 录屏声音 | 可选系统声音，不录麦克风 | 无声录屏，不录系统声音或麦克风 | 暂未支持 |
| 视频编辑 | 裁剪首尾、删除片段、裁画面、静音、撤销与重做 | 裁剪首尾、删除片段、裁画面、撤销与重做；原片本身无音轨 | 暂未支持 |
| 全局快捷键 | 截图、开始录屏、停止录屏 | 截图、开始录屏、停止录屏 | 可保存配置，暂未注册全局按键；使用菜单或启动命令 |

Linux 的自动检查覆盖 X11；**Wayland 截图门户尚未完成实机验证**，可选范围取决于桌面提供的系统界面。视频标注、Windows 音频录制及 Linux 录屏仍待完善。

## 截图：标出重点，再发出去

**框选 → 标注 → 确认 → 复制图片**

1. 从菜单启动截图，或使用默认快捷键。
2. 选好区域后，添加矩形、箭头或文字；需要遮住内容时，使用不透明的实心遮挡。
3. 不满意可撤销或重做。点击复制后，将保留原图尺寸的图片放入剪贴板。
4. 回到聊天或文档中粘贴。按 `Esc` 或取消会关闭本次编辑，保留原有剪贴板内容。

首次在 macOS 截图时，需要允许「隐私与安全性 → 屏幕与系统音频录制」权限；授权后按系统提示重新打开应用。Wayland 的截图选择与授权由系统门户处理，取消授权不会替换剪贴板。

## 录屏：剪掉多余，再分享过程

**开始录制 → 停止 → 编辑 → 确认并复制视频文件**

macOS 可以在开始时选择是否录制系统声音，再通过系统界面选择显示器或窗口。Windows 当前录制主显示器，保留画面比例，最高 1080p、15 fps，包含鼠标指针但没有声音。

结束录制后进入编辑器。按原片的时间填写保留范围或删除区间，点击对应的应用按钮；也可以指定画面范围，去掉不需要的边缘。编辑支持撤销、重做与预览。macOS 有音轨的录屏还可以选择静音。

确认后生成 MP4，并将**视频文件**放到剪贴板，供支持文件粘贴的应用接收。只预览或取消编辑不会复制视频。关闭编辑器会保留原片与草稿；macOS 和 Windows 可从菜单「继续编辑上次录屏」重新打开。

录屏文件保存在本机：macOS 位于 `~/Library/Application Support/MoojiCut/`，Windows 位于 `%LOCALAPPDATA%\MoojiCut\`。`Drafts` 保存原片和编辑草稿，`Exports` 保存确认后的成片。

## 快捷键

| 操作 | macOS 默认 | Windows 默认 |
| --- | --- | --- |
| 截图 | `⌘ ⇧ 1` | `Ctrl + Shift + 1` |
| 开始录屏 | `⌘ ⇧ 2` | `Ctrl + Shift + 2` |
| 停止录屏并编辑 | `⌘ ⇧ X` | `Ctrl + Shift + X` |

在「设置 → 快捷键」中可以录入新组合、清除或恢复默认。若组合已被系统或其他应用占用，换一个组合即可；录入期间会暂时停用对应的全局响应。Linux 当前保存的快捷键尚不会触发采集。

## 应用内更新

macOS 可在「设置 → 更新」中检查新版本，下载后点击安装并重新打开。更新包和更新信息均经过签名校验；快捷键、偏好设置和录屏草稿会保留。录屏或编辑尚未结束时，应用会等待你完成当前操作。

默认由你手动检查，也可以开启自动检查。应用不会静默安装更新。首次安装仍需下载应用；旧版没有更新入口，需要手动换装一次。Windows 与 Linux 本版仍通过发布页更新。

## 从源码构建

准备支持 native 静态库的 MoonBit 工具链和 Python 3.12 或更新版本；Windows / Linux 的 CI 固定使用 MoonBit `0.10.20+65efd5b93`。

- macOS：Xcode Command Line Tools 及支持 macOS 26 的 SDK。
- Windows：MSVC C++ Build Tools 与 Windows SDK，在 x64 Native Tools 开发终端中运行。
- Linux：C 编译器、`pkg-config`、GTK 3 和 Ayatana AppIndicator 开发包。

在仓库根目录运行：

```sh
python3 scripts/desktop.py dev
```

Windows 可将 `python3` 换成 `python`；macOS 与 Linux 也可使用 `make dev`。构建后会启动应用并打开设置。

macOS 首次构建会下载并校验固定版本的 Sparkle 更新框架。构建优先使用本机唯一的 Apple Development 证书，也可通过 `MOOJICUT_SIGNING_IDENTITY` 指定证书；无证书时使用临时签名，重新构建后屏幕录制权限可能需要重新授权。

根目录是 MoonBit 项目，编辑核心位于 `src/`，默认编译为 native。可以单独运行 `moon check`、`moon test` 和 `moon build`，检查、测试与构建核心。各平台的原生界面共用这一核心。

## 关于 Mooji Cut

Mooji Cut 使用 MoonBit 编写标注与剪辑状态，搭配各平台原生界面和系统采集能力。截图与录屏在本机处理，让捕捉、编辑和分享成为连贯的几步操作。

## 许可

项目采用 [MIT 许可](../LICENSE)。macOS 更新组件 Sparkle 的许可随应用一同提供。
