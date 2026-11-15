# macOS 滚动截图

状态：alpha.14 起暂时关闭发布版工具栏入口，保留原型与测试，待真实页面问题修复后再接回。

`MCScrollCaptureController` 从已选定的屏幕区域持续采集真实屏幕画面。用户在原应用中
手动向下滚动，点击「完成」后获得 PNG 并进入图片编辑器；采集本身不写剪贴板，也不
模拟滚轮或申请辅助功能权限。需要既有的屏幕录制授权。

## 接入

1. 在主线程保存编辑器的 `captureScreenFrame`（AppKit 全局坐标）。选区须完整位于
   一个显示器内。先关闭所有冻结截图浮层并恢复原应用焦点。
2. 创建 `initWithScreenRect:includedWindowNumbers:`。窗口编号回调返回当前可见贴图
   的窗口号；ScreenCaptureKit 排除本应用其余窗口，并把这些贴图作为例外保留。
3. 设置 `onCompletion`，持有 controller 后调用 `start`。成功时把 PNG 交给现有
   图片编辑器；`NSUserCancelledError` 表示用户取消，不应弹错误窗口。
4. `busy` 在采集、暂停和最后编码期间均为真，可接入退出与更新的 busy 门禁。
   退出/取消调用 `cancel`；显示器布局变化会自动取消，迟到回调不会提交结果。

独立 HUD 不激活本应用，不抢走原网页/窗口焦点。其宽度按按钮内容计算，高度 60pt，
优先放在选区之外或邻屏。只有确实没有空间时才要求缩小选区。暂停时完整原因保存在
状态文字和 tooltip 中；「完成已捕获部分」只保留上次成功拼接的内容。

`initWithFrameProvider:` 是异步数据源接缝，用于隔离回归或其他截图提供方；这个
构造器不创建窗口、不访问屏幕。公开状态和回调均在主线程，像素匹配/编码在串行后台
队列。普通情况下每 350ms 请求一帧，同一轮只存在一个待完成的请求，5 秒无响应会报错。
ScreenCaptureKit 的一次性截图没有取消 API：取消会废弃其结果，不会声称系统请求已经
物理终止；过期回调均按会话编号丢弃。

## 拼接与边界

- 比较实际像素寻找向下滚动的重叠，固定页头保留一次、页尾替换为最后一帧。
- 采样位置在格内错开，避免文字行距与采样步长重合而误判；候选须通过密集复核和
  唯一性/纹理检查。无法可靠判断时暂停，不能把未对齐的帧直接接到长图后面。
- 重复帧不会增长图片；回滚、横移、无重叠、变化的固定栏会明确暂停。
  动画、懒加载、视频、重复条纹或大片无内容区域可能无法对齐。暂停后可重试对齐，
  或明确保留已经捕获的部分。
- 捕获区域至少 64×96 像素；单帧最多 400 万像素、每边最多 4096 像素、编码输入
  最多 16MiB。结果最多 1200 万像素或 24,000 像素高，先达到的上限生效。
  这些是图像缓冲区边界，不等同于整个进程的 RSS 硬上限。
- 仅支持向下滚动；不支持自动滚轮、跨屏选区或任意二维拼接。

## 验证

```sh
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Werror -I . \
  test/native/scroll-capture.m \
  plugins/feature/scroll_capture/macos/MCScrollStitcher.m \
  plugins/feature/scroll_capture/macos/MCScrollCaptureController.m \
  -framework AppKit -framework ScreenCaptureKit -framework ImageIO \
  -o .artifacts/scroll-capture/fixture
.artifacts/scroll-capture/fixture
```

fixture 使用独立渲染的文档、原生文字栅格和可控异步提供方，覆盖精确输出像素、固定
栏、重复帧、方向/间隙拒绝、资源边界、末帧、取消与迟到结果、超时和 HUD 放置。
它不启动 App、不申请权限，不代表真实浏览器滚动的视觉和采集时序已经验收。
