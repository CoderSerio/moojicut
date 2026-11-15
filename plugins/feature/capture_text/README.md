# 截图文字识别与翻译（macOS）

此模块接收编辑器当前选区的最终 PNG，不自行截屏或读取剪贴板。

- Vision 在后台串行识别截图，结果可编辑、复制。默认优先简体中文、英文，同时开启系统语言检测；其他语言以当前 Vision 支持范围为准。
- Apple Translation 在本机翻译编辑后的原文。默认目标为简体中文，英文可直接切换，其余语言来自系统支持列表。源语言默认自动检测，也可以手动选择。
- 首次翻译缺少语言资源时，由系统弹出下载授权。取消下载、语言不支持、无文字、服务失败都会显示状态，不伪造成功结果。
- 每个编辑器同时保留一个结果窗口。关闭编辑器、截图 revision 变化、重新发起任务或取消任务都会使旧回调失效。修改原文或语言会清除旧译文，避免复制过期结果。
- 原文和译文仅在结果窗口存活期间保留；没有持久化、外部 API 或自动写入剪贴板。

## 接线

宿主持有一个 `MCTextToolsController`，从编辑器的 `onOCR` / `onTranslate` 调用：

```objc
// Export through the host's capturePNGData path first (including pending edits).
// These values come from that successful export and its content snapshot.
NSData *png = currentSelectionPNG;
id snapshot = editor.captureContentSnapshot;
NSString *owner = editor.pluginContextIdentifier;
__weak MCImageEditorController *weakEditor = editor;
[self.textTools openPNGData:png owner:owner parentWindow:editor.window
    isCurrent:^BOOL {
        MCImageEditorController *current = weakEditor;
        return current && [current.pluginContextIdentifier isEqual:owner]
            && [current.captureContentSnapshot isEqual:snapshot];
    } translate:NO]; // onTranslate uses YES (OCR first, then translation).
```

将 `MCCaptureController` 的两个 block 透传给其普通编辑器和所有 overlay 编辑器，与现有 `onUserTool` 方式相同。

在 `onPluginContextClosed` 中同时调用 `[self.textTools cancelForOwner:identifier]`；保留原有用户插件清理。宿主退出时调用 `cancelAll`。结果窗口自身也监听 parent 的关闭通知、在主 run loop 检查 lease，并在每次异步回调与复制前验证 lease。

`MCTextToolsController` 不引用 `MCImageEditorController`，其输入契约可以在其他原生宿主实现。`isCurrent` 应比较完整的轻量内容快照；单比较 document revision 会漏掉尚未提交的文字和属性修改。图像导出及 revision 仍复用已有 MoonBit 文档内核；Vision、Translation 和原生结果 UI 属于系统适配层。

## 边界

- 只接受 PNG；编码数据最多 32 MiB、最长边 8192 像素、像素总数最多 32 Mi。过大图片提示缩小选区，不静默缩图导致小字丢失。
- OCR 输出与翻译输入最多 128 KiB UTF-8。
- 所有 controller API 都在主线程调用，Vision 实际识别在串行后台队列中执行。
- Translation 需要 macOS 26；SwiftUI 的 `.translationTask` 绑定结果窗口生命周期，桥接 view 必须附着在显示中的窗口中，以承载系统语言识别和下载提示。
- 未安装语言时，仅有 `TranslationSession(installedSource:target:)` 的命令行测试无法下载语言；真实 UI 下载流程需要在隔离 bundle ID 的验证 App 中人工确认。未完成该步骤时不可声称真实翻译或下载界面已验收。

## API 依据

- [Vision text recognition](https://developer.apple.com/documentation/vision/vnrecognizetextrequest)
- [TranslationSession](https://developer.apple.com/documentation/translation/translationsession)
- [SwiftUI translationTask](https://developer.apple.com/documentation/swiftui/view/translationtask(_:action:))
- [语言下载能力](https://developer.apple.com/documentation/translation/translationsession/canrequestdownloads)

开发与验证须遵循主仓库 `.artifacts/moojicut-local-runtime-policy.txt`，不可覆盖、启动或登记生产 bundle ID 的测试副本。

## 验证

`python3 scripts/native.py test-text` 只编译命令行程序，验证真实 Vision 识别、边界与取消，以及隐藏窗口的结果状态回归；不生成或注册 App。窗口状态测试使用受控的服务回调，不代表系统翻译成功。

加 `--translation` 可尝试真实的、只使用已安装语言的系统翻译。缺少资源会明确输出 `notInstalled / SKIP`，不会自动下载。

系统 UI 端到端验收步骤（由集成者在独立 bundle ID、独立 profile 的验证 App 中执行）：

1. 框选带有英文或中英混合文字的图片，点文字识别，核对原文并修改一个词，点「复制原文」核对修改内容。
2. 选择源语言 English、目标简体中文，点翻译；缺少模型时在 Apple 系统弹窗中允许下载。等待非空译文，确认它对应修改后的原文，然后复制核对。
3. 将目标改为英文；旧译文应立即清空。改原文、取消正在运行的任务，确认迟到结果不会填回。
4. 翻译中关闭编辑器，或更改截图内容（包括未提交文字/属性），结果窗口应关闭，旧回调不得重开窗口。
5. 用无文字图片和较大选区验证可读错误；原图、原文、译文均不发送外部 API。

下载提示、真实译文和截图工具栏接线需单独记录实际验收结果；CLI 的 `SKIP` 不能替代这些步骤。验证完成后定向注销并归档测试 App，保留唯一用户安装。
