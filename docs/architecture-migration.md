# 架构迁移台账与平台交付

初始源码核对基线：`14bbbea`，2026-11-17；实施进度更新至 2026-11-18。本文是[架构主文档](architecture.md)的实施台账，不另立一套架构。目标路径均是待实现归属，除明确标注外，不表示目录或功能已经存在。

## 状态如何记录

每个工作包分别记录：**归属与依赖、MoonBit 共享规则、共享 UI、平台执行、插件接入、CLI、自动回归、实机验收、发布更新**。某一项通过只更新该项；目录存在、编译成功、模型测试通过，都不能代替真实交互和媒体验收。

平台矩阵分 macOS、Windows、Linux/X11、Linux/Wayland。具体系统版本、显示服务、后端、输入法和运行证据随验收记录，不能只写一个 Linux 勾选框。功能的实际可用性包含后端支持、依赖是否安装、设备、权限、会话状态，不能只有操作系统名称。

## 当前源码速览（2026-11-18，尚未发布）

以下是当前实现，不与后文初始审计混用；各批验证证据见末尾实施记录。最新发行包仍为 alpha.20，不能由 main 的进度推断安装包已包含这些变化。

| 能力 | macOS 生产入口 | Windows 生产入口 | Linux 生产入口 |
| --- | --- | --- | --- |
| 截图标注、贴图 | 已接；复制、滚轮/边界等比缩放 | 已接同类基础操作 | 已接；Wayland 位置/置顶受桌面后端约束 |
| 工具贡献、启停和排序 | 共享 MoonBit 目录 | 共享 MoonBit 目录 | 共享 MoonBit 目录 |
| 二级属性与圆色块 | 共享尺寸/间距值，原生控件 | 共享尺寸/间距值，原生控件 | 共享尺寸/间距值，原生控件 |
| 基础录屏 | 区域/窗口/整屏及系统音频 | 区域 MP4，静音 | X11 区域与 Wayland ScreenCast/PipeWire，静音 WebM |
| v2 视频编辑 | 共享根会话/UI、正式预览/导出与波形，本地回归通过 | 五项媒体/共享宿主、App 和画布检查通过；编辑窗口 fixture 超时待收口 | Ubuntu 22 已过真实媒体、共享宿主、编辑窗口及包验证；Ubuntu 24 同包验证被依赖下载阻塞，尚未运行 |
| OCR、翻译、用户 ZIP 插件 | 已有后端；用户插件仍为元信息输入/文本输出 v1 | 未接对应后端 | 未接对应后端 |
| 更新安装 | 内置安装链 | 下载校验后手动换装 | 下载校验后手动换装 |

Windows/Linux 的共享画布已通过独立宿主调用真实 v2 MoonBit 工程；新生产录制后编辑流程已接线，Ubuntu 22 已通过本批正式媒体与编辑窗口验证，Windows 和 Ubuntu 24 状态分别记录，不能沿用上一批画布绿灯替代验收。画布不拥有第二份剪辑模型，切分、空隙、历史和视口规则仍由 MoonBit 决定。三端麦克风/暂停、完整属性 Schema、用户插件 v2、独立 CLI/IPC仍未完成。

结构约束仍在构建入口执行，新增画布没有增加原生跨层 include 例外。现有 12 对历史例外、旧 components/plugins/feature 和宿主混合职责仍按下表迁移；目录归位、生产接入、自动回归和实机效果分别验收。

## 三端能力历史基线（14bbbea）

以下保留最初源码审计，**不是当前完成度**；后续已补区域录制等能力，见末尾实施记录。它不代表本轮实机通过。macOS 的既有自动回归与 Windows/Linux 历史 CI 只作为各自证据，未重新执行的环境不补勾。

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

主要代码依据：`scripts/desktop.py:163` 的发行范围；`plugins/system/builtins.json` 的三端构建入口；`plugins/feature/recording/windows/recording.cpp:603` 的主显示器来源、`:440` 的外部播放器；`plugins/feature/recording/macos/MCMacRecordingController.m:367` 的音源配置；`plugins/feature/capture/linux/portal.inc:97` 的 Screenshot 接口；`native/linux/main.c:340` 的快捷键与录屏现状。该基线时共享能力规则只接 macOS/Windows 计划，不能据此宣称 Linux 后端存在；后续 Linux 实现见下方 C1/C2 记录。

## 旧原生功能逐项归属

这里列全 `plugins/feature` 的 8 个静态模块与混合职责。当前截图贡献目录已共享，但静态模块本身不等于完整的统一运行时插件；后续接入状态以本页速览与实施记录为准。

| 旧模块 | 当前实现与混合职责 | MoonBit 目标 | 平台部分与验收 |
| --- | --- | --- | --- |
| `plugins/feature/capture` | 三端都有；Windows/Linux 同时含图片编辑、工具 UI 与采集，Linux 还含 Screenshot portal | `features/capture` 会话、core、ui；共用框选到 `shared/selection` | `platform/<os>/capture` 接采集，`windowing` 接浮层；截屏与标注分别验收，保留贴图和可见编辑器入画行为 |
| `plugins/feature/image_editor` | 独立目录只有 macOS；另两端编辑器在 capture 中 | 标注、输入事务、工具条、属性栏归 capture 的共享会话/UI；插件结果应用经核心命令 | 原生文本输入桥、绘制及剪贴板到平台；不能只搬 macOS 文件而漏掉另两端嵌入代码 |
| `plugins/feature/select` | Windows/Linux 有目录；macOS 在 components/selection | 几何到 `shared/geometry`，框选/hover/调整到 `shared/selection` | 窗口枚举、坐标/DPI、输入捕获到 `windowing`；Wayland 的系统选源单独处理 |
| `plugins/feature/pin` | 三端有窗口实现；MoonBit 数值/缩放规则已归 features/capture/extensions/pin | `capture/extensions/pin` 贡献与设置已接；通用命令与完整资源租约继续提取 | `windowing` 管置顶、穿透和窗口资源，`graphics` 管图片；停用按既有窗口关闭/菜单退役策略释放，不能把资源回收解释为删除原始图片 |
| `plugins/feature/capture_text` | macOS Vision OCR、Apple Translation、结果窗口与任务控制 | `capture/extensions/ocr`、`translation` 管工作流、输入输出、可编辑结果、取消；通用结果控件归 shared/ui | `platform/<os>/text_services` 执行 OCR/翻译；三端实现与模型资源待分别验证，不能在无后端时承诺同等可用 |
| `plugins/feature/scroll_capture` | 仅 macOS 原型；默认关闭；采集、HUD、重叠拼接混合 | `capture/extensions/scroll_capture` 管会话/UI与拼接计划；重叠算法优先共享 MoonBit | 获取帧留 capture；实测若需底层像素计算，才提到 platform/shared/image；继续默认关闭，独立页面稳定性验收 |
| `plugins/feature/recording` | macOS 采集/选区；Windows 已移除旧编辑器与剪辑导出，采集/编码仍待归位；Linux 宿主已接 platform/linux/recording | `recording/core` 与倒计时 UI 已共享；完整会话编排与音源仍需提取，Win/Linux 完成素材经 App 回调交接 | `recording`、`audio` 管采集和时间戳，媒体执行归 `media`；Windows 区域选区与 Linux 基础视频流已接，音频/暂停待补 |
| `plugins/feature/video_editor` | macOS 旧文件路径仍在，但已消费共享根会话；Windows/Linux 已接 platform 下薄窗口及共用原生宿主 | `video_editor/core`、ui、根会话已实现，三端消费同一文档和会话规则 | `media` 管 probe/preview/seek/export/waveform；`graphics/windowing` 提供嵌入表面；Ubuntu 22 通过，Windows 窗口及 Ubuntu 24 同包检查待收口，不造平台专用简化编辑器 |

截图扩展清单必须覆盖矩形、箭头、文字、实心/马赛克覆盖、OCR、翻译、贴图、滚动截图及用户自定义贡献。选择、取消、确认是宿主会话控制；撤销重做消费文档历史。每个按钮可配置，不意味着每个按钮都要独立 Wasm 包或三份系统代码。

## components 全量归属

| 旧模块 | 共享部分 | 平台部分 |
| --- | --- | --- |
| `components/desktop_capture` | 捕获计划由所属功能提供 | `platform/macos/capture` 的桌面快照；Windows/Linux 对应实现从 capture 模块拆出 |
| `components/hud` | 录制控制/状态布局进入 recording/ui，通用控件进入 shared/ui | Windows 窗口与渲染桥；并入相应 graphics/windowing 能力 |
| `components/icons` | 图标身份/几何与生成资产供 shared/ui 消费 | `platform/shared/graphics` 可保留通用低层资产表示，macOS 适配只做绘制；输入 SVG 和许可证留 assets |
| `components/image_effects` | 覆盖形状/马赛克粒度与作用区域由 capture 决定 | 像素执行归 graphics；共享 pixelate.h 已由 native/shared 迁至 platform/shared/image |
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
| 原 `native/shared/*.h` | 已迁：15 个 ABI 声明在 bindings/c；pixelate.h 实现在 platform/shared/image。全部同仓 include 已更新，函数符号与所有权不变 |
| `native/tools/generate-app-icon.m` | 构建工具留 scripts 的平台辅助目录，不成为运行时插件 |
| `native/windows/app.ico`、`app.manifest`、`resource.h`、`resources.rc` | 平台打包资源归 platform/windows/app；图标源和生成规则在 assets/scripts，不重画三套图标 |
| `native/linux/launch.sh`、`moojicut.desktop.in` | 平台发行入口与桌面集成归 platform/linux/app；同步打包路径与安装/卸载说明 |
| 原 `plugins/system/builtins.json` | 已迁 `build/native-modules.json`，只管构建；全量原生文件、头、片段、资源及实际 include 已纳入检查，不作为动态贡献注册表 |
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
| `features/capture`、core、ui、extensions/annotations | 结构已迁；annotations 已声明内置工具并处理通用拖框命令，其他扩展声明自身贡献；完整属性 Schema 和 ui→annotations 仍待泛化 |
| `features/recording/core`、ui | 已归位；live flow、静态能力/参数策略与倒计时面板已共享，完整资源会话及动态能力快照仍待做 |
| `app/shortcuts`（原 desktop） | 规则已迁；平台全局注册/释放仍由宿主执行 |
| `features/capture/extensions/pin`（原 pin） | 数值/缩放/可见性规则已迁；贡献接入与窗口资源提取另验 |
| `shared/geometry`（原 selection） | 已迁；不要与新的共享框选 UI 混为一包 |
| `app/updates`（原 updates） | 版本/资产规则已迁；平台下载/安装不在此包 |
| `plugins/runtime/lifecycle`（原 feature_runtime） | 已迁；现在只是启停门控，不能计为通用取消、排空与版本租约实现 |
| `plugins/runtime/catalog`（原 tool_registry） | 目录/配置已迁；贡献已由各功能 extensions 声明、app/tools 注入；通用目录不再导入固定功能 |
| `plugins/contracts`（原 plugin_protocol） | 当前 v1 校验已迁；通用字段与截图业务契约后续拆分，新协议一次替换旧插件 v1 |
| `features/video_editor/core/legacy_document`（原 video） | 已有旧草稿读取/转换、宿主 API 与时间线几何已迁；拆掉旧编辑器后清理无调用 API。视频草稿保护与插件 v1 兼容是两件事 |
| `features/video_editor/core`（原 video_project） | 文档、命令、RenderPlan 已迁；功能根新增权威会话、不可变媒体计划与回执生命周期 |
| `features/video_editor/ui`（原 video_ui） | 已迁；可复用绘制描述/图标/主题按真实消费者提到 shared/ui |
| `shared/protocol`（原 protocol） | 已迁 |
| `shared/test_support`（原 test_support） | 已迁，仅测试导入 |
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

alpha.20 发布后，根 `updates/macos.xml` 已同步该版签名 feed；新版 GitHub 发现与旧固定 feed 是两条升级入口。后续发包必须分别检查，不能把“设置里有更新按钮”写成三端自动替换均已完成。Windows/Linux 当前下载校验后手动换装，自动替换是另一个交付项。

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

R0 基线证据：`14bbbea` 的 `plugins/feature/recording/windows/recording.cpp:444–465` 对录制和导出共用 launchJob，异常后无条件删除 partial；最终 MoveFileEx 失败也走这条清理路径。后续代码修复与验证见末尾实施记录，方案评审通过本身不等于问题已修复。

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
| M3、U-P1-05、P-P1-1 | 分开失败/排空/原片/派生产物；补资源 owner 表，Windows 原片问题列 R0 | R0 代码修复与便携文件故障测试已完成，Windows MF 实测仍待验；macOS 收尾竞态待注入验证 |
| M4 | 固定独立 moojicut-cli(.exe)、可执行包/IPC/签名/产物/控制台验收 | 名称和方案已确定，CLI尚未实现 |
| M5 | 源码/头/.inc/资源完整归属与原生导入约束；pixelate 实现、runtime worker 单列 | 检查已扩展并接入构建；保留 12 对具名旧引用，未宣称混合职责已经全部拆除 |
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

## 实施记录（2026-11-17 起）

### R0：原始录制文件保护

- Windows `launchJob` 已改用 `platform/shared/media/output_file.h` 的文件所有权策略：原始录制的 partial 不自动删除，即使无法立即证明可以解码。只有派生预览/导出的中间文件可自动清理。
- 采集失败时对已经开始写入的 MF writer 尝试一次 Finalize；保留原始错误，Finalize 失败不重试。最终改名禁止覆盖已有目标；改名后探测失败保留最终文件。错误提示携带实际保留路径并注明完整性未验证，录制错误不会被当成静默导出取消。
- 派生任务迟到的取消回调仅删除本次确已发布的目标，发布失败时不删除目标路径上原有的文件。
- 便携 C++ 文件故障测试已通过：中途失败、发布冲突、发布后探测失败、派生清理及原文件不变。Windows 原有 MF smoke 已增加真实样本写入后失败收尾、保留文件解码、真实 MoveFileEx 冲突和迟到取消检查；后续已通过 Windows CI（见本页 C1/C2 验证记录），真实设备交互仍待用户组织验收。
- 文件清理属于平台媒体 I/O；此 C++ 辅助类不承载 UI/录制业务状态。没有引入自动恢复承诺，也没有把 partial 标记为成功素材。

### B1：静态能力与参数计划切片

- `features/recording/core/capabilities.mbt` 统一记录源码已实现的后端/来源/音源/暂停/编码限制；`plan.mbt` 让新请求和现有原生宿主实际共用同一编码策略。已有生命周期规则仍在 `recording.mbt`。
- 新增纯查询 ABI `recording_capabilities` 与严格请求 ABI `recording_request_plan`。Windows 当前只接受主显示器静音录制，不支持的来源/音源/暂停明确拒绝；Linux X11/Wayland 分别可查询，但均不能生成可执行录制计划。
- `supported` 仅代表源码静态支持；`permission=unknown`、`availability=unverified`、`requiresHostValidation=true` 防止把成功计划误当成实际授权。接口不弹权限窗、不获取来源、不启动录制。
- 本轮全量 MoonBit native/Wasm 各 **181/181**、构建与便携故障测试 **21/21** 通过；真实原生 C ABI 测试覆盖输入/输出引用所有权、新旧策略一致与严格拒绝音频。新增 ABI 回归已进入 `test/native/core-embedding.m`，公共接口由固定工具链重新生成。
- B1 切片与 R0 分别由另一代理只读交叉审查，R0 的录制取消错误提示缺口已按审查修正并复核。
- **B1 整体仍未完成**：运行时能力探测、来源身份/坐标转换/媒体时基/generation、取消与资源释放回执、UI/CLI 接入仍待 C1/C2 真实来源验证后落实。此处保留现有宿主 ABI 是为了让正在运行的宿主继续使用同一策略，不是插件 v1 兼容层。

### C1/C2：区域录制与共享准备流程

本节记录继 `fb890b0` 后的功能接入；上方矩阵仍是 `14bbbea` 审计基线。用户已明确实机测试由其后续组织，未验项目继续保留，不以此阻塞实现。

| 层次 | 本批实际接入 | 仍待完成/验证 |
| --- | --- | --- |
| MoonBit core | 不复用的会话句柄、绝对单调截止点、一次启动效果、停止/取消到资源释放回执、活动 close 拒绝；四环境编码计划 | 来源能力动态快照、媒体时间轴与插件/CLI 服务协调 |
| MoonBit UI | 同一倒计时/计时文本、面板/按钮矩形、命中与小窗字号；Windows/Linux 生产入口消费 | macOS 新 UI/flow 迁移；完整选区画布及可访问性语义统一 |
| Windows | 自由框选→3 秒可取消倒计时→所选物理区域采集→停止/Finalize→保留 MP4/现有编辑器；截图与录屏共用提取的 selection surface；MSVC 构建、自动媒体 smoke 与包验证通过 | 混合 DPI/窗口排除/实际输入留实机；跟随窗口和旧媒体/编辑器拆分仍待做 |
| Linux X11 | 自有选区、物理像素换算、GStreamer ximagesrc→VP8/WebM、托盘与 --record/--stop；Ubuntu 原生编译、Xvfb 媒体 smoke 与包验证通过 | 多显示器/DPI/桌面环境实测；选区尚非完整共用画布 |
| Linux Wayland | libportal ScreenCast 授权→PipeWire fd/node→真实视频尺寸探测→共享倒计时→录制；取消与迟到资源释放 | 目标 compositor/portal 组合与实际授权流程实测；不保证任意窗口全局坐标或自有窗口排除 |
| 媒体/原片 | Linux worker 拥有 pipeline，EOS/NULL/FD 收尾后再完成；失败保留 partial；新目标禁止覆盖 | 与录后编辑器的正式媒体端口 E0/E1；系统音频、麦克风、暂停尚未实现 |
| 构建交付 | 显式 platform.recording 模块；Linux 系统 GStreamer/libportal 依赖、CI 安装与包内说明更新 | Windows/Linux 更新仍为下载校验后手动换装；本批没有改变发行包签名与自动替换能力 |

Windows 只在系统支持窗口排除时显示录中控制条；Linux 开始前隐藏自有倒计时窗口，停止由托盘/GUI 启动参数提供。两个新平台入口均为静音，不能把状态模型中存在 pause 或系统名当成音源已实现。Linux 默认文件在 Videos/Mooji Cut 下的独立录制目录，未设置 Videos 时回退用户 data 目录；完成/失败提示提供实际路径。

Linux `--record/--stop` 利用现有 GTK 单实例转发，属于 GUI 启动控制，**不关闭 D2 独立 CLI 工作包**。录屏扩展/标记和用户插件未在此批假装完成；共享准备 UI 也不代表完整截图或视频编辑 UI 已统一。

本轮已运行：MoonBit native/Wasm 各 **187/187**、构建与文件策略 **22/22**、原生 C ABI 重复调用与所有权检查。LLVM-MinGW 20260908 / Clang 23.1.1 将 `surface.c`、`capture.c`、`main.c`、`recording.cpp` 编译为 Windows x64 COFF；新增源与 main 使用 `-Wall -Wextra -Werror` 通过，截图旧文件保留 5 个既有聚合初始化警告。它不等同 MSVC 链接或 Windows 运行。

新增 Windows 选区输入/实际区域裁剪与完整媒体 worker 闭环、Linux X11/合成视频解码/原片失败保留/迟到回调取消自动 fixture 已加入目标平台 smoke，并随 `dfd817d` 通过 [Native desktop previews #44038639327](https://github.com/CoderSerio/moojicut/actions/runs/44038639327)：Windows 2022/MSVC 与 Ubuntu 22.04/Xvfb 两项构建、测试、打包及生成接口检查全部成功。修复涉及 Ubuntu runner 的 LLVM/GStreamer libunwind 开发包冲突、Windows fixture 使用真实鼠标捕获转移，以及 Linux fixture 的局部变量遮蔽 `stat`；未跳过录制测试或缩小断言范围。

两路实现与独立审查已收口：tooltip 捕获、回调跨线程、起录前来源尺寸变化、无效小选区扩大为全屏均已修正。上述 CI 不覆盖真实 Wayland compositor/portal 授权、多显示器与混合 DPI、用户设备上的快捷键或发布更新；这些继续由实机验收记录。Wayland 当前采用无鼠标的通用 cursor mode，不持久化授权；这些限制需要在后续体验与能力扩展中继续处理。

### alpha.20 发布交付（2026-11-17）

- 三端均从 `57c3c419a346cb05a5726da486c645cdb7deb633` 的干净源码构建；[发布页](https://github.com/CoderSerio/moojicut/releases/tag/v0.1.0-alpha.20) 提供 10 项资产。Windows/Linux 显式使用 alpha.20 版本号，构建、媒体 smoke 与打包见 [44043150444](https://github.com/CoderSerio/moojicut/actions/runs/44043150444)。
- macOS 187 项共享核心、22 项构建/文件策略及完整原生回归通过，随后生成生产 ZIP。更新交付检查确认与现有 alpha.19 的证书、指定签名要求、bundle ID 与更新公钥一致。
- 发布后匿名下载全部 10 项资产，大小与 SHA256 均匹配本地；重新验证公开 macOS feed 和 ZIP 的 Ed25519 签名。相同签名 feed 原样同步到旧固定地址。
- 未安装或启动发布包，未重置权限；真实原位升级、TCC、Wayland 和用户设备交互仍待实机验收。macOS 尚未公证，Windows/Linux 仍是手动换装。

### 2026-11-18：共享结构、录制流程与 Linux 快捷键（当前源码，尚未发布）

本批在 `507772f` 基础上实施；本节描述当前源码，alpha.20 的下载包不自动获得这些改动。CI 与发布分别记录，不用历史绿灯替代本批验证。

- MoonBit 现有包已按 `features/{capture,recording,video_editor}`、`app`、`plugins`、`shared` 归位；旧路径拒绝重引入。`legacy_document` 是旧视频草稿/宿主的过渡实现，不是外部插件 v1 兼容层；拆除旧编辑器后再清理无调用 API。根 ABI 保持不变，迁移前后 native/Wasm 各 197 项测试通过。
- 15 个 C ABI 头移到 `bindings/c`；含实现的像素算法移到 `platform/shared/image/pixelate.h`。静态构建清单移至 `build/native-modules.json`，独立工具 worker 与图标生成器也有显式归属。
- 构建前检查所有原生源、头、`.inc`、资源的登记与实际引用；编译单元不可藏在头文件清单里，宏计算 include 不接受。平台层不得导入功能层，shared 不导入平台；12 对历史文件引用单独登记理由和工作包，未登记的新耦合报错，过期例外也报错。原生混合职责并未因此全部完成迁移。
- macOS 接入与 Windows/Linux 相同的 MoonBit recording flow 和倒计时 frame/text/hit；AppKit 负责绘制与系统事件。失败停止不会冒充资源已释放，收到真实 start/stop/writer 终态后才结束忙碌；失败保留原片。故障回归覆盖迟到 start、连续 stop 失败、writer 先完成与最终 didStop 等回执顺序。录制后直接打开旧编辑器的耦合仍列例外，交接与草稿/退出策略后续一起迁入 app。
- Linux X11 使用独立连接登记全局截图/录屏/停止键，检测冲突，失败回滚，退出释放；Wayland 接 GlobalShortcuts portal，按用户设置操作申请，不提供无效的 X11 兜底。改绑申请中继续执行旧快捷键，未获准前保留旧会话；系统实际返回的按键描述用于显示。不支持的桌面明确提示，托盘/启动参数入口保留。

剩余主线仍包括：共享截图工具栏/属性/输入与贡献描述、三端用户插件新契约和宿主、独立 CLI/IPC、Windows/Linux v2 视频编辑与媒体端口、OCR/翻译、音频/暂停及完整运行时能力。Linux 真实 Wayland 授权、混合 DPI、硬件音视频与用户设备体验由后续实机验收覆盖。

本批本地验证：构建/归属/文件策略 33 项、MoonBit native 197 项及 macOS 完整原生回归通过；包括实际 AVFoundation 编辑/导出、插件 worker 与 Vision OCR。ScreenCaptureKit 回执乱序使用故障 fixture，Apple Translation fixture 不触发真实模型下载。Windows 全部 9 个生产单元严格交叉编译为 AMD64 COFF；这不代替 MSVC 链接/运行。Linux X11 真按键、私有 D-Bus portal fixture、目标编译与打包已经通过本批 CI；真实 compositor 授权留实机。

提交 `e1424e0` 已通过 [Native desktop previews #44150074776](https://github.com/CoderSerio/moojicut/actions/runs/44150074776)：Windows 2022/MSVC 与 Ubuntu 22.04/Xvfb 两项均成功，包含构建、核心/平台回归、打包及生成接口一致性。此批合并推送一次，尚未发布新版本。CI 成功不关闭上文实机验收和剩余能力工作包。


### 2026-11-18：B2 截图贡献接线（当前源码，尚未发布）

本批在 `d2f9e80` 基础上实现，只完成 B2 的贡献目录、工具栏接线和一个真实命令案例；**没有完成整个共享属性/输入 UI 工作包，也没有开放用户插件 v2**。

- `capture/extensions/{annotations,pin,ocr,translation,scroll_capture}` 各自声明贡献；`app/tools` 组装注入 `plugins/runtime/catalog`。通用目录不再定义 Rectangle/Pin 固定工具枚举或功能文案；`plugins/contracts` 只持有限贡献字段。
- C ABI 提供不可变目录快照及候选启停/排序；快照从 app 贡献和已验证 manifest 重建，拒绝伪造 command、kind、icon、slot 或能力字段。关闭后句柄不复用，活动快照数量有上限，读接口不改变状态。JSON/typed 操作统一拒绝跨槽位排序，新增内置工具为已保存条目保留有界余量；输出再次检查大小，避免保存后无法读回。能力不可用与用户是否启用分开记录，缺少 OCR/翻译后端时不能点击执行。
- 三端工具栏读取同一描述与图标资产名称；工具在左，贴图等完成操作在右。macOS OCR/翻译/滚动不再是另一排固定按钮；滚动和编号框默认关闭。设置只允许同槽位排序，用户顺序不充当执行依赖顺序。
- Windows/Linux 新增截图工具管理，预检当前输入后构建候选配置，保存成功才发布；保存失败、IME/未提交文本/拖拽或属性输入阻止变更时保留原工具、文档与配置。Windows 先准备隐藏控件、提交时替换，并拒绝旧按钮延迟消息；贴图菜单资源尚未排空时，启用在写盘前被纯预检拒绝。Linux 控件复制描述，借用宿主持有的当前快照；同步切换后才关闭旧句柄；贴图通用开关与工具开关共用唯一已保存配置，成功停用才回收贴图窗口。macOS 沿用已有多窗口预检/提交机制；NSUserDefaults 的写入调用不提供完整磁盘持久化失败回执，这一限制未因此消失。
- 新增默认关闭的“编号框”内置声明案例。三端通过通用 `dragRect` 交互调用 MoonBit 命令，不为其 ID 新建三套原生按钮分支；共享处理器生成核心已有的矩形与文字，一个命令、一次撤销。取消、过小拖框、陈旧文档版本不提交；多位编号按框内宽高限制字号，JSON 适配拒绝画布外矩形。停用贡献保留已生成图元、导出与历史。
- 编号框目前复用矩形颜色/粗细/透明度样式库并隐藏形状选择。这是有限模板，不是任意自绘 UI、任意图元或完整属性 Schema。现有六属性原生控件、IME 桥、工具栏布局还有产品逻辑；`shared/ui` 的完整迁移继续保持未完成。用户 ZIP 仍是已有 v1 元信息/文本协议，v2 的效果权限、安装、三端 worker 和像素端口留在 D1。

本批本地验证：MoonBit native/Wasm 各 212 项、构建/归属/文件策略 33 项与 macOS 完整原生回归通过。新增真实工具栏、复合图元 PNG 导出/撤销、配置停用不丢内容与分组末尾拖拽回归；排序边界测试证明修复前失败、修复后通过。Windows main/capture/pinning 使用 LLVM-MinGW 严格编译，Linux main/capture 使用 Ubuntu 22.04 真实头文件与 Linux target 严格检查；交叉检查不代替下方目标平台运行结果。Windows/Linux 实机输入、DPI、Wayland 和硬件验收仍由用户后续组织，不以本地交叉编译代替。

提交 `2e37903` 已通过 [Native desktop previews #44157505710](https://github.com/CoderSerio/moojicut/actions/runs/44157505710)：Windows 2022/MSVC 和 Ubuntu 22.04/Xvfb 构建、平台 smoke、打包与生成接口检查均成功，包括本批工具启停/排序、复合命令与贴图配置事务回归。代码集中推送一次；此验证记录为文档更新，不另触发构建。尚未发布新包。

### 2026-11-18：E0 共享画布与媒体可行性（画布已验证，媒体端口未接，尚未发布）

本批从 `a8e8ab5` 继续，补齐跨平台编辑器的底层消费者；不因此关闭 E1 生产视频编辑器，也不关闭 B2 完整截图属性/选区 UI。

- MoonBit `shared/ui/frame` 校验整个绘图与语义快照，提供不可变、不复用的有界句柄；非法命令、重复语义 ID、非有限值、超限及不合法滑块数据使整帧失败，不让不同系统各自静默跳过。原生输入通过同一 MoonBit 编码器进入功能 UI。协议仅含通用图元、光标、语义、输入和媒体矩形，不含片段、截图工具或插件 ID 的业务分支。
- `bindings/c/ui_frame.h` 声明类型、单位和字符串所有权；`platform/shared/graphics/canvas.c` 统一遍历，平台只执行矩形、线段和文字原语。保持底图→视频表面→覆盖层次序；媒体资源不由画布拥有。原生按键、鼠标捕获、系统外观、tooltip 和无障碍接口负责翻译系统事实，命中、编辑命令和历史继续由 MoonBit 决定。此画布不是 IME 文本编辑器，也不是完整 GUI 框架。
- macOS 生产编辑器已经消费原始 MoonBit frame；AppKit 不再解析绘图命令，保留 AVPlayerLayer 嵌入和原有 AX 对象生命周期。校验失败保留上一帧，成功替换关闭旧句柄；调试字典只在需要时延迟生成。真实切分、拖开空隙、撤销、裁剪与媒体导出回归通过。
- Windows 的 GDI/输入/MSAA 与 Linux 的 Cairo/Pango/GTK/ATK 适配器放在 `platform/<os>/graphics`，独立 fixture 直接消费真实 v2 工程及其 UI；尚未替换 Windows 旧编辑器或将 Linux 录制完成接入生产编辑器。无障碍能力不能由“有 semantics JSON”推断，必须调用平台接口验证。新增源、头及共享 C 遍历进入构建归属清单；历史 include 例外没有增加。
- 有界 frame 验证暴露并修复了共享波形的极端开销：列间距按输出像素计算，重叠音频跳过随后不透明片段完全遮住的列，保留圆角边缘、全部片段语义和输入。部分重叠逐柱对照保持可见输出，最大合法 512 片段/256 重叠音频和极端宽矮窗口通过实际 producer→decoder 检查；不以扩到百万绘图命令掩盖不可见计算。

本地共享核心 native/Wasm 各 **219/219**、构建/归属/文件策略 **33/33**、macOS 完整原生回归、共享画布/实际媒体与导出专项、隔离身份的完整 App 构建均已通过。Windows 新适配器和 fixture 已严格交叉编译，Linux 使用 Ubuntu 22.04 真实 GTK/ATK/Pango 头严格检查通过。

本批最终源码 `38e45e4` 已通过 [Native desktop previews #44170592200](https://github.com/CoderSerio/moojicut/actions/runs/44170592200)：Windows 2022/MSVC 与 Ubuntu 22.04/Xvfb 构建、生产宿主 smoke、共享画布真实 v2 输入/绘制/无障碍回归、打包及生成接口检查均成功。目标运行期间修正 Windows MSAA 枚举器的 COM 身份/独立克隆，并修复 Linux 设置开关回调同步销毁自身控件的问题：界面刷新延至可取消的 idle，设置事务仍同步，关闭重开及 GObject critical 回归通过。测试也修正了切分前未定位播放头、将保留视口当作当前输出时长，以及检查不存在缩放按钮的错误假设；缩放仍只由快捷键/滚轮操作，继续验证完整文档快照和历史不变。

这次绿灯只关闭共享画布的目标平台自动验证，不关闭 E1 生产编辑器、通用 IME 输入、真实 Wayland/混合 DPI/设备及权限验收。未发布、安装或替换用户应用；发行包仍为 alpha.20。

E0 媒体探针使用隔离的官方 GStreamer/GES 1.28.9，在 macOS arm64 实际调用公共 C ABI，没有改变系统安装或生产依赖。八组真实 preview/seek→Matroska VP8/FLAC 导出→独立 FFmpeg 解码通过：黑屏/静音空隙、独立偏移音频、音频长于视频、1.5×/3×保音调、4500 ticks 源入点及重叠音频；另验真实取消到 NULL 及同进程再次导出。时间线来自共享编辑计划，不引入第二份可编辑文档。

**该次 E0 探针的 MP4 未通过**：H.264/AAC 虽可完成封装、视频帧数正确，末尾音频标记校验失败。完整探针与失败证据保留在本地 `.artifacts/e0-ges/E0-RESULTS.md`，该临时目录不随仓库/发布包交付。后续修复与当前验收范围见下节，不以新结果改写历史失败记录。

### 2026-11-18：E1 共享编辑会话与正式宿主（已接线，目标 CI 待验，未发布）

- `features/video_editor` 根包新增共享会话，统一持有 core/UI、预览请求、保存版本、导出/取消及关闭回执；原生工作线程只接收复制后的不可变媒体计划。异步播放错误以代次失效旧请求，不能冒充独立导出任务完成。备份文档恢复为 v2 也必须先保存到新位置；关闭期间不再启动新的预览构建。本地针对性 native 测试 14 项、完整 Wasm 236 项与 macOS 原生回归通过。
- `platform/shared/media` 新增共享 GStreamer/GES 执行器与 MP4 包装器，只消费计划，不拥有第二份可编辑文档。正式 fixture `test/native/gst-media.c` 在隔离的 macOS 官方 SDK 上通过真实预览、seek、空隙、独立音频、1.5×/3×保音调、裁剪、取消、原片不变及 MP4 首尾音频验证。无音轨与全静音计划不创建音轨、不依赖音频设备；音频长于视频时尾段黑屏继续出声，已由独立解码验证。该 fixture 修前 10 项失败，修后 143 项通过；AAC 修正限定本执行器已知编码配置，不能用于任意导入文件。
- 后台媒体执行由进程唯一 GES 线程及私有事件循环管理，多个编辑会话公平轮转；初始化、创建和释放不跨 GES owner 线程，也不泵 UI 默认循环。素材发现使用真实异步完成回调，关闭等到回调、管道和文件实际排空。双会话、空隙、取消、覆盖与原片别名拒绝已通过真实媒体回归。
- 音频波形使用独立 Gst-only 分析任务，按原始音频时间生成最多 16,384 个峰值，静音空隙、延迟、取消和源文件不变通过实际回归；片段偏移、缩放和变速后的展示仍由 MoonBit UI 计算。
- `platform/shared/app` 只执行 MoonBit 效果并回执；Windows/Linux 薄窗口复用同一宿主。草稿异步原子保存，坏新草稿不回退覆盖，旧 v1/v2 只在新草稿真正不存在时读取，源文件不改写；共享宿主 58 项真实回归及 Address/UndefinedBehavior 检查通过。窗口用 presentation serial 更新绘制描述，视频像素独立刷新。
- Windows 录制模块已删除旧表单、外部播放器预览和旧剪辑导出，改为 App 的完成回调打开共享编辑窗口；Linux 录制后也经 App 回调交接，并可恢复最近草稿。退出必须等保存与媒体完成，保存失败撤回退出并保留编辑状态。新增两端真实窗口 fixture 已登记，尚待目标系统执行。
- Windows 构建接固定官方 SDK、经过依赖闭包/许可证清单核验的最小运行库；最终包带 DLL、插件与 scanner，生产启动使用 EXE 相对路径和独立缓存。CI 同时验证被搬迁包、污染环境、无 SDK PATH 的加载，不以开发 SDK 可运行代替发行包验证。
- 新增媒体源文件已纳入构建归属清单；MoonBit 依赖检查与原生文件/include 检查均通过，仍只有原先 12 对历史例外。业务/UI 会话在 MoonBit，解码、编码、线程与原子文件发布在共享底层 C，不在 Windows/Linux 各复制一套剪辑逻辑。
- 两端窗口与录制交接已接线；macOS 仍用现有宿主会话。上节绿色 CI 不覆盖本批改动；发行包仍为 alpha.20。初始 Linux 媒体链使用 Ubuntu 22.04 的 GStreamer/GES 1.20 与 FFmpeg 58/58/56 ABI，下文目标运行已证明该旧依赖组合不能交付；正在改为随包提供固定私有媒体运行库。Ubuntu 24.04 的真实包运行仍单独验收，不根据 glibc 版本或改 SONAME 软链接推断兼容。

下一交付边界是本批正式录后编辑流程与运行库合批通过目标 CI。截图完整共享属性 UI、用户插件 v2、独立 CLI、OCR/翻译、录屏音源/暂停、Ubuntu 24.04 交付及旧原生职责迁移继续保留为未完成项；用户后续组织实机效果验收。

E1 首轮目标运行已经暴露实际差异，**目前仍未通过**：[429b14e 的 CI](https://github.com/CoderSerio/moojicut/actions/runs/44187534573) 中 Linux 严格编译成功，但 GES 1.20 下的 3× 视频时间映射、MP4 尾端音频共 6 项断言失败，取消释放另触发 GObject critical；Windows 暂停在官方 SDK 子组件精确版本校验，尚未进入本批媒体编译。后续运行收齐独立媒体 fixture 的结果，并保留取消栈与生成媒体作诊断；不关闭断言或放宽版本/资源校验来换取绿灯。

### Linux 私有媒体依赖（SDK 构建已验证，应用运行待验）

[7793422 的诊断运行](https://github.com/CoderSerio/moojicut/actions/runs/44188745337) 收齐了独立媒体检查：Ubuntu 22 下的 MP4 包复制、波形及共享宿主回归通过，取消/导出 worker 和媒体综合检查仍失败。调用栈确认 GES 1.20.3 在 NLE 释放 `GstEvent` 时错误调用 GObject 释放函数，对应[上游修复 ef9962d](https://github.com/GStreamer/gstreamer/commit/ef9962d66aadf5ca32aa684bd8eb146af4c5af27)。末尾 AAC 包完整存在、时间戳正确；旧 qtdemux 重复计算 edit-list 偏移而提前 EOS，对应[上游修复 3d3d2ed](https://github.com/GStreamer/gstreamer/commit/3d3d2ed447cb98e2eb61bda650d363d5adf03677)。同一产物在新解码器中尾音完整，不能通过破坏正确 MP4 格式来兼容旧解码器。另有 1.5×/3× 真实尾段冻结，已增加预览及导出末段条码断言；Mac 隔离 SDK 下媒体检查增至 148 项并全部通过。

当前实现将 Linux 的 GStreamer/GES 固定为 1.28.9，与固定的 FFmpeg、ORC 和 PipeWire 插件源码一起在私有前缀构建。源码、构建工具、配置及安装文件均校验；失败不发布可复用 SDK。Gst/FFmpeg/ORC 和所需编解码插件随包提供，系统 GLib/GTK、显示与音频服务仍共用桌面环境。X11 `ximagesrc`、Wayland `pipewiresrc` 与 PulseAudio 输出显式纳入清单，不能以重新扫描系统旧插件作为缺依赖兜底。

运行库按 ELF 依赖闭包收集并记录来源/许可证，以执行文件相对路径加载；应用启动重建自己的媒体环境，测试使用移动后的包和独立 registry。私有 SDK 成功后缓存复用，后续应用代码修改无需重建底层依赖。

[17ce9ea 的目标运行](https://github.com/CoderSerio/moojicut/actions/runs/44194483533) 已在 Ubuntu 22 成功构建并校验整套 SDK，Windows 官方 SDK 的真实 MSVC ABI 校验也已通过；两端共享核心测试继续通过。应用打包尚未通过：Linux 在收集最小运行库时错误地拒绝了未使用的 SDK 库，Windows 遗漏了 SDK 程序所需的 Microsoft VC 运行库。下一批修正这两项来源与闭包接线，保留对实际依赖的 ABI、来源、许可证检查。

Ubuntu 24 增加独立的同包验证任务：下载 Ubuntu 22 生成的发行包和单独保存的测试二进制，绑定提交与包哈希，不重新编译、不安装媒体 SDK；重新运行实际媒体、共享宿主、编辑窗口及应用 smoke。测试程序不进入用户下载包。此任务尚未运行成功，不能因此宣称 Ubuntu 24 已支持；真实 Wayland、DPI 和设备体验仍由实机验收补充。

### 三端编辑会话收口与依赖修正（本地验证完成，新目标 CI 待验）

- macOS 编辑器现消费同一 MoonBit 根会话及不可变媒体计划，保存版本、预览请求、导出/取消与关闭不再由另一套原生状态机决定。AVFoundation、AVPlayerLayer 和共享画布继续作为执行端；恢复草稿探测不创建长期会话或提前保存。保存对话框改为异步完成，不在效果处理过程中进入嵌套模态循环。
- 关闭等待实际媒体、seek、导出和波形任务排空；终态回执在资源回调退出后提交。应用退出等待编辑器完成，草稿保存失败则撤回退出，恢复操作入口。保留 macOS 录制器直接创建编辑器这一历史耦合，未将其计作 app 编排迁移完成。
- 新接入揭示并修复共享错误状态问题：保存失败提示独立于媒体/操作错误，只有当前文档版本真正保存成功才清除；过期保存回执、预览倍率成功、取消导出或开始新手势均不能隐藏它。相同文字的媒体失败也不能被保存成功误清。原实现失败、新实现通过的回归已验证。
- 本地 MoonBit native/Wasm 各 **238/238**、构建脚本测试 **102/102**、模块与原生归属检查通过；macOS 完整原生回归通过，最后的共享错误状态修正另外重建核心并复验实际 recording-experience。真实 AppKit 退出检查包含 GCD 发起退出、编辑器关闭与保存失败恢复；媒体检查覆盖取消/排空和原片硬链接保护。Apple Translation 仍是 ABI fixture，不代表下载或验证真实模型。
- [a05f427 的 CI](https://github.com/CoderSerio/moojicut/actions/runs/44198481858) 中 Linux 私有 SDK、最小运行库和生产应用编译通过；实际 worker、MP4 包装、共享宿主 58 项回归通过，旧 GES 取消与变速/尾音问题已不再复现。仍失败的是两项 Matroska 导出及波形源生成：实际链协商出 32 位音频，但系统 FLAC 1.3.3 不支持该位深。现固定并私有构建 FLAC 1.5.0、随包提供 libFLAC.so.14，构建阶段运行真实 32 位编码探针；未降低位深或削弱断言。隔离环境的真实媒体 148 项、波形 29 项通过，新 Linux SDK 和最终包仍需目标 CI 确认。
- 同轮 Windows 已找到真实 VC 运行库，失败于 PowerShell 5 子进程继承了 PowerShell 7 模块路径，导致签名校验命令不能加载。修正为子进程自身的系统模块目录和明确导入安全模块，继续要求有效 Microsoft 签名、版本、架构和原文件哈希，不跳过校验。
- 后续目标检查会分别执行媒体、核心、应用、共享画布和编辑窗口，汇总全部错误后仍以失败退出；任何一项失败均不打发行包。这样可一轮收齐独立问题，不通过提前退出掩盖其他检查。仍未发布或安装新包。

[ab92d72 的目标运行](https://github.com/CoderSerio/moojicut/actions/runs/44202442020) 已验证 Linux 私有 FLAC 1.5.0、完整运行库闭包和五项实际媒体检查全部通过；生产 App smoke 与共享画布也通过。唯一失败是独立编辑窗口 fixture 的两处 `-Wmisleading-indentation` 编译错误，已修正，窗口运行及 Ubuntu 24 同包验证仍待后续 CI。Windows 的签名命令已返回有效结果，进一步修正实际 CRT 使用的微软兼容性发布者名称，以及官方 SDK 的 `z-1.dll`、`gstcheck-1.0-0.dll` 组件映射；精确发布者、组织、签名、版本和哈希校验保留，38 个实际非插件依赖均核对到许可证目录，33 项相关测试通过。上述局部通过不代表本轮整体 CI 已绿。

[95e2ad5 的目标运行](https://github.com/CoderSerio/moojicut/actions/runs/44203666177) 中 **Ubuntu 22 整个任务通过**，包括真实编辑窗口的选中、切分、拖出空隙、黑帧预览、撤销、保存失败拒关/重试、重新打开及最终发行包验证。Windows 的正式应用、共享画布和隔离运行库通过，剩余失败是共享媒体 C 的 MSVC 严格编译差异：`g_snprintf` 的长度参数在 Windows 是 32 位，TLS 初始化不能直接使用 DLL 导入的析构地址，且 `noreturn` 函数必须返回 void。修正使用标准 `snprintf`、本地析构转发和符合 GThread 签名的线程入口，保留所有警告；本地严格编译和实际媒体 148 项再次通过，Windows 媒体与窗口仍待 CI。Ubuntu 24 此轮被 Windows 失败连带跳过；流水线已改成只依据 Linux 已验证包和 fixture 上传后的提交输出启动同包检查，不会把缺失包或上传失败视作成功，也不改变整个构建的失败结论。

[8669931 的目标运行](https://github.com/CoderSerio/moojicut/actions/runs/44205075228) 中 Ubuntu 22 再次全部通过；Windows 的严格媒体编译、实际预览/变速/空隙、底层 MP4 编码封装及波形检查通过。共享宿主 fixture 的 `WAIT_FAILED` 与 Windows 系统宏冲突，已统一添加 `HOST_WAIT_` 前缀。worker 导出收尾和编辑器首次保存异常退出，执行位置与已发现的跨 CRT 文件描述符使用吻合：[GLib 明确要求此描述符只能交给同一 C 运行库](https://docs.gtk.org/glib/func.open.html)。现由 `platform/shared/storage/file_sync.h` 统一同步既有文件，Windows 使用完整 Win32 句柄生命周期，GLib 临时描述符由 `g_close` 释放；错误不再读取另一运行库的 errno。原片保护、etag 与原子发布策略保留，本地严格 worker 46 项和宿主 58 项回归通过，Windows 崩溃关闭仍需新 CI 证实。Ubuntu 24 已能独立启动，但本轮停在从 Ubuntu 镜像下载 61.2 MB 的字体包，尚未进入应用验证；因新修复待统一验证而取消旧运行，该系统仍未验收。

[442b3d4 的目标运行](https://github.com/CoderSerio/moojicut/actions/runs/44207105092) 中 Ubuntu 22 全部通过；Windows 五项实际媒体/共享宿主检查、核心、App 和共享画布全部通过，已证实修复导出收尾与首次草稿保存的跨 CRT 崩溃。Windows 唯一剩余失败是编辑窗口 fixture 超时：预期的保存错误使用 TaskDialog，旧 fixture 通过 `GetDlgItem(IDRETRY)` 判断按钮而未能可靠关闭它。现按线程、窗口类、标题和实际编辑器 owner 链识别，再发送官方 `TDM_CLICK_BUTTON`；意外错误仍判失败，最终导出选择器有独立关闭断言，不被此辅助函数关闭。该修正仍待真实 Windows CI，不能据此提前宣布窗口通过。新增阶段日志与超时 stdout/stderr 保留，原有断言和 240 秒上限不变；构建脚本测试 **103/103** 通过。

Ubuntu 24 两次均在 EC2 Ubuntu 镜像下载 `fonts-noto-cjk` 时停滞，第二次超过 7 分钟，取消前未进入应用验证。CI 现仅将该官方镜像地址改为 Ubuntu 主归档的 HTTPS 地址，保留全部依赖、中文字体和包签名校验；增加有限网络超时/重试和安装步骤上限。测试仍使用 Ubuntu 22 的同一个包和 fixture，不安装 SDK 或重新编译。本轮没有发布或安装新包。

### 下一切片：B2a 共享文字标注与属性输入（尚未实现）

交叉源码评审确认：现有 typed frame 只有静态文本和按钮/滑块等语义，通用输入编码器没有组合输入、文本替换区间或编辑字段身份；三套 `style_controls` 仍包含具体属性逻辑。不能在画布上画出输入框就宣称共享输入完成。

- 以已有文字标注贯通颜色、透明度、字号、多行文本、提交/取消、撤销及图像导出。可先用透明度数字框验证原生桥，但交付边界仍是完整文字切片；之后再扩展其余形状工具、OCR 结果和用户插件。
- `shared/ui` 持有通用字段描述、原始草稿和编辑事件；统一 UTF-16 索引、字段稳定 ID、编辑 token 与草稿版本。选中对象变化、贡献退休和迟到 IME 回调不能修改另一个字段，常规 frame 刷新不能覆盖正在组词的内容。
- `capture/ui` 负责布局、绘制和焦点交互；`capture` 根会话负责草稿与文档事务；`capture/core` 继续校验持久值。`annotations` 声明属性，不再靠原生工具枚举生成控件；通用插件运行时不能为此导入 capture。
- 原生只提供文本系统桥：macOS 可复用现有 `NSTextView` 的 IME、选区、剪贴板和候选窗接线，但空白处理、字数限制、数字校验和提交策略必须移到共享层。Windows/Linux 按同一事件契约提供系统输入，不能分别复制字段业务。编辑时的真实无障碍输入对象替换对应虚拟节点，避免重复暴露。
- 验收包括无效数字草稿不入文档、中文组合与 emoji 区间替换、字段退休后迟到输入、取消无文档撤销记录、提交只产生一次历史、AX 设置值，以及多个截图窗口启停预检/存储失败时的原子性。真实系统候选窗与输入法效果仍单列人工验收。

此切片不关闭完整 B2、插件 v2、OCR/翻译或 CLI；这些继续使用前表的独立完成条件。
