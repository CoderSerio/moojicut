# 用户截图插件 v2

用户插件是预编译的 Wasm ZIP。同一个 ZIP 可以导入 macOS、Windows 和 Linux。应用安装插件时会校验包和运行一次健康检查，插件作者在打包前完成编译。

首版 v1 ZIP 需按 v2 契约重新构建。在升级后的「设置 → 插件管理」里导入新包。

## 从示例开始

`plugins/examples/numbered-box` 声明了两个工具。一个在框选区域上添加标注，另一个返回当前截图的尺寸。作者可以修改清单与 MoonBit 源码，在仓库根目录运行：

```sh
python3 scripts/package_plugin.py plugins/examples/numbered-box --output dist/numbered-box.zip
```

脚本使用 MoonBit Wasm 后端。包内含 `manifest.json`、`plugin.wasm` 与可选的 `assets/icon.png`；Windows 和 Linux 当前显示默认插件图标。实现的固定导出为 `mooji_run() -> i32`，可以沿用示例的 `gmlewis/moonbit-pdk@0.47.35` 处理输入输出，无需项目私有 SDK。

## 调用与权限

插件从截图工具栏由用户点击或拖框触发。宿主传入截图尺寸、格式、文档版本和工具的框选坐标。插件可返回文本或声明支持的标注。应用校验结果后，将一批标注作为一次可撤销操作提交。字段、尺寸限制和返回格式见[截图插件 v2 契约](../spec/capture-v2.md)。

安装时的健康检查只核对协议和声明的工具。重启时复核包的内容摘要与清单，再恢复工具布局。每次调用使用应用随包提供的独立 worker 与固定版本的 Extism。当前不提供截图像素、文件访问、网络、自动写剪贴板或自定义 UI。文本结果可由用户手动复制。

旧的 `capture-info` ZIP 保留给底层 worker 的传输回归。可导入应用的示例是上面的 `numbered-box`。
