# 架构迁移台账与平台交付

源码核对基线：`14bbbea`，2026-11-17。本文是[架构主文档](architecture.md)的实施台账，不另立一套架构。目标路径均是待实现归属，除明确标注外，不表示目录或功能已经存在。

## 状态如何记录

每个工作包分别记录：**归属与依赖、MoonBit 共享规则、共享 UI、平台执行、插件接入、CLI、自动回归、实机验收、发布更新**。某一项通过只更新该项；目录存在、编译成功、模型测试通过，都不能代替真实交互和媒体验收。

平台矩阵分 macOS、Windows、Linux/X11、Linux/Wayland。具体系统版本、显示服务、后端、输入法和运行证据随验收记录，不能只写一个 Linux 勾选框。功能的实际可用性包含后端支持、依赖是否安装、设备、权限、会话状态，不能只有操作系统名称。

## 三端能力基线

以下为源码审计，不代表本轮实机通过。macOS 的既有自动回归与 Windows/Linux 历史 CI 只作为各自证据，未重新执行的环境不补勾。

| 能力 | macOS | Windows | Linux / X11 | Linux / Wayland |
| --- | --- | --- | --- | --- |
| 截图来源与编辑 | 桌面冻结/选区/标注已接 | 桌面冻结/选区/标注已接 | 桌面冻结/选区/标注已接 | Screenshot portal 图片再编辑；依赖桌面后端 |
| 共用选区 UI | 截图/录屏共用原生组件，未完成三端 MoonBit UI | 原生截图选区；录屏未接 | 原生截图选区；录屏未接 | 未接与其他端等价的窗口 hover/选源 |
| 截图窗口 hover | 未见录屏候选窗逻辑接入截图；不能由共用 Surface 推断支持 | 未见生产接入 | 未见生产接入 | 当前门户图片不提供自有窗口候选 |
| 标注/样式/撤销 | 共享模型+原生控件 | 共享模型+原生控件 | 共享模型+原生控件 | portal 返回图片后复用 Linux 编辑器 |
| 开关/排序/导入 | macOS 管理入口已接，固定内置模型 | 通用插件管理/导入未接 | 通用插件管理/导入未接 | 同左 |
| 贴图 | 已接置顶/穿透/快捷键等 | 已接对应基础能力 | 已接置顶/穿透与贴图快捷键 | 位置/置顶由 compositor 决定，穿透禁用 |
| OCR / 翻译 | 已接 Vision / Apple Translation | 占位入口，未实现后端 | 占位入口，未实现后端 | 同左 |
| 滚动截图 | 原型与测试，发布入口关闭 | 未实现 | 未实现 | 未实现 |
| 区域/窗口录屏 | 原生选区与窗口来源已接 | 仅主显示器静默录制，未接区域/窗口选源 | 未实现 | 未实现；不能复用 Screenshot portal 当视频流 |
| 系统音频 / 麦克风 | 系统音频已接；麦克风显式关闭 | 无音频采集 | 未实现 | 未实现 |
| 暂停录制 | 核心有状态，不代表采集后端支持 | 未接 | 未实现 | 未实现 |
| 倒计时 / 取消 / 停止收尾 | 原生流程已接 | 旧确认弹窗，plan 倒计时为 0；已有停止/收尾 | 未实现 | 未实现 |
| 视频编辑/预览 | MoonBit v2 UI+内嵌媒体已接 | 旧 v1 编辑器，生成文件交外部播放器 | 未实现 | 未实现 |
| 导出/波形 | 正式媒体端口/单素材包络已接 | 旧导出链；未接共享 v2 媒体与波形 | 未实现 | 未实现 |
| 用户 Wasm worker | 已接元信息/文本 v1 | 未接 | 未接 | 未接 |
| 完整 CLI / IPC | 未实现 | 未实现 | 未实现 | 未实现 |
| 更新安装 | Sparkle 自动替换链；旧固定 feed 另验 | 下载校验后手动换装 | 下载校验后手动换装 | 同左 |
| 全局截图/录屏快捷键 | 已接 | 已接，仍需真实入口验证 | 配置可保存，截图/录屏全局执行未接 | 未接；按桌面能力实现 |

主要代码依据：`scripts/desktop.py:163` 的发行范围；`plugins/system/builtins.json` 的三端构建入口；`plugins/feature/recording/windows/recording.cpp:603` 的主显示器来源、`:440` 的外部播放器；`plugins/feature/recording/macos/MCMacRecordingController.m:367` 的音源配置；`plugins/feature/capture/linux/portal.inc:97` 的 Screenshot 接口；`native/linux/main.c:340` 的快捷键与录屏现状。共享能力规则另见 `src/internal/features/recording/core/recording.mbt`，它目前只接 macOS/Windows 计划，不能宣称 Linux 后端已经存在。

## 旧原生功能逐项归属

这里列全当前 `plugins/feature` 的 8 个模块。这些是静态构建模块，尚不是统一的运行时贡献机制。

| 旧模块 | 当前实现与混合职责 | MoonBit 目标 | 平台部分与验收 |
| --- | --- | --- | --- |
| `plugins/feature/capture` | 三端都有；Windows/Linux 同时含图片编辑、工具 UI 与采集，Linux 还含 Screenshot portal | `features/capture` 会话、core、ui；共用框选到 `shared/selection` | `platform/<os>/capture` 接采集，`windowing` 接浮层；截屏与标注分别验收，保留贴图和可见编辑器入画行为 |
| `plugins/feature/image_editor` | 独立目录只有 macOS；另两端编辑器在 capture 中 | 标注、输入事务、工具条、属性栏归 capture 的共享会话/UI；插件结果应用经核心命令 | 原生文本输入桥、绘制及剪贴板到平台；不能只搬 macOS 文件而漏掉另两端嵌入代码 |
| `plugins/feature/select` | Windows/Linux 有目录；macOS 在 components/selection | 几何到 `shared/geometry`，框选/hover/调整到 `shared/selection` | 窗口枚举、坐标/DPI、输入捕获到 `windowing`；Wayland 的系统选源单独处理 |
| `plugins/feature/pin` | 三端有窗口实现；数值策略在 src/internal/pin | `capture/extensions/pin` 管贡献、命令、设置、生命周期 | `windowing` 管置顶、穿透和窗口资源，`graphics` 管图片；停用按既有窗口关闭/菜单退役策略释放，不能把资源回收解释为删除原始图片 |
| `plugins/feature/capture_text` | macOS Vision OCR、Apple Translation、结果窗口与任务控制 | `capture/extensions/ocr`、`translation` 管工作流、输入输出、可编辑结果、取消；通用结果控件归 shared/ui | `platform/<os>/text_services` 执行 OCR/翻译；三端实现与模型资源待分别验证，不能在无后端时承诺同等可用 |
| `plugins/feature/scroll_capture` | 仅 macOS 原型；默认关闭；采集、HUD、重叠拼接混合 | `capture/extensions/scroll_capture` 管会话/UI与拼接计划；重叠算法优先共享 MoonBit | 获取帧留 capture；实测若需底层像素计算，才提到 platform/shared/image；继续默认关闭，独立页面稳定性验收 |
| `plugins/feature/recording` | macOS 采集/选区；Windows 同文件包含采集、编码、草稿、旧编辑器；Linux 缺失 | `recording/core` 已归位；会话/UI后续提取，编辑职责移到 video_editor | `recording`、`audio` 管采集和时间戳，媒体执行归 `media`；Windows 先拆责任再接共享选区，Linux 单独补录制流 |
| `plugins/feature/video_editor` | 独立目录仅 macOS；Windows 旧编辑器仍在 recording.cpp；Linux 缺失 | `video_editor/core`、ui、根会话统一三端 | `media` 管 probe/preview/seek/export/waveform；`graphics/windowing` 提供嵌入表面；无后端时共享 UI 报不可用，不能继续造平台专用简化编辑器 |

截图扩展清单必须覆盖矩形、箭头、文字、实心/马赛克覆盖、OCR、翻译、贴图、滚动截图及用户自定义贡献。选择、取消、确认是宿主会话控制；撤销重做消费文档历史。每个按钮可配置，不意味着每个按钮都要独立 Wasm 包或三份系统代码。

## components 全量归属

| 旧模块 | 共享部分 | 平台部分 |
| --- | --- | --- |
| `components/desktop_capture` | 捕获计划由所属功能提供 | `platform/macos/capture` 的桌面快照；Windows/Linux 对应实现从 capture 模块拆出 |
| `components/hud` | 录制控制/状态布局进入 recording/ui，通用控件进入 shared/ui | Windows 窗口与渲染桥；并入相应 graphics/windowing 能力 |
| `components/icons` | 图标身份/几何与生成资产供 shared/ui 消费 | `platform/shared/graphics` 可保留通用低层资产表示，macOS 适配只做绘制；输入 SVG 和许可证留 assets |
| `components/image_effects` | 覆盖形状/马赛克粒度与作用区域由 capture 决定 | 像素执行到 graphics 或经验证的 platform/shared/image；同步 native/shared/pixelate.h |
| `components/media_analysis` | 波形时间映射和 UI 在 video_editor；缓存身份/任务状态在会话 | `platform/<os>/media` 解码和采样，完成/取消回报给共享会话 |
| `components/selection` | 三端共用几何、选区交互和语义 | `windowing` 输入/枚举/坐标；与 plugins/feature/select 一起迁移 |
| `components/shared_canvas` | 描述协议、主题、语义在 shared/ui | `graphics` 绘制解释器、测量、视频表面；不能把时间线逻辑移回原生 |
| `components/style_controls` | 属性 Schema、布局、取值与显隐统一到 shared/ui + 功能描述 | 原生 IME/焦点桥到 windowing；替换前验证数字/文本组合输入、无效值、取消与提交 |
| `components/theme` | 主题 token 和控件配色到 shared/ui | 系统深浅色/高对比等外观信号由平台报告 |

迁移不会为齐目录而建立空壳后端。尚未抽出的产品 UI 可暂留原路径，必须绑定上述工作包和删除条件；不能搬入 platform 后就宣布它已成为薄适配层。纯改路径与提取产品逻辑分开提交。

## 入口、运行时与资源归属

| 当前范围 | 目标和边界 |
| --- | --- |
| `native/macos/main.m`、`native/windows/main.c`、`native/linux/main.c` | 平台进程/消息循环在 `platform/<os>/app`；功能装配、命令路由、会话/退出/忙碌策略到 MoonBit app。Linux 的 begin_recording 目前指快捷键录入，不能计为屏幕录制实现 |
| `native/macos/preferences/*` | 设置模型、插件目录、排序预检与通用 UI 到 app/preferences 和 plugins/runtime；系统快捷键冲突检查到 platform/input，落盘到 storage。每端只实现原生事件/授权入口 |
| `native/macos/shortcuts/*` | 全局注册/释放到 platform/input；默认值、冲突和行为选择复用 app/shortcuts |
| `native/macos/runtime/*` | 独立测试身份、profile 和路径选择到 platform/app/storage；不混入插件版本语义 |
| `native/macos/plugins/*` | 包结构/策略/贡献/调用与迟到结果校验到 plugins/contracts/runtime，结果 UI 到 shared/ui；文件事务到 storage，worker/引擎桥到 plugin_host |
| `native/tools/plugin-worker.m` | worker 独立可执行入口归平台 plugin_host，进程协议/限制尽量共用；Windows/Linux 执行宿主仍需补齐，不复制三套策略 |
| `native/macos/updates/*`、`native/windows/updates.*`、`native/linux/updates.*` | 版本/资产选择到 app/updates；下载、验签与替换到 platform/updates；旧 feed、GitHub 发现、正式身份均单独验收 |
| `native/shared/*.h` | ABI 声明与所有权到 bindings/c；其中 pixelate.h 是含实现的像素算法，执行部分分到 platform/shared/image，不能当普通头文件一概搬走 |
| `native/tools/generate-app-icon.m` | 构建工具留 scripts 的平台辅助目录，不成为运行时插件 |
| `native/windows/app.ico`、`app.manifest`、`resource.h`、`resources.rc` | 平台打包资源归 platform/windows/app；图标源和生成规则在 assets/scripts，不重画三套图标 |
| `native/linux/launch.sh`、`moojicut.desktop.in` | 平台发行入口与桌面集成归 platform/linux/app；同步打包路径与安装/卸载说明 |
| `plugins/system/builtins.json` | `build/native-modules.json`，明确只管编译链接。同步 native_modules.py 的路径/归属规则与测试，不将其作为动态贡献注册表 |
| `plugins/user-runtime/README.md` | 作者规范归 plugins/spec；当前 v1 限制保留到替换发布，同步示例与打包脚本，不建设旧 v1 兼容层 |
| `plugins/examples/*` | 留在根 plugins/examples；用真实导入/运行回归验证规范和实现一致，不只检查 ZIP 可解压 |

平台能力分类补齐为：app、input、windowing、graphics、capture、recording、audio、media、text_services、storage、ipc、plugin_host、updates。分类按实际依赖建目录，不要求三端具有完全相同的文件树。

恢复上次视频草稿归 app/video_editor 命令；录制后端不创建编辑器。它只回报完成素材及附属数据，由 app 按 recordingId/generation 保证单次交接。迁移时解除 macOS recording→video_editor 的原生头文件和构建依赖，旧 ABI 如需暂留只做同仓薄转发。

每批拆分附以下资源所有权表，禁止仅搬类名而漏掉持有者：

| 资源 | 权威所有者与平台执行 | 何时允许释放/交接 |
| --- | --- | --- |
| 原始录制/partial | recording session 持素材身份，平台 writer 持打开文件 | writer 确认收尾后才发布成功；失败保留可恢复文件，原片与可再生成预览分开清理 |
| 采集流/设备/编码器 | recording session 持租约，平台后端执行 | 停止请求不等于已释放，必须有 finalized/failed + cleanup 回执 |
| MoonBit 文档与 UI 会话 | 功能根会话，app 注册与串行调度 | 未提交编辑/保存失败时拒绝丢弃，后台只拿复制计划，不跨线程共享可变句柄 |
| 草稿/附属标记 | 功能会话负责版本和事务，storage 原子落盘 | 保存确认才标成功；失败保留内存可重试，不删除源媒体 |
| 预览/导出/波形 | video_editor session/app jobs，media 执行 | cancel 后等回执，迟到输出验证 job/generation；预览和缓存可再生成，原片不可按缓存清理 |
| worker/管道/引擎 | plugins/runtime 持实例与调用，plugin_host 执行 | 进程退出和输出排空后释放；保留有录制/工程引用的版本 |
| 窗口/输入捕获/IME | 功能 UI 状态，windowing 持系统对象 | 提交/取消完成后销毁；菜单或回调仍持租约时先退役，后回收 |
| 全局热键/监听器/定时器 | app 或所属功能持登记票据，平台执行 | 禁用/退出撤销登记，所有回调带会话代次，不以关闭窗口代替解除注册 |

故障注入至少覆盖磁盘满、只读目录、最终改名失败、探测失败、双 stop、迟到 start/完成、退出/更新、IME veto。macOS 失败路径在真实 writer 完成前清空引用的风险也纳入收尾审查；它是待验证竞态，不以静态阅读断言已丢失媒体。

## MoonBit 包逐项归属

| 当前包 | 目标与状态 |
| --- | --- |
| `features/capture`、core、ui、extensions/annotations | 第一批结构已迁；annotations 目前仅属性与默认值，固定工具分发和 ui→annotations 仍需泛化，不是完整插件化 |
| `features/recording/core` | 已拆出；当前只是状态转换/参数策略，尚无统一资源会话与三端能力模型 |
| `desktop` | app/shortcuts |
| `pin` | capture/extensions/pin |
| `selection` | shared/geometry；不要与新的共享框选 UI 混为一包 |
| `updates` | app/updates |
| `feature_runtime` | plugins/runtime；现在只是启停门控，不能计为通用取消、排空与版本租约实现 |
| `tool_registry` | 通用贡献目录/配置到 plugins/runtime；固定内置描述迁到各功能 extensions，由 app 注入 |
| `plugin_protocol` | 通用字段到 plugins/contracts，截图业务字段到 capture/core 契约；新协议一次替换旧插件 v1 |
| `video` | video_editor/core 的旧草稿读取/转换及共用几何；拆掉旧编辑器后清理无调用 API。视频草稿保护与插件 v1 兼容是两件事 |
| `video_project` | video_editor/core 文档、命令、RenderPlan；会话装配到功能根 |
| `video_ui` | video_editor/ui；可复用绘制描述/图标/主题按真实消费者提到 shared/ui |
| `protocol` | shared/protocol |
| `test_support` | shared/test_support，仅测试导入 |
| `src/api_*.mbt`、`moon.pkg`、`preview.mbt` | ABI 薄转发与启动自检；变动同步生成接口、bindings 和所有调用者，不以 alpha 为由留下悬空符号 |

## 构建与交付不能漏迁

| 范围 | 必须同步 |
| --- | --- |
| scripts/native.py、desktop.py、native_modules.py | 所有源文件、include、对象路径、链接依赖、Swift 桥、工具入口与打包资源；新平台源文件只登记一次，未使用模块也做归属检查 |
| scripts/check_module_boundaries.py、check-shared-video-ui.py | 包所有权映射、依赖约束、共享组件宿主路径；迁移不能通过删检查绕过错误 |
| scripts/install_moon.py、install_extism.py、install_sparkle.py | 固定版本、平台资产、校验、许可证与打包；新增平台引擎必须有实际加载证据 |
| scripts/generate_icons.py、package_plugin.py | 输入源/生成产物路径；插件 Schema、入口、示例、打包同时升级 |
| scripts/native_profile.py、prepare_update.py、generate_update_feed.py、verify_update.swift | 隔离测试身份、签名/feed/资产、正式安装位置、录制忙碌与保存失败时的更新策略 |
| test/build/*、test/native/*、包内测试 | 路径敏感 fixture、源码检查、实际宿主链接及生命周期；已有行为回归不能随文件删除而消失 |
| .github/workflows/native-preview.yml | 新 platform/bindings/build 路径触发、固定工具链、生成接口、Windows 和 Linux 依赖与产物；Xvfb 不代表 Wayland 验收 |
| .github/workflows/website.yml、website | 官网单独构建；平台支持、下载入口、版本文案与实际发布一致，架构迁移不重做网站 |
| assets、updates、根构建元数据 | 图标/许可证和更新源继续受版本管理；各端产物命名与 MoonBit 资产筛选一致 |

当前根 `updates/macos.xml` 仍指向 alpha.9；新版 GitHub 发现与旧固定 feed 是两条升级入口。后续发包必须分别检查，不能把“设置里有更新按钮”写成三端自动替换均已完成。Windows/Linux 当前下载校验后手动换装，自动替换是另一个交付项。

构建清单目前只有 sources/requires，不含全部系统链接依赖。迁移账本还必须核对 framework/系统库、Swift 桥、SDK/最低系统、worker/运行时库/rpath、CLI、图标/字体、OS manifest、许可证、启动脚本、feed、公钥及构建元数据。实际规则可继续由脚本执行，但必须与产物白名单、源 SHA 和解包验证对应。

归属检查需从“清单里列出的文件有效”补到“范围内源码、头文件、.inc、运行资源都已登记或明确排除”；维护工具/fixture 例外，测试遗漏源、重复归属、同名对象、漏资源、非法原生跨功能依赖的反例。现有 MoonBit 检查只覆盖 imports，不能证明原生产品逻辑已抽出。对完成迁移的模块再加原生导入约束，不能靠删检查过关。

目前原生 CI 只有 Windows/Linux，Linux 使用 Xvfb；macOS 需可重复的受控验证机或后续 CI 入口。每包分别记录 core、共享 UI、媒体、插件、CLI、包验证“通过/失败/未测/不适用”。`check-shared-video-ui.py` 有独立硬编码链接路径，必须与主构建同步。仅改 platform/bindings/build 文件也应触发原生流水线；Wayland、真实权限/设备、混合 DPI/IME、实际升级另外验收。网站构建保留自己的 Node 工具链与发布产物，不打进桌面包。

## 首要问题与实施工作包

顺序基于真实用户流程；每包仅迁移完成该能力所需的文件。其余目录逐包跟进，不等全仓搬完才交付功能。

| 工作包 | 依赖与范围 | 完成条件 |
| --- | --- | --- |
| R0 录制原片保护 | 立即优先；区分原始采集文件与可重建预览/导出文件 | Windows 编码失败、最终改名失败、探测失败时保留可恢复原片并报告路径；只有派生产物按取消策略清理；故障注入证明原片不被无条件删除 |
| B1 能力与共享端口 | 与 R0 并行；从真实录屏选源提取最小接口 | 来源、坐标/时基、音源、权限/可用性、取消完成与资源所有者有类型；UI/CLI 使用同一状态，未实现明确不可用；不先建设全能媒体框架 |
| E0 小媒体端口验证 | 与 C1/C2 并行，早于依赖编辑器交接的 D3；不前置整个 E1 | 在 Windows/Linux 验证带同步点素材的 probe、内嵌预览、时钟/seek、最小 RenderPlan 导出和取消；测时长、顺序、裁剪、实际变速/空隙与音画，不凭库名假设可行 |
| C1 Windows 区域录制 | R0、B1；从 recording.cpp 分离采集/媒体/旧编辑器，复用共享选区规则 | 从真实入口框选→倒计时取消或开始→停止→可播放文件；混合 DPI/窗口关闭/失败收尾验证；暂缺音源明确标记 |
| C2 Linux 基础录制 | B1；先验证 X11 与 Wayland 视频来源/编码/依赖，再接统一会话 | 两环境分别完成最小采集文件与取消/停止；Wayland 系统选源是允许的流程；不能以 Xvfb 冒充 Wayland 验收，阻塞项独立记录 |
| B2 通用截图贡献与属性 UI | B1 可并行；注册描述注入、三端画布/IME桥、内置工具提取 | 新增一个声明式工具无需改三端按钮枚举；两组工具栏、顺序/启停/主题/光标、属性和中文 IME、撤销通过；OCR/翻译/贴图也进入统一贡献目录，滚动仍默认关闭 |
| D1 新插件协议贯通 | B2；通用策略+三端 worker 执行；直接替换 v1 | 相同 ZIP 三端导入、开关/排序、调用并应用受控结果；非法包/超时/停用/更新/迟到结果/排空回归；旧 v1 明确拒绝，不增兼容路径 |
| D1b 异步图像贡献 | D1 的编号框之后，图像端口单独冻结 | 第二个操作经授权读取已渲染选区快照并异步返回结果，验证有界传输/资源 token/遮挡/过期/取消；未完成前不称“完整截图插件能力” |
| D2 CLI 与应用通信 | B1 的命令描述可提前做；随 C/B2 接能力，随 D1 接插件命令 | 独立 moojicut-cli 可执行包，发现/会话/调用/任务/取消贯通；UI 与 CLI 同一权威状态，查询无副作用；三端发行包和干净目录调用验证 |
| D3 录制标记 | C、D1/D2、E0；媒体时钟与 sidecar 交接 | 内置和用户贡献同路由，暂停时间对齐、请求去重、持久化、素材交接和编辑器映射；插件停用/卸载不损坏媒体或既有标记 |
| E1 编辑器媒体对齐 | C 产出真实素材；抽出 Windows 旧编辑器，接三端共享 v2 UI | 内嵌预览/seek/真实片段速度/音画链接/导出/波形；同序列编辑得到同语义成片，草稿保存重开与失败保护通过 |
| E2 OCR 与翻译后端 | B2 的贡献/结果 UI；库选型单独验证 | Windows/Linux 真实识别/翻译、语言资源/取消/模型不可用/结果编辑验证；不把 macOS 系统服务存在推导为三端都有 |
| E3 应用宿主与交付 | 各能力切片随接入迁移；设置/快捷键/退出/更新单独记账 | 三端实际快捷键入口与冲突/释放、设置持久化、忙碌时退出/更新、隔离测试身份；Windows/Linux 自动替换需独立方案和安装回滚验收，当前手动换装状态不冒充完成 |
| F 滚动与后续视频扩展 | 独立稳定性/性能验证；不阻塞 C/D | 滚动先验证真实页面再决定开放；多素材/字幕/效果/实时处理按用例定义契约，沿统一命令/任务/资源路径 |

R0 代码证据：`plugins/feature/recording/windows/recording.cpp:444–465` 对录制和导出共用 launchJob，异常后无条件删除 partial；最终 MoveFileEx 失败也走这条清理路径。**本次评审只登记并提高优先级，尚未修复，不得将方案修订写成问题已解决。**

原始 partial 即使尚未证明能解码也保留，标注“未完成/未验证”及错误路径；不能以无法立即恢复为理由主动删除唯一字节。C1/C2 的采集/会话与共享 UI 分栏结项：先得到视频文件不代表已完成共享选区/倒计时/控制条；后者必须实际消费同一 MoonBit 描述和事件模型，通过目标端输入回放。基础视频文件验证不等待完整 B2。

D2 补充产物契约：独立 MoonBit executable target；包内 moojicut-cli(.exe)，不依赖仓库、编译器、Python 或 Node；IPC 端点发现、profile、当前用户访问与版本握手统一。Windows 验证控制台和重定向，macOS helper/CLI 纳入签名与包清单，Linux 更新启动脚本及安装说明；测试只连隔离实例。文件名不能仅靠大小写与 GUI 区分。

B2/D1 共同验收跨窗口原子生效：窗口 A 可提交，窗口 B 正在中文组合输入；从设置或 CLI 停用/升级同一贡献，A、B、配置和活动版本均不变。B 结束组合后重试，全部检查通过且存储提交成功后统一发布；旧调用按租约取消/排空，迟到结果不得应用。持久化失败、检查后版本变化同样不允许部分窗口先切换。

录屏基础能力 C1/C2 不等待 D1 外部插件协议完成；B2、CLI 命令描述可并行。无法实机验证的平台状态保持“待验”，不为目录对称填入完成标记。

B1 来源验证明确区分自有桌面框选、系统选源、已授权来源内裁剪、跟随窗口和固定桌面区域。结果携带不透明来源身份、坐标空间、逻辑/像素尺寸、缩放、generation、权限状态与释放责任；不将 macOS windowID+全局矩形当成三端通用对象。X11/Wayland 最小持续取帧、取消、来源关闭/显示器断开先有实证，再冻结公共选区接口。

B2 在扩大迁移之前先通过 macOS+Windows 的同一完整切片（声明按钮、颜色/数值、多行文本、IME、语义、图像导出），再补 Linux X11/Wayland 输入后端；三端未全接时分开记状态。E0 的窄验证提前降低播放器/编辑交接风险，完整剪辑体验仍在 E1；不让全部 UI/媒体库建设阻塞 C 的可播放录制文件。

系统与依赖前提：当前 macOS Swift 链接最低版本为 26.0，这是现有包门槛，不能先宣称只是翻译在旧系统不可用；Windows/Linux 当前发行包 unsigned，查询/下载/替换/重启/签名分别验收。Linux 记录具体 compositor/portal 与依赖；音频回环、麦克风、摄像头、暂停、设备热拔插分别建能力，不从“视频已录制”推导支持。OCR/翻译后端和语言模型的分发/许可在 E2 选型验收，不提前宣传。

## 工作包验收记录格式

每包提交前列出：基线提交、旧模块→新归属、仍留在原生的产品判断、平台支持/限制、CLI/插件接入状态、自动测试命令、实机环境/结果、未验收项、原有数据与资源保护证据。发布前另列版本、资产、签名、安装位置、实际升级结果。

禁止用“共享核心完成”代替整个功能完成。一次变更的实现者和审查者不同；移动中的同一文件只允许一个写入者。统筹负责合并结论和关闭缺口，不能只把评审报告堆在附件中。

## 本轮独立评审与处理记录

三路评审均针对 `14bbbea` 做静态源码核对，没有启动应用或重跑测试。M 表示全仓迁移评审（4 项 P1、4 项 P2）；U 表示插件与共享 UI（6 项 P1、5 项 P2）；P 表示平台能力（3 项 P1、4 项 P2）。合计 26 条原始意见，存在交叉覆盖；以下按问题合并记录。记录“纳入方案”不等于代码修复、功能完成或实机通过。

| 来源意见 | 处理决定 | 实施/验证状态 |
| --- | --- | --- |
| M1、U-P2-01 | 8 个旧功能与三端嵌入实现逐项映射；OCR/翻译/滚动/贴图/标注全部登记；recording→app→editor 交接 | 台账已补，原生提取与贡献接入待做 |
| M2、U-P1-02、P-P1-3 | B2 真实第二平台样板；文本/数字草稿、IME、焦点、语义、图像导出是验收项 | UI桥待技术验证，不把已有视频画布当完整文本客户端 |
| M3、U-P1-05、P-P1-1 | 分开失败/排空/原片/派生产物；补资源 owner 表，Windows 原片问题列 R0 | Windows 路径问题已由主控核对，代码尚未修复；macOS 收尾竞态待注入验证 |
| M4 | 固定独立 moojicut-cli(.exe)、可执行包/IPC/签名/产物/控制台验收 | 名称和方案已确定，CLI尚未实现 |
| M5 | 源码/头/.inc/资源完整归属与原生导入约束；pixelate 实现、runtime worker 单列 | 现有检查仍是旧范围，扩展检查随对应迁移提交 |
| M6、P-P2-3 | 四环境分层记录，更新 platform/bindings/build 触发；独立媒体fixture与受控mac验证入口 | 后续每包提供本次提交证据，本轮无三端实测 |
| M7、P-P2-4 | 链接/运行库/helper/CLI/许可证/签名账本；更新按查询/下载/替换/重启分开 | Win/Linux自动替换仍未实现，mac旧固定feed风险保留 |
| M8 | 修正 annotations 依赖箭头、历史路径、user-runtime实际位置；限定旧video退出批次 | 文档已修，alpha.9固定源事实保留；本地未受控旧README不作为基线缺陷 |
| U-P1-01、U-P2-05 | 有限贡献描述，app注入处理器，runtime不导入功能；UI不固定枚举；槽位/配置/可用性/依赖分开 | B2/D1待实施；现有 ui→annotations 明确为过渡 |
| U-P1-03、P-P2-2 | 能力取真实支持/声明/授权/会话/租约/系统权限交集；受遮挡的只读快照、有界token；编号框和D1b两案例 | 不复用64KiB JSON承载任意图片；像素端口验证前不开放 |
| U-P1-04 | 安装只校验与纯健康检查，无业务invoke/授权/剪贴板/录制副作用 | 新协议切换时删除旧逐工具probe路径，旧v1不兼容 |
| U-P1-06 | 明确标记附属文档、媒体时基、去重、保存回执及app/editor交接 | D3待实施，插件卸载不删除已保存标记 |
| U-P2-02 | 通用安装/租约策略与可移植worker底层共用；平台仅进程/文件/签名等差异 | 三端worker、包原子发布仍需实际验证 |
| U-P2-03 | 每贡献图标/消息资源进入白名单和摘要；tooltip/无障碍与CLI共用身份 | B2/D1随契约和打包器一起实现 |
| U-P2-04 | 首批仅核心已有图元；自定义持久对象、效果RenderPlan、包GC与项目引用另阶段设计 | 明确后置，不用任意JSON/万能回调假装已支持 |
| P-P1-2 | B1先验证四环境实际来源；句柄/坐标/缩放/generation/释放明确，Wayland不假设窗口枚举 | 来源协议冻结前有取帧/取消/断开证据 |
| P-P2-1 | E0小媒体端口验证前置，与C并行；完整编辑器仍E1 | 接受顺序修订，不等待全部视频功能才补录屏 |

取舍：未采用“先做完全仓目录迁移，再交付功能”的串行方案；构建/路径清单随每个完整用户流程同步调整。未新增 v1 插件兼容层、MCP、通用 GUI 框架或提前发布独立库。这些取舍不减少三端能力、资源安全和发布验收要求。

复核结果：三路评审均已再次核对修订稿，并确认各自提出的方案问题已处理。复核追加的 pixelate 摘要例外、C 采集/共享 UI 独立结项、D3 对 E0 的依赖、跨窗口配置原子生效均已补入。结论仅覆盖本轮架构和实施规划；R0 及能力矩阵中的未实现/待验项目仍未关闭。
