# Recording core

此包只拥有录制状态转换、静态后端能力、请求校验和编码参数策略，不依赖视频编辑工程、草稿或 UI。
`src/api_video.mbt` 保留现有四个录屏 C ABI 名称并转发到本包；原生宿主无需更改符号或内存所有权。

- macOS：最长边不超过 3840、30 fps、3 秒倒计时，可选系统声音，不录麦克风。
- Windows：不超过 1920×1080、15 fps、3 秒倒计时、无音频，支持固定桌面区域。
- Linux X11/Wayland：不超过 1920×1080、15 fps、3 秒倒计时、无音频，GStreamer VP8/WebM。
- 状态校验接口包含的 pause/resume 事件不表示宿主已经提供暂停界面或采集实现。

录制宿主仍负责权限、选区、时钟、媒体资源、文件以及异步回调身份检查。
`canStop` 表示宿主可执行结束/取消动作：`requesting` 和 `countdown` 转发 `cancel`，
`starting`、`recording` 和 `paused` 转发 `stop`。`stopping` 保持 `captureInProgress`，
直到媒体完成或失败；不得在编码收尾前开始下一次录制。状态机本身无会话状态，
不替代宿主的 generation/资源身份校验，无法仅凭事件字符串识别来自旧会话的回调。

生产依赖仅为通用协议校验与 MoonBit 标准库；`test_support` 仅用于测试。
参数和返回结构保持原有宿主约定，包括严格 JSON 布尔值与无效原生参数的全零结果。

## B1 最小能力与计划接口

`recording_capabilities(platform)` 接受 `macOS`、`windows`、`linux-x11` 或
`linux-wayland`，返回带 `ok` 的 JSON。`supported` 仅表示当前源码有该后端，
不是本机可立即录制；支持的后端仍返回 `availability: "unverified"`、
`permission: "unknown"` 和 `requiresHostValidation: true`。Linux 需要实际运行时
组件与显示服务；已编译进源码不等于用户机器安装了 GStreamer 插件或 ScreenCast portal。
查询不触发权限、读取设备或分配媒体资源。

来源按实际执行区分：macOS 的 `display`、固定桌面 `region` 和跟随的 `window`；
Windows 支持 `primary-display/display/region` 固定像素区域；Linux X11 支持
`display/region`，Wayland 使用 `system-picker`，不能传桌面全局窗口 ID 替代系统选源。
系统音频、麦克风、暂停分别声明，不能用状态机
含 `paused` 或平台名称推断支持。`limits` 记录输入像素范围、输出偶数对齐、
尺寸上限、固定帧率和倒计时；音源支持不代表当前获得系统授权。

`recording_request_plan(request)` 是严格的参数规划入口，例如：

```json
{"platform":"macOS","source":"region","width":5120,"height":2880,"systemAudio":true,"microphone":false,"pause":false}
```

`platform/source/width/height/systemAudio` 必填，`microphone/pause` 默认为 false。
宽高必须是来源的物理像素整数，不能直接传逻辑点；此入口不接收窗口 ID、全局坐标
或未验证的设备句柄。未知字段也拒绝，不能传 `permission: "granted"` 伪装授权。
错误码区分 `unsupported_backend/source/audio/pause` 和格式错误 `invalid_input`。
成功仍带未知权限与待验证标志；这是编码计划，不是已经启动或授权的会话。

旧 `recording_plan` 和六值 `native_recording_plan` 实际共用同一后端限制与编码策略。
标量接口将 Windows/Linux 的 systemAudio=true 降为 false；新严格接口
拒绝不支持的音源，不静默删除意图。Mac/Windows/Linux 原生编码使用同一参数策略。
发现/严格请求入口仍未作为独立 CLI 协议发布。

真实权限、依赖/设备就绪、来源身份/存活、坐标转换、generation、忙碌和资源释放
仍需平台探测并在执行前复查。来源句柄、像素缩放、设备和实际媒体时间仍由各适配层
持有；此包不将 portal 节点、窗口 ID 与全局矩形混为通用对象。

## 实际会话与共享 UI

`flow.mbt` 的 `recording_flow_open/event/value/close` 已供 Windows/Linux 生产入口使用。
句柄不复用；一次事件只发一个系统执行效果。倒计时采用同一单调时钟的绝对截止点，
迟到 timer 不延长倒计时，也不重复启动。开始中的停止仍等待媒体完成，不能提前 close。
选源/倒计时取消进入 stopping，宿主释放来源后 COMPLETE 才到 cancelled；采集停止后的
COMPLETE 必须等 writer/EOS 与本地资源收尾后才报告 ready。FAIL 亦要求宿主先完成清理。
原片失败保留策略在平台媒体 I/O 中执行。

`../ui/panel.mbt` 统一倒计时、计时文本、面板与按钮几何、命中动作、小窗字号。
Windows 与 Linux 宿主只转换 DPI、绘制主题/图标及处理系统窗口；Linux 开始后隐藏
自有面板以免录入画面，通过托盘/启动参数停止。Windows 只有系统支持窗口排除时显示
录中控制条。macOS 仍使用既有准备界面和状态校验入口，尚未迁入这套 live flow/panel。

调用与所有权见 `native/shared/recording_flow.h`。只在主/core线程操作句柄；后台任务
携带身份并返回宿主队列，不能直接访问 MoonBit 可变会话。未来 CLI/插件应接同一会话，
Linux 当前 `--record/--stop` 只是 GUI 的启动控制参数，不等于完整 D2 CLI 已交付。
