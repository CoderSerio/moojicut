# MoonBit 核心代码

共享业务逻辑优先用 MoonBit 实现，平台宿主负责系统 API、界面交互和媒体执行。
目前核心编译为原生静态库，由 macOS、Windows 和 Linux 宿主链接；不是通过 Wasm 运行。

## 目录与边界

```text
src/
├── moon.pkg                  # foreign_library：原生静态库入口
├── api_desktop.mbt            # 快捷键 C ABI / MoonBit 兼容入口
├── api_editor_style.mbt       # 编辑样式兼容入口
├── api_image.mbt              # 图像与图像会话兼容入口
├── api_selection.mbt         # 三平台共享选区几何 C ABI
├── api_updates.mbt           # GitHub 发布版本与平台资产选择 C ABI
├── api_feature_runtime.mbt   # 内置功能启停规则 C ABI
├── api_tool_registry.mbt     # 内置工具目录、显示开关与排序 C ABI
├── api_video.mbt              # 视频、剪辑计划与录制规则兼容入口
├── preview.mbt               # 原生程序启动时的跨模块自检
├── preview_wbtest.mbt
├── pkg.generated.mbti        # 保持兼容的根包公开接口
└── internal/
    ├── desktop/              # 平台无关的快捷键规则
    ├── editor_style/         # 属性范围、默认值、每个编辑器的样式状态
    ├── image/                # 图像文档、标注、裁剪、历史与会话
    ├── selection/            # 选区/标注的数值几何，保留 macOS 基准
    ├── updates/              # 版本比较、渠道与平台安装包筛选
    ├── feature_runtime/      # 启用、停用中、已停用状态与调用门控
    ├── tool_registry/        # 稳定工具 ID、版本化布局、启用与排序校验
    ├── video/                # 视频文档、时间线、导出配置、录制规则与会话
    ├── protocol/             # 共享 JSON 校验、数值边界与错误响应
    └── test_support/         # 测试使用的 JSON 断言与结果读取
```

各包通过自己的 `moon.pkg` 声明依赖，并提交生成的接口文件；业务测试与实现放在同一个包中。
MoonBit 以目录为包边界；`internal` 下的包仅供本模块使用，跨包依赖仍须显式导入。

根包保留现有 `#export_name` 名称和参数类型，`api_*.mbt` 只做转发。
业务规则和会话状态只保留在内部包中，原生宿主仍链接同一个根包静态库。

依赖方向如下：

```text
根包兼容入口 / 启动自检
    ├── desktop
    ├── editor_style
    ├── image ──→ editor_style、protocol
    ├── video ──→ protocol
    ├── selection
    ├── updates
    ├── feature_runtime
    └── tool_registry ──→ protocol

image / video 的白盒测试 ──→ test_support（仅测试导入）
```

图像文档与样式控件使用同一份样式规则。图像、视频会话的原生参数转换留在各自业务包，
可以直接调用包内私有实现；不为适配或测试额外公开内部状态。

## 新代码放在哪里

- 跨平台的规则、状态、命令和文档处理优先放在相应 MoonBit 业务包。
- 平台权限、窗口、绘制、采集和编码继续由原生宿主负责。
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

验收分别记录：核心与原生回归、更新源/包签名校验、旧版实际替换并重启且保留设置、新版 GitHub 发现。最后两项不能由“未发现新版”或模拟 transport 测试代替。真实安装应在隔离账户或虚拟机进行；`MOOJICUT_NATIVE_DEFAULTS_DOMAIN` 只隔离应用设置，不隔离 Sparkle 偏好和录屏草稿。

## 内置工具管理

macOS 设置的“插件管理”将截图、录制控制和录后编辑分开；目前可管理矩形、箭头、文字、遮挡和贴图。
工具目录、稳定 ID、配置版本、排序与开关校验在 `internal/tool_registry`；原生 Store 只负责持久化与发布。
标注类型和位置分离，贴图是即时操作，不占用标注/样式枚举。选择、确认、取消等流程入口由宿主保留。

配置先在全部当前编辑器上预检，再同步发布。禁用正在使用的工具会结束可提交的编辑并回到选择；
中文输入组合中或属性无效时拒绝修改，原开关、配置和输入保持不变。排序和禁用其他工具不重建文档或样式会话。
贴图的管理开关与原“启用贴图”设置共用已有功能门控，旧设置会迁入布局。

录制与录后编辑目前显示空列表，导入按钮暂不可用；外部 MoonBit/Wasm 插件及 ZIP 安装尚未接入此管理页。
当前工具目录仅管理已接入的内置功能，不声明任意代码执行或完整插件热更新能力。
