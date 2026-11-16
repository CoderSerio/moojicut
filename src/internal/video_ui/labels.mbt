// Human-readable action names live here; layout never measures these strings.
// The same descriptions serve accessibility and native hover help.

///|
fn control_label(s : UI, id : String) -> String {
  match id {
    "start" => "起点（Home）"
    "backward" => "后退"
    "play" =>
      if s.playing {
        "暂停（空格）"
      } else {
        "播放（空格）"
      }
    "forward" => "前进"
    "end" => "终点（End）"
    "undo" => "撤销"
    "redo" => "重做"
    "export" =>
      if s.export_busy {
        "正在保存视频…"
      } else {
        "保存视频"
      }
    "preview-rate" =>
      "预览速度 \{rate_label(s.preview_rate)}，仅影响观看"
    "preview-rate-menu" => "预览速度"
    "project-speed-menu" => "片段实际速度"
    "trim-start" => "裁剪起点"
    "trim-end" => "裁剪终点"
    "playhead" =>
      if is_project(s) {
        "成片播放位置"
      } else {
        "原片播放位置"
      }
    "project-split" => "在播放头处切分片段"
    "project-remove" =>
      if s.selected_gap != "" {
        "删除空隙并合拢"
      } else {
        "删除片段；Shift+Delete 删除并合拢"
      }
    "project-move-earlier" => "片段向前移动一位"
    "project-move-later" => "片段向后移动一位"
    "project-offset-earlier" => "独立音频向左偏移"
    "project-offset-later" => "独立音频向右偏移"
    "project-unlink" => "解除音视频关联"
    "project-audio-toggle" =>
      if s.audio_expanded {
        "收起音轨"
      } else {
        "展开音轨"
      }
    "project-mute" =>
      if !project(s).has_audio {
        "素材没有音频"
      } else if project(s).muted {
        "恢复成片声音"
      } else {
        "静音成片"
      }
    "project-crop" =>
      "裁剪画面；在预览中拖框，应用后影响整个成片"
    "project-crop-apply" =>
      if s.crop_candidate.width < 2 || s.crop_candidate.height < 2 {
        "请拖出至少 2×2 像素的裁剪框"
      } else {
        "应用画面裁剪（Enter）"
      }
    "project-crop-cancel" => "取消画面裁剪（Esc）"
    "project-crop-reset" =>
      if project(s).crop is None {
        "当前已是完整画面"
      } else {
        "恢复完整画面，可撤销"
      }
    "project-crop-region" =>
      "裁剪框；拖动重新框选，方向键移动，Shift 加方向键调整大小，Enter 应用"
    "project-zoom-out" => "缩小时间轴"
    "project-zoom-in" => "放大时间轴"
    "project-zoom-fit" => "适应全部成片"
    "project-speed" =>
      match project_selected(s) {
        Some(c) => "片段速度 \{clip_rate_label(c)}，改变成片时长"
        None => "片段速度，改变成片时长"
      }
    "project-trim-start" => "片段源起点"
    "project-trim-end" => "片段源终点"
    _ if rate_index(id) >= 0 =>
      "预览速度 \{rate_label(preview_rates[rate_index(id)])}，仅影响观看"
    _ if clip_rate_index(id) >= 0 => {
      let rate = rate_label(preview_rates[clip_rate_index(id)])
      if clip_rate_index(id) == 0 && !project_can_slow(s) {
        "片段实际速度 \{rate}，有声慢放暂不支持"
      } else {
        "片段实际速度 \{rate}，改变成片时长"
      }
    }
    _ => {
      if !is_project(s) {
        return ""
      }
      match project_clip_target(s, id) {
        Some(c) => {
          let wave = if c.kind != "audio" || has_waveform(s) {
            ""
          } else if s.waveform is None {
            "，正在生成波形"
          } else {
            "，波形不可用"
          }
          "\{if c.kind == "video" { "视频" } else { "音频" }}\{project_clip_label(c)}，\{clip_rate_label(c)}\{if c.link_group != "" { "，已关联" } else { "，独立" }}\{wave}"
        }
        None =>
          match project_gap_target(s, id) {
            Some(g) =>
              "空隙 \{fine_time(g.start / 90)} – \{fine_time(g.end / 90)}"
            None => ""
          }
      }
    }
  }
}
