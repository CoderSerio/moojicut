# Recording core

此包只拥有录制状态转换、状态能力查询和编码参数策略，不依赖视频编辑工程、草稿或 UI。
`src/api_video.mbt` 暂时保留现有四个录屏 C ABI 名称并转发到本包；原生宿主无需更改符号或内存所有权。

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
