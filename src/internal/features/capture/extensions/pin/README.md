# Shared pin policy

The numeric ABI in `bindings/c/pin_policy.h` is used by the macOS, Windows and
Linux pin hosts. No window handles, event objects, image buffers or JSON cross
this boundary. Hosts retain monitor lookup, Retina/native unit conversion,
rounding/placement of native window rectangles, focus and input registration.

| Existing behavior | macOS (1) | Windows (2) | Linux (3) |
| --- | --- | --- | --- |
| Interactive fit | 95% work area | 100% work area | 100% work area |
| Scale range | 0.1–8, lowered when required to fit | Same | Same |
| Unanchored initial fit | 75%, at most original size | Original size | Interactive fit at scale 1 |
| Opacity domain / step | 0.1–1 / 0.1 | 26–255 / 26 | 0.1–1 / 0.1 |
| Recovery key required for visibility toggle | Hiding only | Hiding and restoring | Existing native global registration gate; local action unchanged |
| Explicit restore of hidden pass-through pins | Skip | Skip | Restore (legacy behavior) |

Visibility decisions prioritize a selected pin, otherwise restore a hidden group
before hiding all. Focus/selection effects deliberately remain with their native
window events: Windows clears selection for either toggle direction, Linux only
when hiding, and macOS can focus a restored selected pin.

Invalid geometry or nonfinite sizing produces zero, telling the host to keep its
current window geometry. Nonfinite opacity recovers to the visible default. These
checks keep invalid scalars away from window APIs; regular limits and platform
semantics are preserved.

Core regressions cover differing caps, tiny work areas, byte and unit alpha,
nonfinite input, selected-target priority, unavailable recovery keys and the
legacy pass-through differences. `test/native/pinned-image.m` exercises all
platform profiles through the actual scalar ABI and macOS's real pin controller;
Windows/Linux native smoke tests exercise their adapters on CI.

## 贴图交互边界

`interaction.mbt` 统一三端滚轮缩放、边缘命中和等比例拖拽缩放规则：

- 滚轮以一格为一个单位，保留触控板和高精度滚轮的小数增量。
- 边缘使用左、右、上、下位掩码，内部区域仍用于移动窗口。
- 拖拽始终使用手势开始时的窗口和比例，固定对边或对角，保持整张图片的长宽比，并受现有缩放范围及屏幕工作区约束。它不会裁剪或改写原图。
- 共享坐标从左上开始。AppKit 在边界转换 Y 轴；Windows 和 GTK 转换自己的事件、DPI 和窗口坐标。返回的几何数组由宿主释放。

GTK 的窗口位置请求仍受窗口管理器约束，可能被忽略；X11 与 Wayland 的实际锚定效果需要分别验收，不能由共享几何测试代替。

原生适配层负责窗口、焦点、鼠标捕获、光标和剪贴板，不重复缩放算法。macOS 的 `Cmd+C`、Windows/Linux 的 `Ctrl+C` 仅在本地选中且可交互的贴图中生效，不注册全局复制快捷键；隐藏、穿透或截图期间不能复制旧选择。复制始终使用保留的原始像素，与显示缩放、透明度和选中边框无关。

`interaction_wbtest.mbt` 验证小数滚轮、边缘命中、对边锚定、比例与上下限。AppKit 的 `test/native/pinned-image.m` 使用隐藏窗口与私有剪贴板验证实际事件路径；Windows/GTK 的贴图 smoke 覆盖各自事件、取消和资源释放，系统剪贴板检查只在隔离 CI 桌面执行。
