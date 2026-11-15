# Capture Info：最小 MoonBit 插件

这个独立示例只依赖现成的 `gmlewis/moonbit-pdk@0.47.35`，没有项目私有 SDK
或 `moon.work` 路径依赖。一包提供“截图信息”和“查看尺寸”两个工具。

在仓库根目录运行：

```sh
python3 scripts/package_plugin.py plugins/examples/capture-info --output dist/capture-info.zip
```

脚本使用 `MOON_HOME` 指定的工具链，其次尝试仓库 `.tools/moon`、PATH 中的
`moon`。已验证工具链为 `moon 0.1.20261104`。首次执行会刷新依赖元数据，并由
构建自动下载固定版本的 PDK；已有依赖缓存时可加 `--offline`。

已验证示例构建、打包及 macOS App 的导入和执行。使用流程是在
Mooji Cut 的“设置 → 插件管理”中导入 ZIP，打开一张截图，再点击新增的“截图信息”
或“查看尺寸”。两者都只接收**当前截图**的宽、高、PNG 格式和修订号，返回纯文本，
由 App 原生结果窗口显示；只有用户点击窗口的复制按钮才写入剪贴板。

制作自己的插件时，主要修改：

1. `plugin/main.mbt` 的 `describe` 函数：按局部 `toolId` 返回标题和文本。
2. `manifest.json`：填写自己的反域名 `pluginId`、名称、版本和工具声明。
3. `moon.mod`：换成自己的 MoonBit 模块名和版本。

可选图标放在 `assets/icon.png`，不需要增加 manifest 字段。脚本会将它加入 ZIP；
文件须为普通 PNG，最大 256 KiB、宽高各 1–512 像素。本示例没有自带图标，使用默认图标。

`plugin/moon.pkg` 中的 `mooji_run` 导出名称与 `memory` 导出保持不变。
`mooji_run` 的 ABI 是 `() -> i32`：成功返回 `0`，失败使用 PDK 的 `set_error`
并返回非零。Manifest 的 `action:"run"` 是工具动作类型，不是 Wasm 导出名。

打包脚本检查构建产物、Wasm v1 头、32 位未共享线性内存、必要导出和 ZIP 的
名称、大小、CRC。它不会复制 App 的整套 manifest 业务规则，也不会代替真实
运行测试；App 导入时的 MoonBit 协议校验和 Wasm probe 才是最终检查。

协议完整约束见仓库 `src/internal/plugin_protocol/README.md`。不能声明网络、
文件、图像像素、自动写剪贴板或自定义界面能力。
