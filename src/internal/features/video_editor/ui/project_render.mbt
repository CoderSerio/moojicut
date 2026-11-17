///|
fn project_draw_button(
  commands : Array[Json],
  semantics : Array[Json],
  s : UI,
  id : String,
) -> Unit {
  let p = palette(s)
  let r = control_rect(s, id)
  let active = enabled(s, id)
  let selected = (id == "project-audio-toggle" && s.audio_expanded) ||
    (id == "project-mute" && project(s).muted)
  let fill = if active && s.gesture == id {
    p.button_pressed
  } else if selected || (active && s.hover == id) {
    p.button_hover
  } else {
    p.button
  }
  draw_rect(
    commands,
    s,
    r,
    5,
    fill,
    if s.focus == id && active {
      p.focus
    } else {
      ""
    },
  )
  let color = if active { p.text } else { p.disabled }
  if id == "project-speed" {
    let value = match project_selected(s) {
      Some(c) => clip_rate_label(c)
      None => "—"
    }
    draw_rate_button_content(commands, s, r, id, value, color)
  } else {
    draw_action_icon(commands, s, r, id, color)
  }
  semantics.push(
    semantic(
      s,
      id,
      "button",
      if id == "project-audio-toggle" || id == "project-mute" {
        Json(selected)
      } else {
        Json::null()
      },
    ),
  )
}

///|
fn project_draw_speed_menu(
  commands : Array[Json],
  semantics : Array[Json],
  s : UI,
) -> Unit {
  let p = palette(s)
  draw_rect(commands, s, project_speed_rect(s), 9, p.panel, p.border)
  semantics.push(semantic(s, "project-speed-menu", "group", Json::null()))
  let current = match project_selected(s) {
    Some(c) => clip_rate(c)
    None => 1.0
  }
  for i, id in clip_rate_ids {
    let r = control_rect(s, id)
    let selected = (current - preview_rates[i]).abs() < 0.01
    let active = enabled(s, id)
    if active && (s.focus == id || s.hover == id) {
      draw_rect(
        commands,
        s,
        r,
        5,
        p.button_hover,
        if s.focus == id {
          p.focus
        } else {
          ""
        },
      )
    }
    if selected {
      draw_line(commands, s, r.x + 8, r.y + 13, r.x + 11, r.y + 16, p.text, 1.5)
      draw_line(commands, s, r.x + 11, r.y + 16, r.x + 17, r.y + 9, p.text, 1.5)
    }
    let label = rate_label(preview_rates[i])
    draw_text(
      commands,
      s,
      { x: r.x + 26, y: r.y, width: r.width - 32, height: r.height, },
      label,
      if active {
        p.text
      } else {
        p.disabled
      },
      12,
      if selected {
        "medium"
      } else {
        "regular"
      },
      "left",
    )
    semantics.push(semantic(s, id, "button", Json(selected)))
  }
}

///|
fn project_slider(
  s : UI,
  id : String,
  value : Double,
  maximum : Double,
) -> Json {
  match semantic(s, id, "slider", Json(value)) {
    Object(fields) => {
      fields["min"] = Json(0)
      fields["max"] = Json(maximum)
      Json::object(fields)
    }
    _ => abort("semantic object")
  }
}

///|
fn project_draw_row(
  commands : Array[Json],
  semantics : Array[Json],
  s : UI,
  kind : String,
) -> Unit {
  let p = palette(s)
  let row = project_track(s, kind)
  draw_text(
    commands,
    s,
    { x: 40, y: row.y, width: 30, height: row.height, },
    if kind == "video" {
      "V1"
    } else {
      "A1"
    },
    p.secondary,
    11,
    "medium",
    "left",
  )
  draw_rect(commands, s, row, 4, p.track, "")
  if kind == "video" {
    for g in project_gaps(s) {
      let r = project_gap_rect(s, g)
      if r.width <= 0 {
        continue
      }
      let id = project_gap_id(g)
      let selected = s.selected_gap == id
      if selected || s.hover == id {
        draw_rect(
          commands,
          s,
          r,
          2,
          p.button_hover,
          if selected {
            p.focus
          } else {
            p.border
          },
        )
      }
      semantics.push(semantic(s, id, "button", Json(selected)))
    }
  }
  for c in project_clips(s, kind) {
    let r = project_clip_rect(s, c)
    if r.width <= 0 {
      continue
    }
    let moving = s.clip_drag_active &&
      project_selected(s) is Some(selected) &&
      project_moves_with(c, selected)
    let selected = s.selected_gap == "" && (c.id == s.selected_clip || moving)
    draw_rect(
      commands,
      s,
      r,
      3,
      if selected {
        p.button_pressed
      } else {
        p.clip
      },
      if moving && !s.clip_move_valid {
        p.disabled
      } else if selected {
        p.focus
      } else {
        p.clip_border
      },
    )
    project_draw_waveform(commands, s, c, r)
    if r.width > 48 {
      let label = "#\{c.id[1:]} · \{clip_rate_label(c)}"
      draw_text(
        commands,
        s,
        {
          x: r.x + 8,
          y: r.y,
          width: r.width - 16,
          height: if kind == "audio" && has_waveform(s) {
            14.0
          } else {
            r.height
          },
        },
        label,
        p.text,
        11,
        "medium",
        "left",
      )
    }
    if c.link_group != "" && r.width > 130 {
      // Two overlapping outlines mark the actual linked video/audio group.
      let link_y = r.y +
        (if kind == "audio" && has_waveform(s) { 3.0 } else { 10.0 })
      draw_rect(
        commands,
        s,
        { x: r.x + r.width - 25, y: link_y, width: 10, height: 7, },
        2,
        p.clip,
        p.secondary,
      )
      draw_rect(
        commands,
        s,
        { x: r.x + r.width - 19, y: link_y + 3, width: 10, height: 7, },
        2,
        p.clip,
        p.secondary,
      )
    }
    semantics.push(semantic(s, "clip:\{c.id}", "button", Json(selected)))
  }
}

///|
fn project_frame(s : UI) -> Json {
  let p = palette(s)
  let commands : Array[Json] = []
  let semantics : Array[Json] = []
  draw_rect(
    commands,
    s,
    { x: 0, y: 0, width: s.width, height: s.height, },
    0,
    p.background,
    "",
  )
  for id in ["undo", "redo"] {
    draw_button(commands, semantics, s, id, false)
  }
  draw_button(commands, semantics, s, "export", true)
  let stage : Rect = {
    x: 24,
    y: 80,
    width: s.width - 48,
    height: s.height - 344,
  }
  draw_rect(commands, s, stage, 10, p.stage, p.border)
  let video = project_video_rect(s)
  if s.crop_mode {
    let c = s.crop_candidate
    semantics.push(
      semantic(
        s,
        "project-crop-region",
        "button",
        Json(
          "\{c.x.to_int()}, \{c.y.to_int()} · \{c.width.to_int()}×\{c.height.to_int()}",
        ),
      ),
    )
  }
  draw_text(
    commands,
    s,
    { x: 24, y: s.height - 244, width: 200, height: 36, },
    "\{fine_time(s.source_time)} / \{fine_time(s.snapshot.output_duration)}",
    p.secondary,
    12,
    "medium",
    "left",
  )
  for id in ["start", "backward", "play", "forward", "end"] {
    draw_button(commands, semantics, s, id, false)
  }
  draw_button(commands, semantics, s, "preview-rate", false)
  draw_rect(
    commands,
    s,
    { x: 24, y: s.height - 188, width: s.width - 48, height: 172, },
    10,
    p.panel,
    p.border,
  )
  for id in project_toolbar(s) {
    project_draw_button(commands, semantics, s, id)
  }
  let row = project_track(s, "video")
  let step = @video.timeline_tick_step(s.viewport_span, row.width, 72)
  let mut time = (s.viewport_start / step).to_int64().to_double() * step
  if time < s.viewport_start {
    time = time + step
  }
  let mut count = 0
  while time <= s.viewport_start + s.viewport_span && count < 500 {
    let x = project_x(s, time * 90)
    draw_line(commands, s, x, row.y - 7, x, row.y - 2, p.tick, 1)
    draw_text(
      commands,
      s,
      {
        x: clamp(x - 26, row.x, row.x + row.width - 52),
        y: row.y - 24,
        width: 52,
        height: 16,
      },
      tick_label(time, step),
      p.muted,
      10,
      "regular",
      "center",
    )
    time = time + step
    count = count + 1
  }
  project_draw_row(commands, semantics, s, "video")
  if s.audio_expanded {
    project_draw_row(commands, semantics, s, "audio")
  }
  match project_selected(s) {
    Some(c) if c.kind == "video" || s.audio_expanded => {
      for
        (id, value) in [
          ("project-trim-start", c.source_start),
          ("project-trim-end", c.source_end),
        ] {
        if s.clip_drag_active || !project_handle_visible(s, id) {
          continue
        }
        let r = control_rect(s, id)
        draw_rect(
          commands,
          s,
          { x: r.x + 3, y: r.y + 3, width: 6, height: r.height - 6, },
          2,
          if enabled(s, id) {
            p.handle
          } else {
            p.handle_disabled
          },
          if s.focus == id {
            p.focus
          } else {
            ""
          },
        )
        semantics.push(
          project_slider(s, id, value / 90, project(s).source_duration / 90),
        )
      }
      if s.gesture == "project-trim-start" || s.gesture == "project-trim-end" {
        let start = s.gesture == "project-trim-start"
        let ticks = if start {
          c.start + (s.clip_trim_start - c.source_start) / clip_rate(c)
        } else {
          c.start + c.duration + (s.clip_trim_end - c.source_end) / clip_rate(c)
        }
        let x = project_x(s, ticks)
        let rect = project_clip_rect(s, c)
        if project_visible(s, ticks / 90) {
          draw_line(
            commands,
            s,
            x,
            rect.y - 3,
            x,
            rect.y + rect.height + 3,
            p.focus,
            2,
          )
        }
      }
    }
    _ => ()
  }
  let px = project_x(s, s.source_time * 90)
  let bottom = if s.audio_expanded {
    project_track(s, "audio").y + project_track(s, "audio").height + 1
  } else {
    row.y + 33
  }
  if project_visible(s, s.source_time) {
    draw_line(commands, s, px, row.y - 10, px, bottom, p.playhead, 1.5)
    draw_rect(
      commands,
      s,
      {
        x: clamp(px - 4, row.x, row.x + row.width - 8),
        y: row.y - 14,
        width: 8,
        height: 7,
      },
      2,
      p.playhead,
      "",
    )
  }
  semantics.push(semantic(s, "playhead", "slider", Json(s.source_time)))
  let status = if s.crop_mode {
    "\{s.crop_candidate.width.to_int()}×\{s.crop_candidate.height.to_int()} · Enter 应用 · Esc 取消"
  } else if s.clip_drag_active {
    if s.clip_move_valid {
      fine_time(s.clip_move_start / 90)
    } else {
      "视频片段不能重叠"
    }
  } else if s.message != "" {
    s.message
  } else if s.gesture == "project-trim-start" || s.gesture == "project-trim-end" {
    "修剪源范围 \{fine_time(s.clip_trim_start / 90)} – \{fine_time(s.clip_trim_end / 90)}"
  } else {
    ""
  }
  if status != "" {
    draw_text(
      commands,
      s,
      { x: 40, y: s.height - 44, width: s.width - 330, height: 18, },
      status,
      if s.message_error {
        p.text
      } else {
        p.muted
      },
      11,
      "regular",
      "left",
    )
  }
  draw_text(
    commands,
    s,
    { x: s.width - 260, y: s.height - 52, width: 100, height: 32, },
    fine_time(s.viewport_span),
    p.secondary,
    10,
    "regular",
    "right",
  )
  if s.rate_menu {
    draw_rate_menu(commands, semantics, s)
  }
  if s.clip_speed_menu {
    project_draw_speed_menu(commands, semantics, s)
  }
  Json::object({
    "ok": Json(true),
    "videoRect": Json::object(rect_json(video, s.scale)),
    "commands": Json::array(commands),
    "overlayCommands": Json::array(project_crop_overlay(s)),
    "semantics": Json::array(semantics),
    "cursor": Json(cursor(s)),
    "revision": Json(project(s).revision),
    "viewport": Json::object({
      "startMs": Json(s.viewport_start),
      "spanMs": Json(s.viewport_span),
      "totalMs": Json(s.snapshot.duration),
    }),
  })
}
