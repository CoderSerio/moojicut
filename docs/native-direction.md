# MoonBit 原生菜单栏工具：实现方向修正

本决策替代继续以 Electron / WebView 作为产品宿主的路线。现有 Electron 实现保留为行为参考与回归样本，不能再把其“最近记录与设置”窗口作为产品首页。本文描述目标和验证结果，不代表完整原生迁移已经完成。

## 产品形态

- 平时仅显示 macOS 菜单栏图标，点击展开系统原生菜单，无首页、工作台或 Dock 常驻图标。
- 截图和录屏分别通过全局快捷键或菜单唤起。
- 截图使用冻结桌面的覆盖层，在选区附近标注，确认后复制并收起。
- 录屏仅显示必要的准备、倒计时和停止控件；停止后打开专用视频编辑窗。
- 首选项使用紧凑的原生系统控件，关闭即释放窗口。
- 最近记录优先使用菜单中的有限条目与“在 Finder 中显示”；不默认建设独立图库首页。

## 运行结构

目标为 MoonBit native + macOS 原生接口，通过薄 C / Objective-C FFI 连接 AppKit、ScreenCaptureKit、CoreGraphics 和媒体接口。桌面运行不需要 Electron、Chromium、Node 或 WKWebView。

| 部分 | 职责 |
| --- | --- |
| MoonBit | 应用状态、菜单与命令状态、工具与选区、手势和命中规则、标注对象、撤销重做、视频时间线、编辑计划、输出和素材生命周期规则 |
| macOS 适配 | 原生菜单和控件、窗口、系统事件与权限、采集、文本输入法、绘制、播放和编码、剪贴板与文件 I/O |

统一边界采用“系统事件 → MoonBit 状态更新 → 界面状态和系统操作请求”。原生层回报操作结果，MoonBit 决定下一步，避免在原生层另写一套产品状态机。

现有 MoonBit 图片和视频文档、裁剪与区间计算、版本检查、撤销重做可以保留。JavaScript 中的工具状态、拖拽和命中判断、流程控制与输出策略需要迁进 MoonBit。Rabbita 的浏览器控件不能直接变成 AppKit 控件，现有 HTML / Canvas / MediaRecorder 适配需要重写。

## 已确认的可行性

本机 MoonBit v0.10.20 工具链运行现有核心的 native 测试，14 / 14 通过。同一份核心可构建为 native 静态库；本机 C 程序已成功调用图片文档创建以及视频删片段、快照和释放接口。不是通过 Node 或浏览器解释 MoonBit 的 JavaScript 输出。

`npm run test:native` 已将这条边界保留为可重复检查：Objective-C 真实调用核心，覆盖中文／emoji、字符串所有权、重复调用、图片版本与裁切，以及视频编辑、时间映射与会话销毁。`native/macos/` 是已开始实现的原生菜单栏与设置入口，完整采集和编辑器仍需继续迁移。

当前工具链的 FFI 类型与内存所有权需要封装在单独桥接层，并固定工具链版本，不能将内部字符串表示散落在平台代码中。

参考：[MoonBit Native FFI](https://docs.moonbitlang.com/en/latest/language/ffi.html#native-static-libraries)、[Apple NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem)、[ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)。

## 迁移次序与验收

1. 原生菜单栏、快捷键、首选项与 MoonBit 事件回调；验证默认零窗口、无浏览器进程、关闭面板后释放。
2. 原生截图完整闭环：采集、选区、标注、确认、剪贴板；沿用已有文档与行为测试，重新验证像素与中文输入。
3. 原生录制和录后编辑：保留已确认的裁剪、删片段、裁画面和静音范围；重新验收权限、音画时间戳和输出。
4. 迁移历史与 Agent 接口，验证共享版本与文件寿命，移除桌面的 Electron / Node 运行依赖。

MoonBit 的核心与事件测试保持平台无关。未来 Windows / Linux 分别补充平台适配，不宣称 macOS 的原生 UI 与采集代码可以直接跨平台运行。

黑客松实现重点是可独立运行和重放事件的 MoonBit 应用逻辑。平台 API 的必要绑定不应承载另一套业务逻辑；具体参赛资格仍取决于所报名赛事的规则。
