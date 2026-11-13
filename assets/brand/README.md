# Mooncap · 月窗

采用「月窗 / Lunar Frame」：月牙代表 Moon，右上角取景边界表达截图。此方案于 2026-11-14 确认用于 Mooncap。

- `lunar-frame/logo.svg` 是独立矢量标志，路径不依赖字体或系统符号。
- `app-icon-1024.svg` 与 `layers/` 保留应用图标的可编辑源；同名 PNG 是导出图。
- `app-icon-rounded-preview.png` 用于 README、关于页和传统 macOS `.icns` 的打包来源；打包时增加透明安全边距。
- `menubar-16/18/24.svg` 是按小尺寸调整的单色版本；每种尺寸包含 1×、2× 透明 PNG。macOS 当前使用 18pt 模板图像，由系统着色以适配浅色、深色菜单栏。

修改图形时应同步相应 SVG 和 PNG 导出，避免文档与应用使用不同版本。只保留已选中的方案，不随应用打包设计对比图。
