# macOS 原生宿主

当前入口是 AppKit 菜单栏与偏好设置，直接链接 MoonBit native 核心。截图、录屏采集和完整编辑器仍在迁移范围内；此构建不代表这些功能已经迁移完成。

需要 macOS、Xcode Command Line Tools、Node.js 22+（仅构建脚本）及 MoonBit 工具链。工具链按 `.tools/moon`、`MOON_HOME`、`PATH` 的顺序查找。当前嵌入回归已验证 `moonc 0.10.20`；MoonBit 原生 ABI 应随工具链一起验证。

从仓库根目录运行：

```sh
node scripts/check-native-core.mjs
node scripts/check-native-shortcuts.mjs
node scripts/build-native-app.mjs
node scripts/build-native-app.mjs --run --preferences
```

产物是 `dist/native-app.noindex/Mooncap.app`，编译缓存位于 `.artifacts/native-app/`。开发产物放在 `.noindex` 目录，避免被系统应用搜索当成另一个安装版本。应用只包含 AppKit/Objective-C 宿主与 MoonBit 静态核心，不打包 Node、Electron 或 WebView。默认启动只显示菜单栏图标；`--preferences` 打开偏好设置。Node 在启动应用后退出。

应用采用 **「月窗」**标志，源文件位于 [assets/brand/lunar-frame](../assets/brand/lunar-frame/)。构建会将应用图标打包为 `Mooncap.icns`，并带入供菜单栏与关于页使用的资源。菜单栏使用专门适配小尺寸的单色模板图像，由 AppKit 处理浅色、深色外观；资产生成工具不包含在应用包中。

原生设置的「快捷键」页保存截图、开始录屏和停止录屏的配置，默认分别为 `⌘⇧1`、`⌘⇧2`、`⌘⇧X`。支持直接按键录入、清除、恢复默认和动作间冲突校验；配置使用原生设置域持久化，不修改旧 Electron 版设置。当前采集入口尚未迁移，快捷键只保存配置，尚未注册为可执行的全局动作。

可单独启动或运行界面 smoke：

```sh
open 'dist/native-app.noindex/Mooncap.app'
mkdir -p .artifacts/native-app/smoke
MOONCAP_NATIVE_OUTPUT="$PWD/.artifacts/native-app/smoke" \
  'dist/native-app.noindex/Mooncap.app/Contents/MacOS/MooncapNative' --smoke
```

Smoke 检查菜单栏启动、偏好设置、外观切换、重新打开、关闭释放和 MoonBit 调用，并输出 JSON 报告，不采集用户屏幕或麦克风。快捷键回归使用隔离的临时设置域，检查持久化、清除、恢复默认以及已启用系统组合的冲突，不注册或监听全局按键。开发包使用本机 ad-hoc 签名，未做 Developer ID 签名或公证；只构建当前机器架构，不宣称兼容所有 macOS 版本。
