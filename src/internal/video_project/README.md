# 视频项目 v2 核心

这是独立 MoonBit 包 `moojicut/core/internal/video_project`，不改写 `internal/video` 的 v1 API。它拥有文档、时间映射、验证、事务和历史，不拥有文件、播放器、窗口、UI 或媒体线程。当前支持一个素材、多视频片段与独立音频片段；字幕、特效、变速曲线及多个素材尚未实现。

## 公共入口

```text
open(source_json: String, draft_json: String) -> String
command(session: Int, command_json: String) -> String
snapshot(session: Int) -> String
close(session: Int) -> Unit
```

前三者返回 JSON。成功为 `{ok:true,session,revision,document,plan,canUndo,canRedo}`，错误沿用 `{ok:false,error:{code,message}}`。空 draft 新建；保存时存 `document`，不是整个响应。`close` 可重复调用。会话、历史与请求去重缓存只存在于内存；调用及会话生命周期由宿主串行管理。

## 文档与派生计划

以下为 180 秒、有声音素材的初始文档示例：

```json
{
  "schemaVersion": 2,
  "timebase": 90000,
  "frameRate": {"num": 30, "den": 1},
  "source": {"durationMs": 180000, "width": 1920, "height": 1080, "hasAudio": true},
  "clips": [
    {"id":"v1","kind":"video","sourceStartTicks":0,"sourceEndTicks":16200000,"startTicks":0,"durationTicks":16200000,"linkGroup":"g1"},
    {"id":"a1","kind":"audio","sourceStartTicks":0,"sourceEndTicks":16200000,"startTicks":0,"durationTicks":16200000,"linkGroup":"g1"}
  ],
  "crop": null,
  "muted": false,
  "preset": "share",
  "nextId": 2,
  "revision": 0
}
```

Clip 的源范围与输出范围均为左闭右开。倍率仅由 `(sourceEndTicks-sourceStartTicks)/durationTicks` 派生，不保存另一份可冲突的速度值。`startTicks/durationTicks` 必须在 3000 ticks 的输出帧网格；源边界为整数 ticks，允许 4500 等非整源帧边界。每个源跨度和输出跨度至少 3000 ticks。首版仅输出 30fps，video 恒速范围 0.25–4 倍，audio 为 1–4 倍。有声慢放在媒体读回中发现尾音损失，因此关联音视频低于 1 倍会以 `unsupported_audio_slowdown` 原子拒绝；可显式解除关联、只放慢视频并保留原速音频。观看用的 0.5 倍预览不受这一成片编辑限制影响。

计划为 `{schemaVersion:2,timebase:90000,frameRate,source,outputDurationTicks,video:[Clip],audio:[Clip],crop,muted,preset}`。分数组按输出起点排序；视频不重叠，音频可重叠以表达混音。至少保留一个视频片段，允许前置/中间黑场、静音间隙和音频尾部黑场。`outputDurationTicks` 取文档全部片段最远端点，不能把空隙自动合拢。`muted:true` 时 `plan.audio=[]`，但不改变文档音频片段或输出时长。

每个 audio clip 是该素材原音频的一次时间线实例；媒体端口只按 `plan.audio` 添加声音，不能再随 video 自动添加一次。素材有多个原音轨时，端口按每个 audio 实例导入它们各一次，并保留原偏移。核心的 gN 组严格包含时间映射相同的一视频与一音频，解除联动后各自编辑。

源时长与输出时长上限均为七天，源可用范围为完整 `durationMs*90`；每种 clip 上限 256。新建 1 倍速项目及 v1 迁移保留完整输出帧，最多将源尾向下收敛不足一帧，实际范围写入文档。v2 保存重开验证 source 元数据、ID、网格、边界、链接及重叠，拒绝未知文档/片段字段，不能默默丢掉未来版本数据。

## 命令

每次必须携带 `expectedRevision`。宿主可发送直接操作、`op` 包装或 `operations` 批量，三者互斥：

```json
{"expectedRevision":0,"requestId":"speed-1","op":{"type":"setSpeed","clipId":"v1","rate":{"num":3,"den":1}}}
```

这把完整 180 秒源区间压缩为 60 秒成片，同时修改关联音频；它不等于预览播放器倍率。`targetDurationTicks:5400000` 是同一需求的另一种输入，不能与 `rate` 同时提供。

| type | 操作字段与规则 |
| --- | --- |
| `split` | `clipId,atTicks`，位置为时间线绝对 ticks；左右至少各一源帧/输出帧。左侧保留 ID，右侧分配新的 vN/aN/gN。 |
| `remove` | `clipId,ripple?:true,linked?:true`；默认关联音视频一起删除、后片合拢；`ripple:false` 保留空隙。拒绝删掉最后一个视频。 |
| `removeGap` | `startTicks,endTicks`，必须精确匹配当前视频轨一个完整空隙的整数输出帧边界；可删除前置或中间空隙，所有在 end 及之后的音视频片段一起前移。不接受局部范围、旧空隙或输出结束后的区域；音频与空隙有任何正长度交集时以 `ambiguous_ripple` 原子拒绝，恰好在 start 结束或 end 开始则允许。 |
| `move` | `clipId,beforeClipId:null或视频ID,linked?:true`；先取出再插入，null 表示视频末尾。关联 audio ID 也可选中整组；独立音频必须用 offset。 |
| `setSpeed` | `clipId,rate:{num,den}` 或 `targetDurationTicks` 二选一，`linked?:true,ripple?:true`；固定源范围和输出起点，改变时长。 |
| `trim` | `clipId,sourceStartTicks,sourceEndTicks,linked?:true,ripple?:true`；固定输出起点，按原倍率重算输出时长。普通修剪不会变成速度拉伸。 |
| `unlink` | `clipId`，解除整组关系，保留成员 ID 与原有时间范围。 |
| `mute` | `muted:bool`，全局静音或恢复声音；保留所有音频片段、关联及输出时长，只改变计划的音频是否输出。 |
| `crop` | `crop:null或{x,y,width,height}`，对整个成片应用源像素坐标画面裁剪；null 恢复完整画面。与 v1 共用 `video.normalize_crop` 的边界/整数校验和宽高向下取偶数规则。 |
| `offset` | `clipId,deltaTicks`，仅独立音频；可向前/后移动，但结果不能负数或超过时长上限。 |
| `undo/redo` | 必须为单独事务，不与其他操作混合。 |

`linked:false` 不会隐式拆掉已有链接组，须先显式 `unlink`。独立音频自身编辑可用 `ripple:false`，不会移动视频。调整或搬移视频时，若另一个独立片段跨过受影响范围/插入边界，首版返回 `ambiguous_ripple`，不擅自剪掉声音或改变其速度。无 ripple 的延长若产生同轨视频重叠，原子拒绝。

## 时间与事务保证

- 用户输入的时间线位置、时长和移动后的 trim 边界就近量化至 3000 ticks，恰半帧取较晚边界；未移动的精确源边界原样保留。目标时长不足一帧、速度计算出的理想时长不足一帧均拒绝，不偷偷钳制为一帧。
- Split 内部源分界仅量化至一个 tick，半 tick 向后，左右共享同一分界；输出时长严格守恒。先缩成输出帧数，再用有界 Int64 乘除与余数舍入，避免长片段 Double 乘法错舍入。每次派生分界误差不超过 0.5 tick；不宣称任意有理速度无限精确。
- 成功返回的源范围、输出时长及派生倍率是实际值。保音调由媒体端口执行；当前没有可修改的保音调字段，片段变速默认保音调。UI 的 `previewRate` 不属于文档和计划。
- 一个批量最多 64 项，每一项通过验证才继续；任何失败都不改变文档、ID 分配、历史或 revision。成功批次形成一个撤销步骤；纯无变化操作不增加 revision。
- revision 在编辑及 undo/redo 后递增，不回退。nextId 保持高水位，撤销过的可见 ID 不复用；保存时一同持久化。历史各方向最多 100 项，重开不恢复历史。
- `requestId` 可选，长度 1–128，缓存最近 64 次成功响应。同 ID、同请求重试先命中缓存再检查旧 revision；不同请求使用同 ID 返回冲突。缓存响应保留原 revision，调用方不能用旧响应覆盖已见到的更新版本。缓存淘汰后旧请求因 revision 过期而失败，不会重复编辑。失败不缓存。

v1 迁移调用既有 `@video.edit_plan` 得到真实保留区间，再生成片段；保留 crop、muted 和 preset，不写旧文件，不修改旧 API。短到不能保留一帧的旧区间明确拒绝，交由宿主保留原草稿并提示。

## 验证边界

本包回归覆盖 180 秒→60 秒、三段调序/删除/撤销、独立音频偏移、保存重开、v1 迁移、批量失败、旧 revision、重复请求、撤销后的 ID、长时间精确舍入和空隙。可定向运行：

```sh
moon test src/internal/video_project --target native --deny-warn
moon test src/internal/video_project --target wasm --deny-warn
```

这些验证文档与计划，不代替媒体解码/保音调、实际导出或三端共享 UI 验收。
