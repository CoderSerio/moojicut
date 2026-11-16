///|
fn project_track(s : UI, kind : String) -> Rect {
  {
    x: 80,
    y: s.height - (if kind == "audio" { 86.0 } else { 126.0 }),
    width: s.width - 120,
    height: if kind == "audio" { 42.0 } else { 30.0 },
  }
}

///|
fn project_x(s : UI, ticks : Double) -> Double {
  let r = project_track(s, "video")
  @video.timeline_x_for_time(
    ticks / 90 - s.viewport_start,
    s.viewport_span,
    r.x,
    r.width,
  )
}

///|
fn project_time(s : UI, x : Double) -> Double {
  let r = project_track(s, "video")
  s.viewport_start +
  @video.timeline_time_for_x(x, s.viewport_span, r.x, r.width)
}

///|
fn project_clip_rect(s : UI, c : ProjectClip) -> Rect {
  project_interval_rect(s, c.start, c.start + c.duration, c.kind)
}

///|
fn project_speed_rect(s : UI) -> Rect {
  { x: 200, y: s.height - 202, width: 156, height: 142, }
}

///|
fn project_control_rect(s : UI, id : String) -> Rect {
  let y = s.height - 244
  let tool_y = s.height - 182
  match id {
    "export" => { x: s.width - 60, y: 24, width: 36, height: 36, }
    "undo" => { x: s.width - 148, y: 24, width: 36, height: 36, }
    "redo" => { x: s.width - 104, y: 24, width: 36, height: 36, }
    "start" => { x: s.width / 2 - 106, y, width: 36, height: 36, }
    "backward" => { x: s.width / 2 - 62, y, width: 36, height: 36, }
    "play" => { x: s.width / 2 - 18, y, width: 36, height: 36, }
    "forward" => { x: s.width / 2 + 26, y, width: 36, height: 36, }
    "end" => { x: s.width / 2 + 70, y, width: 36, height: 36, }
    "preview-rate" => { x: s.width - 112, y, width: 88, height: 36, }
    "preview-rate-menu" => rate_menu_rect(s)
    "project-speed-menu" => project_speed_rect(s)
    "project-split" => { x: 40, y: tool_y, width: 32, height: 32, }
    "project-remove" => { x: 80, y: tool_y, width: 32, height: 32, }
    "project-move-earlier" | "project-offset-earlier" =>
      { x: 120, y: tool_y, width: 32, height: 32, }
    "project-move-later" | "project-offset-later" =>
      { x: 160, y: tool_y, width: 32, height: 32, }
    "project-speed" => { x: 200, y: tool_y, width: 88, height: 32, }
    "project-unlink" => { x: 296, y: tool_y, width: 32, height: 32, }
    "project-mute" => { x: 336, y: tool_y, width: 32, height: 32, }
    "project-crop" => { x: 376, y: tool_y, width: 32, height: 32, }
    "project-crop-apply" => { x: 40, y: tool_y, width: 32, height: 32, }
    "project-crop-cancel" => { x: 80, y: tool_y, width: 32, height: 32, }
    "project-crop-reset" => { x: 120, y: tool_y, width: 32, height: 32, }
    "project-crop-region" => project_video_rect(s)
    "project-audio-toggle" =>
      { x: s.width - 72, y: tool_y, width: 32, height: 32, }
    "project-zoom-out" =>
      { x: s.width - 152, y: s.height - 52, width: 32, height: 32, }
    "project-zoom-in" =>
      { x: s.width - 112, y: s.height - 52, width: 32, height: 32, }
    "project-zoom-fit" =>
      { x: s.width - 72, y: s.height - 52, width: 32, height: 32, }
    "project-trim-start" | "project-trim-end" =>
      match project_selected(s) {
        Some(c) => {
          if !project_handle_visible(s, id) {
            return { x: 0, y: 0, width: 0, height: 0, }
          }
          let r = project_track(s, c.kind)
          let x = project_x(
            s,
            if id == "project-trim-start" {
              c.start
            } else {
              c.start + c.duration
            },
          )
          {
            x: clamp(x - 6, r.x, r.x + r.width - 12),
            y: r.y,
            width: 12,
            height: r.height,
          }
        }
        None => { x: 0, y: 0, width: 0, height: 0, }
      }
    "playhead" => {
      let r = project_track(s, "video")
      { x: r.x, y: r.y - 22, width: r.width, height: 20, }
    }
    _ if rate_index(id) >= 0 => {
      let r = rate_menu_rect(s)
      {
        x: r.x + 6,
        y: r.y + 6 + rate_index(id).to_double() * 26,
        width: r.width - 12,
        height: 26,
      }
    }
    _ if clip_rate_index(id) >= 0 => {
      let r = project_speed_rect(s)
      {
        x: r.x + 6,
        y: r.y + 6 + clip_rate_index(id).to_double() * 26,
        width: r.width - 12,
        height: 26,
      }
    }
    _ =>
      match project_clip_target(s, id) {
        Some(c) => project_clip_rect(s, c)
        None =>
          match project_gap_target(s, id) {
            Some(g) => project_gap_rect(s, g)
            None => { x: 0, y: 0, width: 0, height: 0, }
          }
      }
  }
}

///|
fn project_video_index(s : UI, id : String) -> Int32 {
  for i, c in project_clips(s, "video") {
    if c.id == id {
      return i
    }
  }
  -1
}

///|
fn project_editable(s : UI) -> Bool {
  s.media_ready && !s.export_busy
}

///|
fn project_enabled(s : UI, id : String) -> Bool {
  if s.crop_mode {
    return match id {
      "project-crop-region" | "project-crop-cancel" => true
      "project-crop-apply" =>
        project_editable(s) &&
        s.crop_candidate.width >= 2 &&
        s.crop_candidate.height >= 2
      "project-crop-reset" => project_editable(s) && project(s).crop is Some(_)
      _ => false
    }
  }
  match id {
    "project-mute" => project_editable(s) && project(s).has_audio
    "project-crop" => project_editable(s)
    "undo" => !s.export_busy && s.snapshot.can_undo
    "redo" => !s.export_busy && s.snapshot.can_redo
    "export" => project_editable(s)
    "play"
    | "playhead"
    | "start"
    | "backward"
    | "forward"
    | "end"
    | "preview-rate" => s.media_ready
    "project-audio-toggle" => !project_clips(s, "audio").is_empty()
    "project-zoom-in" => s.viewport_span > project_min_span(s)
    "project-zoom-out" => s.viewport_span < s.viewport_extent
    "project-zoom-fit" =>
      s.viewport_start != 0 || s.viewport_span != s.snapshot.duration
    _ if rate_index(id) >= 0 => s.media_ready && s.rate_menu
    _ if clip_rate_index(id) >= 0 =>
      project_editable(s) &&
      s.clip_speed_menu &&
      project_selected(s) is Some(_) &&
      (clip_rate_index(id) != 0 || project_can_slow(s))
    _ => {
      match project_clip_target(s, id) {
        Some(c) =>
          return (c.kind == "video" || s.audio_expanded) &&
            project_clip_rect(s, c).width > 0
        None => ()
      }
      if project_gap_target(s, id) is Some(g) {
        return project_gap_rect(s, g).width > 0
      }
      if !project_editable(s) {
        return false
      }
      if project_gap_target(s, s.selected_gap) is Some(_) {
        return id == "project-remove"
      }
      match project_selected(s) {
        None => false
        Some(c) =>
          match id {
            "project-split" => {
              let t = (s.source_time * 90 / 3000 + 0.5).to_int().to_double() *
                3000
              t >= c.start + 3000 &&
              t <= c.start + c.duration - 3000 &&
              (t - c.start) * clip_rate(c) >= 3000 &&
              (c.start + c.duration - t) * clip_rate(c) >= 3000
            }
            "project-remove" => {
              let videos = project_clips(s, "video")
              if c.kind == "video" {
                videos.length() > 1
              } else {
                c.link_group == "" ||
                !videos.any(v => v.link_group == c.link_group) ||
                videos.length() > 1
              }
            }
            "project-move-earlier" =>
              c.kind == "video" && project_video_index(s, c.id) > 0
            "project-move-later" =>
              c.kind == "video" &&
              project_video_index(s, c.id) <
              project_clips(s, "video").length() - 1
            "project-offset-earlier" =>
              c.kind == "audio" && c.link_group == "" && c.start > 0
            "project-offset-later" => c.kind == "audio" && c.link_group == ""
            "project-unlink" => c.link_group != ""
            "project-speed" => true
            "project-trim-start" | "project-trim-end" =>
              project_handle_visible(s, id)
            _ => false
          }
      }
    }
  }
}

///|
fn project_toolbar(s : UI) -> Array[String] {
  if s.crop_mode {
    return ["project-crop-apply", "project-crop-cancel", "project-crop-reset"]
  }
  let audio = match project_selected(s) {
    Some(c) => c.kind == "audio"
    None => false
  }
  [
    "project-split",
    "project-remove",
    if audio {
      "project-offset-earlier"
    } else {
      "project-move-earlier"
    },
    if audio {
      "project-offset-later"
    } else {
      "project-move-later"
    },
    "project-speed",
    "project-unlink",
    "project-mute",
    "project-crop",
    "project-audio-toggle",
  ]
}

///|
fn project_focus_targets(s : UI) -> Array[String] {
  if s.crop_mode {
    return [
      "project-crop-region", "project-crop-apply", "project-crop-cancel", "project-crop-reset",
    ]
  }
  let targets : Array[String] = [
    "undo", "redo", "export", "start", "backward", "play", "forward", "end", "preview-rate",
  ]
  for id in project_toolbar(s) {
    targets.push(id)
  }
  for g in project_gaps(s) {
    targets.push(project_gap_id(g))
  }
  for c in project_clips(s, "video") {
    targets.push("clip:\{c.id}")
  }
  if s.audio_expanded {
    for c in project_clips(s, "audio") {
      targets.push("clip:\{c.id}")
    }
  }
  for id in ["project-trim-start", "project-trim-end", "playhead"] {
    targets.push(id)
  }
  targets
}

///|
fn project_hit(s : UI, x : Double, y : Double) -> String {
  if s.crop_mode {
    for id in project_focus_targets(s) {
      if enabled(s, id) && contains(control_rect(s, id), x, y) {
        return id
      }
    }
    return ""
  }
  if s.rate_menu || s.clip_speed_menu {
    let items = if s.rate_menu { rate_ids } else { clip_rate_ids }
    for id in items {
      if contains(control_rect(s, id), x, y) && enabled(s, id) {
        return id
      }
    }
    let button = if s.rate_menu { "preview-rate" } else { "project-speed" }
    if contains(control_rect(s, button), x, y) {
      return button
    }
    return ""
  }
  for
    id in [
      "undo", "redo", "export", "start", "backward", "play", "forward", "end", "preview-rate",
    ] {
    if enabled(s, id) && contains(control_rect(s, id), x, y) {
      return id
    }
  }
  for id in project_toolbar(s) {
    if enabled(s, id) && contains(control_rect(s, id), x, y) {
      return id
    }
  }
  let a = enabled(s, "project-trim-start") &&
    contains(control_rect(s, "project-trim-start"), x, y)
  let b = enabled(s, "project-trim-end") &&
    contains(control_rect(s, "project-trim-end"), x, y)
  if a && b {
    let left = control_rect(s, "project-trim-start").x
    let right = control_rect(s, "project-trim-end").x
    return if x <= (left + right) / 2 + 6 {
      "project-trim-start"
    } else {
      "project-trim-end"
    }
  }
  if a {
    return "project-trim-start"
  }
  if b {
    return "project-trim-end"
  }
  // Later overlapping independent audio clips remain reachable by keyboard/AX.
  let clips = project(s).clips
  for i = clips.length() - 1; i >= 0; i = i - 1 {
    let c = clips[i]
    if (c.kind == "video" || s.audio_expanded) &&
      project_clip_rect(s, c).width > 0 &&
      contains(project_clip_rect(s, c), x, y) {
      return "clip:\{c.id}"
    }
  }
  for g in project_gaps(s) {
    let r = project_gap_rect(s, g)
    if r.width > 0 && contains(r, x, y) {
      return project_gap_id(g)
    }
  }
  if s.media_ready {
    if contains(control_rect(s, "playhead"), x, y) ||
      contains(project_track(s, "video"), x, y) ||
      (s.audio_expanded && contains(project_track(s, "audio"), x, y)) {
      return "playhead"
    }
  }
  ""
}

///|
fn project_can_slow(s : UI) -> Bool {
  match project_selected(s) {
    None => false
    Some(c) =>
      c.kind == "video" &&
      (
        c.link_group == "" ||
        !project_clips(s, "audio").any(a => a.link_group == c.link_group)
      )
  }
}
