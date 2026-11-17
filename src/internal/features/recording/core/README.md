# Recording core

此包只拥有录制状态转换、静态后端能力、请求校验和编码参数策略，不依赖视频编辑工程、草稿或 UI。
`src/api_video.mbt` 保留现有四个录屏 C ABI 名称并转发到本包；原生宿主无需更改符号或内存所有权。

- macOS：最长边不超过 3840、30 fps、3 秒倒计时，可选系统声音，不录麦克风。
- Windows：不超过 1920×1080、15 fps、无倒计时、无音频。
- Linux 不在录屏计划的支持平台内。状态机包含的 pause/resume 事件不表示宿主已经提供暂停界面或采集实现。

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
`permission: "unknown"` 和 `requiresHostValidation: true`。Linux 两种环境返回
`supported: false`、`availability: "unsupported"`、空来源与 null 限制。
查询不触发权限、读取设备或分配媒体资源。

来源按实际执行区分：macOS 的 `display`、固定桌面 `region` 和跟随的 `window`；
Windows 仅 `primary-display`。系统音频、麦克风、暂停分别声明，不能用状态机
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
仅保留原调用约定：Windows 旧接口将 systemAudio=true 降为 false；新严格接口
拒绝不支持的音源，不静默删除意图。现有 Mac/Windows 生产消费者继续使用旧接口。
新的发现/严格请求入口供后续统一宿主接入，当前并未新增 UI/CLI 路由。

真实权限、依赖/设备就绪、来源身份/存活、坐标转换、generation、忙碌和资源释放
仍需平台探测并在执行前复查。B1 本切片没有冻结跨平台来源句柄、时基或清理回执
协议，也没有完成统一录制资源会话；这些必须随实际取帧/取消/断开验证推进。
