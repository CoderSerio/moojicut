///|
priv struct Rect {
  x : Double
  y : Double
  width : Double
  height : Double
}

///|
fn track(s : UI) -> Rect {
  { x: 48, y: s.height - 96, width: s.width - 96, height: 40, }
}

///|
fn time_x(s : UI, time : Double) -> Double {
  let r = track(s)
  @video.timeline_x_for_time(time, s.snapshot.duration, r.x, r.width)
}

///|
fn control_rect(s : UI, id : String) -> Rect {
  if is_project(s) {
    return project_control_rect(s, id)
  }
  let y = s.height - 216
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
    "trim-start" =>
      {
        x: time_x(s, s.preview_start) - 10,
        y: track(s).y,
        width: 20,
        height: 40,
      }
    "trim-end" =>
      {
        x: time_x(s, s.preview_end) - 10,
        y: track(s).y,
        width: 20,
        height: 40,
      }
    "playhead" =>
      { x: track(s).x, y: track(s).y - 18, width: track(s).width, height: 62, }
    _ if rate_index(id) >= 0 => {
      let menu = rate_menu_rect(s)
      {
        x: menu.x + 6,
        y: menu.y + 6 + rate_index(id).to_double() * 26,
        width: menu.width - 12,
        height: 26,
      }
    }
    _ => { x: 0, y: 0, width: 0, height: 0, }
  }
}

///|
fn rate_menu_rect(s : UI) -> Rect {
  if is_project(s) {
    return { x: s.width - 180, y: s.height - 202, width: 156, height: 142, }
  }
  { x: s.width - 180, y: s.height - 174, width: 156, height: 142, }
}

///|
fn contains(r : Rect, x : Double, y : Double) -> Bool {
  r.width > 0 &&
  r.height > 0 &&
  x >= r.x &&
  x <= r.x + r.width &&
  y >= r.y &&
  y <= r.y + r.height
}

///|
fn enabled(s : UI, id : String) -> Bool {
  if is_project(s) {
    return project_enabled(s, id)
  }
  match id {
    "undo" => !s.export_busy && s.snapshot.can_undo
    "redo" => !s.export_busy && s.snapshot.can_redo
    "export" => s.media_ready && !s.export_busy
    "trim-start" | "trim-end" => s.media_ready && !s.export_busy
    "play"
    | "playhead"
    | "start"
    | "backward"
    | "forward"
    | "end"
    | "preview-rate" => s.media_ready
    _ if rate_index(id) >= 0 => s.media_ready && s.rate_menu
    _ => false
  }
}

///|
fn hit(s : UI, x : Double, y : Double) -> String {
  if is_project(s) {
    return project_hit(s, x, y)
  }
  if s.rate_menu {
    for id in rate_ids {
      if contains(control_rect(s, id), x, y) && enabled(s, id) {
        return id
      }
    }
    if contains(control_rect(s, "preview-rate"), x, y) {
      return "preview-rate"
    }
    return ""
  }
  for
    id in [
      "export", "undo", "redo", "start", "backward", "play", "forward", "end", "preview-rate",
    ] {
    if contains(control_rect(s, id), x, y) && enabled(s, id) {
      return id
    }
  }
  let a = enabled(s, "trim-start") &&
    contains(control_rect(s, "trim-start"), x, y)
  let b = enabled(s, "trim-end") && contains(control_rect(s, "trim-end"), x, y)
  if a && b {
    return if x <= (time_x(s, s.preview_start) + time_x(s, s.preview_end)) / 2 {
      "trim-start"
    } else {
      "trim-end"
    }
  }
  if a {
    return "trim-start"
  }
  if b {
    return "trim-end"
  }
  if enabled(s, "playhead") && contains(control_rect(s, "playhead"), x, y) {
    return "playhead"
  }
  ""
}

///|
fn rect_json(r : Rect, scale : Double) -> Map[String, Json] {
  {
    "x": Json(r.x * scale),
    "y": Json(r.y * scale),
    "width": Json(r.width * scale),
    "height": Json(r.height * scale),
  }
}

///|
fn draw_rect(
  commands : Array[Json],
  s : UI,
  r : Rect,
  radius : Double,
  fill : String,
  stroke : String,
) -> Unit {
  let fields = rect_json(r, s.scale)
  fields["type"] = Json("rect")
  fields["radius"] = Json(radius * s.scale)
  fields["fill"] = Json(fill)
  if stroke != "" {
    fields["stroke"] = Json(stroke)
    fields["lineWidth"] = Json(s.scale)
  }
  commands.push(Json::object(fields))
}

///|
fn draw_line(
  commands : Array[Json],
  s : UI,
  x1 : Double,
  y1 : Double,
  x2 : Double,
  y2 : Double,
  color : String,
  width : Double,
) -> Unit {
  commands.push(
    Json::object({
      "type": Json("line"),
      "x1": Json(x1 * s.scale),
      "y1": Json(y1 * s.scale),
      "x2": Json(x2 * s.scale),
      "y2": Json(y2 * s.scale),
      "color": Json(color),
      "lineWidth": Json(width * s.scale),
    }),
  )
}

///|
fn draw_text(
  commands : Array[Json],
  s : UI,
  r : Rect,
  text : String,
  color : String,
  size : Double,
  weight : String,
  align : String,
) -> Unit {
  let fields = rect_json(r, s.scale)
  fields["type"] = Json("text")
  fields["text"] = Json(text)
  fields["color"] = Json(color)
  fields["size"] = Json(size * s.scale)
  fields["weight"] = Json(weight)
  fields["align"] = Json(align)
  fields["valign"] = Json("center")
  commands.push(Json::object(fields))
}

///|
fn pad2(n : Int32) -> String {
  if n < 10 {
    "0\{n}"
  } else {
    "\{n}"
  }
}

///|
fn time_label(ms : Double) -> String {
  let seconds = (ms / 1000).to_int()
  "\{pad2(seconds / 60)}:\{pad2(seconds % 60)}"
}

///|
fn tick_label(ms : Double, step : Double) -> String {
  if step >= 1000 {
    return time_label(ms)
  }
  let seconds = (ms / 1000).to_int()
  let sub = ms.to_int() % 1000
  let fraction = if step >= 100 {
    "\{sub / 100}"
  } else if step >= 10 {
    pad2(sub / 10)
  } else if sub < 10 {
    "00\{sub}"
  } else if sub < 100 {
    "0\{sub}"
  } else {
    "\{sub}"
  }
  "\{seconds}.\{fraction}s"
}

///|
fn fine_time(ms : Double) -> String {
  let sub = ms.to_int() % 1000
  let suffix = if sub < 10 {
    "00\{sub}"
  } else if sub < 100 {
    "0\{sub}"
  } else {
    "\{sub}"
  }
  "\{time_label(ms)}.\{suffix}"
}

///|
fn semantic(s : UI, id : String, role : String, value : Json) -> Json {
  let fields = rect_json(control_rect(s, id), s.scale)
  fields["id"] = Json(id)
  fields["role"] = Json(role)
  fields["label"] = Json(control_label(s, id))
  fields["value"] = value
  fields["enabled"] = Json(enabled(s, id))
  fields["focused"] = Json(s.focus == id)
  if role == "slider" {
    fields["min"] = Json(
      if id == "trim-end" {
        s.preview_start + 1
      } else {
        0.0
      },
    )
    fields["max"] = Json(
      if id == "trim-start" {
        s.preview_end - 1
      } else if id == "playhead" {
        s.snapshot.duration - 1
      } else {
        s.snapshot.duration
      },
    )
  }
  Json::object(fields)
}

///|
fn draw_button(
  commands : Array[Json],
  semantics : Array[Json],
  s : UI,
  id : String,
  primary : Bool,
) -> Unit {
  let p = palette(s)
  let active = enabled(s, id)
  let pressed = s.gesture == id && s.hover == id
  let hovered = s.hover == id
  let fill = if !active {
    p.button
  } else if primary {
    if pressed {
      p.primary_pressed
    } else if hovered {
      p.primary_hover
    } else {
      p.primary
    }
  } else if pressed {
    p.button_pressed
  } else if hovered {
    p.button_hover
  } else {
    p.button
  }
  let r = control_rect(s, id)
  if s.focus == id && active {
    draw_rect(
      commands,
      s,
      { x: r.x - 3, y: r.y - 3, width: r.width + 6, height: r.height + 6, },
      12,
      p.background,
      p.focus,
    )
  }
  draw_rect(commands, s, r, 9, fill, "")
  let color = if !active {
    p.disabled
  } else if primary {
    p.on_primary
  } else {
    p.text
  }
  if id == "preview-rate" {
    draw_rate_button_content(
      commands,
      s,
      r,
      id,
      rate_label(s.preview_rate),
      color,
    )
  } else if id == "export" {
    draw_action_icon(commands, s, r, id, color)
  } else {
    draw_icon(commands, s, r, id, color)
  }
  semantics.push(
    semantic(
      s,
      id,
      "button",
      if id == "preview-rate" {
        Json(rate_label(s.preview_rate))
      } else {
        Json::null()
      },
    ),
  )
}

///|
pub fn frame(id : Int32, width : Double, height : Double) -> String {
  @protocol.response(() => {
    let s = session(id)
    if !(width >= 1 && width <= 32768 && height >= 1 && height <= 32768) {
      raise @protocol.InputError(
        "invalid_viewport", "Viewport must be finite and positive",
      )
    }
    if is_project(s) &&
      s.framed &&
      project_clip_target(s, s.gesture) is Some(_) &&
      (
        (width - s.width * s.scale).abs() > 0.001 ||
        (height - s.height * s.scale).abs() > 0.001
      ) {
      // A new native frame changes logical pointer coordinates. Revoke the
      // pending body drag instead of committing it with a different mapping.
      project_cancel(s, [])
    }
    s.scale = @protocol.smaller(1, @protocol.smaller(width / 720, height / 480))
    s.width = width / s.scale
    s.height = height / s.scale
    s.framed = true
    if is_project(s) {
      return project_frame(s)
    }
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
    draw_button(commands, semantics, s, "undo", false)
    draw_button(commands, semantics, s, "redo", false)
    draw_button(commands, semantics, s, "export", true)
    let stage : Rect = {
      x: 24,
      y: 88,
      width: s.width - 48,
      height: s.height - 324,
    }
    draw_rect(commands, s, stage, 12, p.stage, p.border)
    let ratio = s.snapshot.source_width / s.snapshot.source_height
    let vw = @protocol.smaller(stage.width - 2, (stage.height - 2) * ratio)
    let vh = vw / ratio
    let video : Rect = {
      x: stage.x + (stage.width - vw) / 2,
      y: stage.y + (stage.height - vh) / 2,
      width: vw,
      height: vh,
    }
    draw_text(
      commands,
      s,
      { x: 24, y: s.height - 218, width: 200, height: 20, },
      "原片位置  \{fine_time(s.source_time)}",
      p.secondary,
      11,
      "medium",
      "left",
    )
    draw_text(
      commands,
      s,
      { x: 24, y: s.height - 198, width: 200, height: 18, },
      "成片时长  \{fine_time(s.snapshot.output_duration)}",
      p.muted,
      11,
      "regular",
      "left",
    )
    for id in ["start", "backward", "play", "forward", "end"] {
      draw_button(commands, semantics, s, id, false)
    }
    draw_button(commands, semantics, s, "preview-rate", false)

    let panel : Rect = {
      x: 24,
      y: s.height - 156,
      width: s.width - 48,
      height: 132,
    }
    draw_rect(commands, s, panel, 12, p.panel, p.border)
    draw_text(
      commands,
      s,
      { x: 40, y: panel.y + 10, width: 240, height: 20, },
      "原片时间线",
      p.text,
      12,
      "medium",
      "left",
    )
    draw_text(
      commands,
      s,
      { x: s.width - 300, y: panel.y + 10, width: 260, height: 20, },
      if s.gesture == "trim-start" || s.gesture == "trim-end" {
        "裁剪范围 \{fine_time(s.preview_end - s.preview_start)}"
      } else {
        "成片 \{fine_time(s.snapshot.output_duration)}"
      },
      p.secondary,
      12,
      "regular",
      "right",
    )
    let r = track(s)
    let step = @video.timeline_tick_step(s.snapshot.duration, r.width, 72)
    let mut t = 0.0
    let mut ticks = 0
    while t <= s.snapshot.duration && ticks < 500 {
      let x = time_x(s, t)
      draw_line(commands, s, x, r.y - 8, x, r.y - 3, p.tick, 1)
      draw_text(
        commands,
        s,
        {
          x: clamp(x - 26, r.x, r.x + r.width - 52),
          y: r.y - 27,
          width: 52,
          height: 16,
        },
        tick_label(t, step),
        p.muted,
        10,
        "regular",
        "center",
      )
      t = t + step
      ticks = ticks + 1
    }
    draw_rect(commands, s, r, 7, p.track, "")
    let a = time_x(s, s.preview_start)
    let b = time_x(s, s.preview_end)
    draw_rect(
      commands,
      s,
      { x: a, y: r.y, width: b - a, height: r.height, },
      5,
      p.clip,
      p.clip_border,
    )
    for (cut_start, cut_end) in s.snapshot.cuts {
      let left = time_x(s, clamp(cut_start, s.preview_start, s.preview_end))
      let right = time_x(s, clamp(cut_end, s.preview_start, s.preview_end))
      if right > left {
        draw_rect(
          commands,
          s,
          { x: left, y: r.y + 1, width: right - left, height: r.height - 2, },
          0,
          p.cut,
          "",
        )
      }
    }
    if b - a > 130 {
      draw_text(
        commands,
        s,
        { x: a + 14, y: r.y, width: b - a - 28, height: r.height, },
        "视频片段",
        p.text,
        12,
        "medium",
        "left",
      )
    }
    for
      (target, x, value) in [
        ("trim-start", a, s.preview_start),
        ("trim-end", b, s.preview_end),
      ] {
      if s.focus == target && enabled(s, target) {
        draw_rect(
          commands,
          s,
          { x: x - 9, y: r.y - 4, width: 18, height: r.height + 8, },
          7,
          p.panel,
          p.focus,
        )
      }
      draw_rect(
        commands,
        s,
        { x: x - 6, y: r.y - 1, width: 12, height: r.height + 2, },
        4,
        if !enabled(s, target) {
          p.handle_disabled
        } else {
          p.handle
        },
        "",
      )
      draw_line(commands, s, x - 1, r.y + 13, x - 1, r.y + 27, p.handle_grip, 1)
      draw_line(commands, s, x + 2, r.y + 13, x + 2, r.y + 27, p.handle_grip, 1)
      semantics.push(semantic(s, target, "slider", Json(value)))
    }
    let px = time_x(s, s.source_time)
    draw_line(
      commands,
      s,
      px,
      r.y - 12,
      px,
      r.y + r.height + 4,
      p.playhead,
      if s.focus == "playhead" {
        2.5
      } else {
        1.5
      },
    )
    draw_rect(
      commands,
      s,
      { x: px - 4, y: r.y - 15, width: 8, height: 8, },
      2,
      p.playhead,
      "",
    )
    semantics.push(semantic(s, "playhead", "slider", Json(s.source_time)))
    let message = if s.persistence_error != "" { s.persistence_error } else { s.message }
    let message_error = s.persistence_error != "" || s.message_error
    if message != "" {
      draw_text(
        commands,
        s,
        { x: 40, y: s.height - 47, width: s.width - 80, height: 18, },
        message,
        if message_error {
          p.text
        } else {
          p.muted
        },
        11,
        if message_error {
          "medium"
        } else {
          "regular"
        },
        "left",
      )
    }
    if s.rate_menu {
      draw_rate_menu(commands, semantics, s)
    }
    Json::object({
      "ok": Json(true),
      "videoRect": Json::object(rect_json(video, s.scale)),
      "commands": Json::array(commands),
      "semantics": Json::array(semantics),
      "cursor": Json(cursor(s)),
    })
  })
}
