# macOS 原生宿主

当前入口是 AppKit 菜单栏与偏好设置，直接链接 MoonBit native 核心。截图、录屏采集和完整编辑器仍在迁移范围内；此构建不代表这些功能已经迁移完成。

需要 macOS、Xcode Command Line Tools、Node.js 22+（仅构建脚本）及 MoonBit 工具链。工具链按 `.tools/moon`、`MOON_HOME`、`PATH` 的顺序查找。当前嵌入回归已验证 `moonc 0.10.20`；MoonBit 原生 ABI 应随工具链一起验证。

从仓库根目录运行：

```sh
node scripts/check-native-core.mjs
node scripts/build-native-app.mjs
node scripts/build-native-app.mjs --run --preferences
```

产物是 `dist/native-app/Mooncap Native.app`，编译缓存位于 `.artifacts/native-app/`。应用只包含 AppKit/Objective-C 宿主与 MoonBit 静态核心，不打包 Node、Electron 或 WebView。默认启动只显示菜单栏图标；`--preferences` 打开偏好设置。Node 在启动应用后退出。

可单独启动或运行界面 smoke：

```sh
open -n 'dist/native-app/Mooncap Native.app'
mkdir -p .artifacts/native-app/smoke
MOONCAP_NATIVE_OUTPUT="$PWD/.artifacts/native-app/smoke" \
  'dist/native-app/Mooncap Native.app/Contents/MacOS/MooncapNative' --smoke
```

Smoke 检查菜单栏启动、偏好设置、外观切换、关闭释放和 MoonBit 调用，输出报告及界面预览，不采集用户屏幕或麦克风。开发包使用本机 ad-hoc 签名，未做 Developer ID 签名或公证；只构建当前机器架构，不宣称兼容所有 macOS 版本。
