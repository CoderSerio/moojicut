# MoonBit 核心代码

共享业务逻辑优先用 MoonBit 实现。复杂编辑组件的目标是由同一套 MoonBit 代码负责布局、外观描述和交互，平台宿主负责系统 API、底层输入/渲染接入和媒体执行。
目前核心编译为原生静态库，由 macOS、Windows 和 Linux 宿主链接；不是通过 Wasm 运行。

macOS 正式视频编辑器已采用共享 MoonBit UI，应用其他界面仍有平台实现。Windows 保留旧编辑窗，Linux 尚无视频编辑链；共享核心不代表三端共享 UI 已完成。视频编辑器按[共享编辑组件约定](../docs/shared-editor-ui.zh-CN.md)推进，不继续分别扩展三套复杂界面。

正式 macOS 编辑窗与独立样例共用同一套组件，已贯通单素材切分、多段按钮调序/拼接、修剪、删除与撤销、实际片段加速、关联音频解除和独立偏移，以及真实导出；时间轴可缩放/横移，空隙可选中删除合拢。全片静音与画面裁剪进入 v2 文档、预览及导出，裁剪候选在应用前仅为 UI 暂态。观看用的预览倍率与改变成片的片段倍率分开。v2 核心还提供目标时长、版本检查、批量事务和请求重试去重；多文件素材导入、字幕/效果、视频 MCP/CLI 入口及 Windows/Linux 媒体宿主仍按[视频编辑器推进计划](../docs/video-editor-roadmap.zh-CN.md)推进。

macOS 应用接入层负责原子保存 `edit-v2.json`，保留原片与旧 `edit.json`。恢复时严格校验已有 v2，仅不存在时才读取旧版并在内存迁移；无效的新草稿不会被旧版覆盖。最近草稿恢复跳过无效候选，不改写文件。保存失败时保留内存状态并拒绝关闭、退出和导出，允许修复后重试。这些路径有隔离媒体与文件回归，不代表人工录屏或更新验收已经完成。

## 目录与边界

```text
src/
├── moon.pkg                  # foreign_library：原生静态库入口
├── api_desktop.mbt            # 快捷键 C ABI / MoonBit 兼容入口
├── api_editor_style.mbt       # 编辑样式兼容入口
├── api_image.mbt              # 图像与图像会话兼容入口
├── api_selection.mbt         # 三平台共享选区几何 C ABI
├── api_pin.mbt               # 三平台贴图数值和可见性规则 C ABI
├── api_updates.mbt           # GitHub 发布版本与平台资产选择 C ABI
├── api_feature_runtime.mbt   # 内置功能启停规则 C ABI
├── api_tool_registry.mbt     # 内置工具目录、显示开关与排序 C ABI
├── api_video.mbt              # 视频、剪辑计划与录制规则兼容入口
├── api_video_project.mbt      # v2 多片段文档/事务 C ABI，保留旧接口
├── api_video_ui.mbt           # 共享编辑组件的批量绘制/事件接口
├── preview.mbt               # 原生程序启动时的跨模块自检
├── preview_wbtest.mbt
├── pkg.generated.mbti        # 保持兼容的根包公开接口
└── internal/
    ├── desktop/              # 平台无关的快捷键规则
    ├── pin/                  # 三平台贴图缩放、透明度和显隐恢复规则
    ├── editor_style/         # 属性范围、默认值、每个编辑器的样式状态
    ├── image/                # 图像文档、标注、裁剪、历史与会话
    ├── selection/            # 选区/标注的数值几何，保留 macOS 基准
    ├── updates/              # 版本比较、渠道与平台安装包筛选
    ├── feature_runtime/      # 启用、停用中、已停用状态与调用门控
    ├── tool_registry/        # 稳定工具 ID、版本化布局、启用与排序校验
    ├── video/                # 视频文档、时间线、导出配置、录制规则与会话
    ├── video_project/        # v2 片段、链接、恒速、版本事务与媒体计划
    ├── video_ui/             # 正式 macOS 编辑窗与样例共用：布局、主题、命中、手势和语义
    ├── protocol/             # 共享 JSON 校验、数值边界与错误响应
    └── test_support/         # 测试使用的 JSON 断言与结果读取
```

各包通过自己的 `moon.pkg` 声明依赖，并提交生成的接口文件；业务测试与实现放在同一个包中。
MoonBit 以目录为包边界；`internal` 下的包仅供本模块使用，跨包依赖仍须显式导入。

视频沿用截图的分层：`internal/image` 对应新 `internal/video_project` 文档核心，旧 `internal/video` 保留录制、v1 兼容和共用几何；复杂组件统一在 `internal/video_ui`，播放条、时间线和属性面板作为包内模块；`plugins/feature/video_editor` 做应用和媒体接线，`components/shared_canvas` 做通用绘制/输入适配。`plugins/system/builtins.json` 描述原生装配依赖，不代表用户 Wasm 插件接口；当前 Windows 编辑窗仍在 `recording.cpp`，Linux 视频媒体链尚缺。详见[实际目录与目标职责](../docs/shared-editor-ui.zh-CN.md#沿用截图的目录分层)。

根包保留现有 `#export_name` 名称和参数类型，`api_*.mbt` 只做转发。
业务规则和会话状态保留在内部包中，原生宿主链接同一个根包静态库。

本轮进一步共享了三平台标注命中和箭头翼几何、贴图数值与恢复规则、平台录屏配置，以及 macOS 快捷键偏好规则和录屏生命周期。相关宿主实际调用新增 C ABI，原生层保留窗口、键盘布局、系统权限、媒体资源和文件操作。完整交互与边界见[截图编辑与录屏体验](../docs/interaction-design.zh-CN.md)。

依赖方向如下：

```text
根包兼容入口 / 启动自检
    ├── desktop
    ├── pin
    ├── editor_style
    ├── image ──→ editor_style、protocol、selection
    ├── video ──→ protocol
    ├── video_project ──→ video（v1迁移）、protocol
    ├── video_ui ──→ video、protocol
    ├── selection
    ├── updates
    ├── feature_runtime
    └── tool_registry ──→ protocol

image / video 的白盒测试 ──→ test_support（仅测试导入）
```

图像文档与样式控件使用同一份样式规则。图像、视频会话的原生参数转换留在各自业务包，
可以直接调用包内私有实现；不为适配或测试额外公开内部状态。

每个原生进程在分配 MoonBit 对象或调用导出函数前执行一次 `moonbit_init()`。宿主在主线程调用业务核心，
媒体工作线程只接收复制后的纯数值计划；不得把 MoonBit 管理的对象或状态句柄交给后台线程并发修改。

## 新代码放在哪里

- 跨平台的规则、状态、命令和文档处理优先放在相应 MoonBit 业务包。
- 复杂组件的布局、样式、绘制描述、命中、拖动事务、焦点及语义状态放在共享 MoonBit UI 中；底层库可以提供通用控件、排版和渲染能力。
- 播放条的观看状态与动作放在共享 UI，片段恒速、目标时长、音画链接、ripple 和时间舍入放在 `video_project`；原生层只执行媒体请求，不自行计算另一套剪辑结果。预览倍率和时间轴视口不写文档，片段变速与空隙删除才进入原子事务与撤销历史。
- 平台权限、窗口、原始输入与输入法接入、渲染表面、采集和编码由宿主或底层库提供，不在平台适配层重写时间线、属性面板等产品组件。
- 媒体库消费由权威文档生成的 RenderPlan；MLT 组合是派生执行状态，不另存为第二份可独立编辑的项目。共享 UI 不依赖 MLT/AVPlayer 等具体类型。
- 只有形成独立职责时才新增包；不要按单个文件建包，也不要把新业务都堆进 `protocol`。
- 包内测试与实现放在一起。测试辅助代码通过 `for "wbtest"` 导入，不进入应用的依赖链。
- 依赖保持单向，内部包不反向依赖根包。跨模块集成检查留在调用方。
- 调整结构时保留现有原生符号、参数类型和文档格式；业务行为变更单独处理。

## 验证

使用项目固定版本的 MoonBit 工具链运行：

```sh
moon check --target native --deny-warn
moon test --target native --deny-warn
moon info --target native
moon build --target native --release --deny-warn
```

提交每个包生成的 `pkg.generated.mbti`。根包接口应保持兼容，原生静态库还需通过
`test/native/core-embedding.m` 的实际链接、字符串所有权、样式状态与编辑流程检查。
完整桌面验证入口是 `python3 scripts/desktop.py test`；PR 的原生预览 CI 负责 Windows 和 Linux 构建与测试。

## 更新与旧版迁移

更新包来自 GitHub Releases。MoonBit 选择版本、渠道和对应平台资产；原生宿主执行网络请求、文件校验和系统界面。macOS 继续使用内置公钥验证 Sparkle 更新源和安装包，Windows/Linux 目前下载校验后手动换装。

已发布的 alpha.9 固定读取 `https://raw.githubusercontent.com/CoderSerio/moojicut/main/updates/macos.xml`，没有新的 GitHub 发现逻辑。给 Release 添加 `macos.xml` 附件不会改变旧包的地址。后续正式升级时，必须为更高版本生成签名源并同步旧固定路径，同时把同份源附到对应 Release；也可以明确要求一次手动换装。当前仓库中的签名源仍指向 alpha.9，不能当作升级到候选版的验收证据。

验收分别记录：核心与原生回归、更新源/包签名校验、旧版实际替换并重启且保留设置、新版 GitHub 发现。最后两项不能由“未发现新版”或模拟 transport 测试代替。开发界面验收使用构建脚本的隔离测试 profile；非生产 defaults domain 的设置、插件和录屏草稿分别隔离。环境变量 `MOOJICUT_NATIVE_DEFAULTS_DOMAIN` 本身不会改变应用签名身份或隔离 Sparkle 偏好，不能替代隔离账户或虚拟机中的真实更新验收。

## 工具与用户插件管理

macOS 设置的“插件管理”将截图、录制控制和录后编辑分开；目前可管理矩形、箭头、文字、遮挡和贴图。
工具目录、稳定 ID、配置版本、排序与开关校验在 `internal/tool_registry`；原生 Store 只负责持久化与发布。
标注类型和位置分离，贴图是即时操作，不占用标注/样式枚举。选择、确认、取消等流程入口由宿主保留。

配置先在全部当前编辑器上预检，再同步发布。禁用正在使用的工具会结束可提交的编辑并回到选择；
中文输入组合中或属性无效时拒绝修改，原开关、配置和输入保持不变。排序和禁用其他工具不重建文档或样式会话。
贴图的管理开关与原“启用贴图”设置共用已有功能门控，旧设置会迁入布局。

macOS 开发版可导入 MoonBit 编译的用户插件 ZIP，贡献多个截图动作，并在运行中安装、更新、停用和卸载。
`internal/plugin_protocol` 负责清单、能力、调用与文本结果校验；动态目录复用 `internal/tool_registry`，
原生宿主负责包事务、独立 worker 和可见结果窗口。重启只恢复目录，不执行停用的插件。

首版只传截图元数据并返回文本；录制与录后编辑仍为空列表，尚不提供像素处理、网络、自定义界面或跨版本内存迁移。
作者模板、单命令打包、兼容版本和限额见[用户插件运行说明](../plugins/user-runtime/README.md)。
