# MoonBit 核心代码

共享业务逻辑优先用 MoonBit 实现，平台宿主负责系统 API、界面交互和媒体执行。
目前核心编译为原生静态库，由 macOS、Windows 和 Linux 宿主链接；不是通过 Wasm 运行。

## 目录与边界

这一轮先拆出编辑样式包，其余模块保留原位置，按依赖逐步整理。

```text
src/
├── moon.pkg                       # 原生静态库入口与依赖
├── editor_style.mbt                # 稳定的样式 C ABI / MoonBit 入口
├── editor_style_wbtest.mbt          # 图像文档与样式规则的集成测试
├── internal/
│   └── editor_style/
│       ├── moon.pkg
│       ├── domains.mbt             # 属性范围、默认值与工具支持的属性
│       ├── sessions.mbt            # 每个编辑器、每种工具的样式状态
│       ├── style_wbtest.mbt         # 样式包自己的行为测试
│       └── pkg.generated.mbti      # 自动生成的包接口
├── image_model.mbt                 # 图像文档、标注与历史
├── image_session.mbt               # 图像会话的原生调用适配
├── video_document.mbt              # 视频文档、命令与历史
├── native_video.mbt                # 视频会话的原生调用适配
├── timeline.mbt                    # 时间线与剪辑计划
├── export_profile.mbt              # 导出配置计算
├── geometry.mbt                    # 裁剪几何规则
├── recording.mbt                   # 录制状态转换规则
├── desktop.mbt                     # 快捷键校验与核心自检
└── validation.mbt                  # 现有 JSON 校验与错误响应
```

每个 `moon.pkg` 所在目录是独立包。`internal` 下的包仅供本模块使用，跨包依赖仍须显式导入。
根包保留 `foreign_library` 和现有 `#export_name` 入口；这些入口只转发到已拆出的实现，
不复制业务规则或维护第二份状态。图像文档校验与原生样式入口使用同一份样式规则。

## 后续整理原则

- 新增跨平台的规则、状态、命令和文档处理优先放在 MoonBit；平台权限、窗口、绘制、采集和编码留在原生宿主。
- 按职责建立内部包，不按单个文件建包，也不建一个继续平铺所有实现的大包。
- 包内测试与实现放在一起；跨包集成测试留在调用方，不为移动测试暴露私有状态。
- 后续先明确共享 JSON 校验与错误协议，再分别整理图像包和视频包。图像模型与会话一起迁移；视频文档、时间线、导出计划与会话一起评估。
- 依赖保持单向：原生调用入口 → 业务包 → 共享规则。子包不反向依赖根包。
- 调整目录时保留现有原生符号、参数类型和文档格式；业务行为变更单独处理。

## 验证

整理后运行 `moon check --target native --deny-warn`、`moon test --target native --deny-warn`
和 `moon info --target native`，并提交各包的 `pkg.generated.mbti`。
根包接口应保持兼容，原生静态库仍需通过 `test/native/core-embedding.m` 的实际链接与调用检查。
