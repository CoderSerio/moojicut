# 用户插件运行方式（首版）

Alpha 协议策略：当前格式仍为 v1，但不承诺向后兼容。下一批插件协议改造将直接替换旧格式，同时更新示例与打包脚本；旧包需重新构建，不实现 v1 兼容层。设计依据见[架构与实施规划](../../docs/architecture.md#决策记录)。

首版加载预编译的 WebAssembly 插件 ZIP。App 不包含 MoonBit 编译器，也不在用户
导入插件时下载依赖或编译源码。当前原生宿主实现面向 macOS。已经用隔离配置在
实际 App 中验证 ZIP 导入、工具开关与上移、重启恢复，以及从图片标注工具栏运行
示例并显示正确尺寸；这里使用本地合成 PNG，不代表真实屏幕采集权限已验收。
Windows、Linux 的用户插件宿主与界面尚未接入。

## 作者从哪里开始

最小示例是 [`../examples/capture-info`](../examples/capture-info/README.md)。作者主要
修改 MoonBit 业务函数和 manifest 中的必要信息，在仓库根目录运行：

```sh
python3 scripts/package_plugin.py plugins/examples/capture-info --output dist/capture-info.zip
```

脚本构建 `--target wasm`，输出包含 `manifest.json`、`plugin.wasm` 的 ZIP；存在时
同时加入 `assets/icon.png`。这是一包两个工具的示例：“截图信息”和“查看尺寸”。
两者都只返回文本，不自动写剪贴板。

当前固定组合：

| 层 | 固定值 |
| --- | --- |
| MoonBit 编译器 | `moonc v0.10.20+65efd5b93`（2026-11-05） |
| Moon 构建工具 | `moon 0.1.20261104`（`940aa18`） |
| 作者 PDK | `gmlewis/moonbit-pdk@0.47.35` |
| 原生执行运行时 | Extism `1.41.0` |
| 产物 / ABI | Wasm core v1、32 位线性内存；`mooji_run: () -> i32` |

编译器及 core 由 `scripts/install_moon.py` 固定；Extism 下载与校验由
`scripts/install_extism.py` 固定。PDK 是现成依赖，无需引入项目私有 SDK 或
`moon.work` 路径依赖。Manifest 中的 `runtime:"extism-1"` 表示协议兼容线，实际
worker 还会检查加载的原生库精确为 `1.41.0`。`action:"run"` 是目录语义，导出名
仍是 `mooji_run`。

## 数据与能力边界

普通调用由用户在当前截图工具栏中主动点按发起。插件收到局部 `toolId`、由宿主
生成的 `invocationId`，以及截图宽、高、PNG 格式与 revision；没有图像像素、文件
路径或剪贴板数据。返回值只能是包含相同 invocation ID 的纯文本结果。

导入和更新包时，宿主还会逐个工具进行带有合成截图元数据的 probe。这个
试运行不传入用户截图，也不自动展示结果或复制文本。插件必须支持 manifest 中
声明的全部工具。

重启时只复核已安装包的内容摘要与 manifest，并恢复目录和工具偏好，不执行插件
代码。首次点击工具时，worker 仍检查真实 Wasm ABI、运行时版本和输出；失效的
调用会返回错误。已停用的工具不会因为 App 重启而被试运行。

Manifest 必须恰好声明 `capture.metadata` 与 `result.text`。不接受网络、文件、
像素读取、自动写剪贴板或自定义界面能力；原生结果窗口提供用户主动点击的复制
按钮。详细字段、大小和错误返回见
[`src/internal/plugins/contracts/README.md`](../../src/internal/plugins/contracts/README.md)。

原始插件输出先受字节上限约束，再原样嵌入 MoonBit 校验 envelope。宿主不能先用
Foundation 解析再重编码，否则重复 JSON 字段会在校验前丢失。重复字段、未知声明、
错误 invocation ID 和超长文本均被拒绝。通过格式校验后，宿主仍检查调用未取消、
包摘要未变化、工具仍启用且截图 revision 仍有效。

## 每次调用的进程与限制

每次调用启动 App 自带的独立 worker，创建新的 Extism 实例，运行一次 `mooji_run`，
释放实例并退出。没有长驻插件 VM，不保留上次调用的 Wasm globals 或 heap，也没有
版本之间的状态迁移。更新只让后续调用使用新的包内容；旧调用被撤销后不能提交结果。

| 资源 | 默认上限 |
| --- | --- |
| 单个 Wasm 文件 | 4 MiB |
| 发送给 worker 的调用 JSON | 64 KiB |
| 原始结果 stdout | 256 KiB |
| 解码后的结果文本 | 32 KiB UTF-8 |
| worker stderr | 16 KiB |
| Wasm fuel | 50,000,000 |
| Wasm 线性内存 | 1,024 pages，即 64 MiB |
| Extism 执行超时 | 1,000 ms |
| 宿主总墙钟计时 | 5 秒，包含进程启动、编译与 IPC |

超时或取消会请求终止 worker；250 ms 后进程仍存活则发送 `SIGKILL`。完成回调等待
进程退出及管道关闭/排空后才交付，避免把“已经请求取消”误当成“资源已经释放”。
同一编辑器的新调用会撤销旧调用，普通后台调用总数最多为 4。

Fuel 不是 CPU 秒数；page 限制只覆盖 Wasm 线性内存，不是整个原生进程的 RSS
上限。独立进程、受限导入和资源限额也**不等于 OS sandbox**：首版没有额外的
macOS Seatbelt 隔离层。worker 禁用 WASI，不继承用户凭据等完整环境，不提供自定义
Host 函数；只接受选定的 Extism 输入、输出、错误和内存函数导入，运行时的 allowed
hosts/paths 均为空。原生引擎或宿主缺陷仍属于不同于 Wasm 代码本身的风险边界。

## 包、替换与卸载

ZIP 最大 8 MiB，解包内容最大 5 MiB；manifest 最大 64 KiB。可选 PNG 图标最大
256 KiB、宽高各不超过 512。宿主检查包结构、内容和实际运行结果之后才发布安装索引；
打包脚本的结构检查不能代替 App 的 MoonBit 校验与 probe。

工具的稳定 ID 是 `user.<pluginId>/<toolId>`。升级保留顺序与开关，新工具追加末尾。
卸载或移除某个工具后，布局仍保留它的隐藏记录；重新安装相同 ID 可恢复原偏好。
既有截图标注和工具样式不属于插件包内容，不因目录变更被删除。

生产数据目录位于 `~/Library/Application Support/Mooji Cut/Plugins`；测试 profile
使用独立目录。`catalog.json` 指向按内容摘要保存的包。替换或卸载后，不再被索引
引用的内容包暂时保留；首版没有孤儿包 GC，也没有承诺卸载立即回收这些磁盘空间。
失败的暂存目录会清理，这与已落盘但不再被引用的完整内容包不同。

## macOS 构建

`scripts/native.py build` 将对应 CPU 架构的固定 Extism 动态库与 worker 一同打包，
库、helper、App 按顺序签名。宿主界面不直接链接 Wasm 引擎；插件代码在单次调用
的 helper 中执行。当前验证为 Apple Silicon macOS；Intel helper 已交叉编译，
尚未在 Intel 机器执行。

沿用现有 App 的非 Hardened Runtime 签名方式。当前产物未公证，不能把本地
ad-hoc 验证当成发布签名验收。固定引擎的 JIT 分配方式需要在未来公证流程中
单独验证 helper 的可执行内存授权；此批没有给 UI 进程扩大权限。
