# 截图插件 v2

此协议正接入应用。仓库中的 `numbered-box` 是可编译的示例，用一个包声明拖框标注和查看尺寸两个工具。

## 包和清单

作者实现 `mooji_run() -> i32`，编译为 Wasm 后将 `manifest.json`、`plugin.wasm` 及可选的 `assets/icon.png` 放进 ZIP。打包脚本为 `scripts/package_plugin.py`。同一个 ZIP 用于三端。

清单需要 `apiVersion: 2`、`pluginId`、`name`、`version`、`entry: "plugin.wasm"`、`runtime: "extism-1"` 和 `tools`。采用小写反向域名作为插件 ID，采用三段数字版本。每个包可声明 1–16 个工具。工具需要 `toolId`、`title`、`gesture`、`effect`，其中工具 ID 在包内唯一。

| 字段 | 允许值 |
| --- | --- |
| `gesture` | `invoke` 点击调用，`dragRect` 框选后调用 |
| `effect` | `result.text` 显示文本，`capture.annotations.add` 添加标注 |

添加标注的工具需要 `dragRect`。安装授权按该包内容的版本和贡献生效。

## 安装检查和调用

安装检查的输入是 `{"apiVersion":2,"operation":"health"}`。插件返回同样的版本和操作，以及与清单一致的 `toolIds` 数组。安装检查没有截图会话或效果权限。

调用输入中的 `operation` 为 `invoke`。输入附带版本、`invocationId`、包内 `toolId`、`capture` 和 `selection`。截图信息包含 `width`、`height`、`format` 和 `revision`。点击工具的 `selection` 为 `null`，框选工具收到相对当前截图裁剪区域的 `x`、`y`、`width`、`height`，单位为像素。

输出重复 `apiVersion` 和 `invocationId`，只能返回当前工具声明的效果。

- `kind: "text"` 附带 `title` 和 `text`，文本上限为 32 KiB UTF-8。
- `kind: "annotations"` 附带 1–16 个 `annotations`。每个标注需要 `type`、`x`、`y`、`width`、`height` 和 `color`。矩形的类型为 `rect`，附带 1–24 的 `stroke`。文字的类型为 `text`，附带 8–96 的 `fontSize` 和最多 80 个 UTF-16 单元的 `text`。坐标与框选使用同一单位和原点，颜色使用 `#rrggbb`。标注 ID 由应用分配，整批作为一条撤销记录。

此版本的请求和结果对象都有固定字段。应用会复核会话、文档版本、插件版本和调用授权，完成的调用只能提交一次。
