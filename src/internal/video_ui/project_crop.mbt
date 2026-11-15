// A crop candidate belongs only to the shared UI until Apply. All coordinates
// are source pixels; the media port continues showing the committed output.

///|
fn project_crop_base(s : UI) -> Rect {
  project(s).crop.unwrap_or({
    x: 0,
    y: 0,
    width: s.snapshot.source_width,
    height: s.snapshot.source_height,
  })
}

///|
fn project_video_rect(s : UI) -> Rect {
  let stage : Rect = {
    x: 24,
    y: 80,
    width: s.width - 48,
    height: s.height - 344,
  }
  let base = project_crop_base(s)
  let ratio = base.width / base.height
  let width = @protocol.smaller(stage.width - 2, (stage.height - 2) * ratio)
  let height = width / ratio
  {
    x: stage.x + (stage.width - width) / 2,
    y: stage.y + (stage.height - height) / 2,
    width,
    height,
  }
}

///|
fn project_crop_rect_json(r : Rect) -> Json {
  Json::object({
    "x": Json(r.x),
    "y": Json(r.y),
    "width": Json(r.width),
    "height": Json(r.height),
  })
}

///|
fn project_crop_activate(s : UI, effects : Array[Json], id : String) -> Bool {
  match id {
    "project-crop" => {
      pause(s, effects)
      close_rate_menu(s)
      project_close_speed(s)
      s.crop_candidate = project_crop_base(s)
      s.crop_saved = s.crop_candidate
      s.crop_mode = true
      s.focus = "project-crop-region"
      s.hover = ""
    }
    "project-crop-region" => s.focus = id
    "project-crop-cancel" => {
      s.crop_mode = false
      s.gesture = ""
      s.focus = "project-crop"
    }
    "project-crop-apply" | "project-crop-reset" => {
      let c = s.crop_candidate
      let full = c.x == 0 &&
        c.y == 0 &&
        c.width == s.snapshot.source_width &&
        c.height == s.snapshot.source_height
      let crop = if id == "project-crop-reset" || full {
        Json::null()
      } else {
        project_crop_rect_json(c)
      }
      s.crop_mode = false
      s.gesture = ""
      s.focus = "project-crop"
      project_command(s, effects, { "type": Json("crop"), "crop": crop })
    }
    _ => return false
  }
  true
}

///|
fn project_crop_point(s : UI, x : Double, y : Double) -> (Double, Double) {
  let r = project_video_rect(s)
  let base = project_crop_base(s)
  (
    base.x +
    (clamp((x - r.x) / r.width, 0, 1) * base.width + 0.5).to_int().to_double(),
    base.y +
    (clamp((y - r.y) / r.height, 0, 1) * base.height + 0.5).to_int().to_double(),
  )
}

///|
fn project_crop_drag(s : UI, x : Double, y : Double) -> Unit {
  let (px, py) = project_crop_point(s, x, y)
  let left = @protocol.smaller(px, s.crop_anchor_x)
  let top = @protocol.smaller(py, s.crop_anchor_y)
  let raw = {
    x: left,
    y: top,
    width: (px - s.crop_anchor_x).abs(),
    height: (py - s.crop_anchor_y).abs(),
  }
  let normalized = @video.normalize_crop(
    s.snapshot.source_width,
    s.snapshot.source_height,
    project_crop_rect_json(raw),
  ) catch {
    _ => {
      s.crop_candidate = raw
      return
    }
  }
  match normalized {
    Object(r) => {
      let width = number(r, "width") catch { _ => return }
      let height = number(r, "height") catch { _ => return }
      s.crop_candidate = { x: left, y: top, width, height, }
    }
    _ => ()
  }
}

///|
fn project_crop_pointer(
  s : UI,
  effects : Array[Json],
  kind : String,
  x : Double,
  y : Double,
) -> Unit {
  if kind == "pointerDown" {
    project_cancel(s, effects)
  }
  s.hover = project_hit(s, x, y)
  if kind == "pointerDown" {
    s.gesture = s.hover
    if s.gesture == "" {
      return
    }
    s.focus = s.gesture
    if s.gesture == "project-crop-region" {
      s.crop_saved = s.crop_candidate
      let (px, py) = project_crop_point(s, x, y)
      s.crop_anchor_x = px
      s.crop_anchor_y = py
      s.crop_candidate = { x: px, y: py, width: 0, height: 0, }
    }
  } else if kind == "pointerMove" {
    if s.gesture == "project-crop-region" {
      project_crop_drag(s, x, y)
    }
  } else {
    let gesture = s.gesture
    if gesture == "project-crop-region" {
      project_crop_drag(s, x, y)
    }
    s.gesture = ""
    if gesture != "project-crop-region" && gesture != "" && gesture == s.hover {
      activate(s, effects, gesture)
    }
  }
}

///|
fn project_crop_key(
  s : UI,
  effects : Array[Json],
  key : String,
  shift : Bool,
) -> Unit {
  project_cancel(s, effects)
  if key == "Escape" {
    ignore(project_crop_activate(s, effects, "project-crop-cancel"))
    return
  }
  if key == "Tab" {
    next_focus(s, shift)
    return
  }
  if key == "Enter" || key == "Space" {
    activate(
      s,
      effects,
      if s.focus == "project-crop-region" {
        "project-crop-apply"
      } else {
        s.focus
      },
    )
    return
  }
  let dx = if key == "ArrowLeft" {
    -1.0
  } else if key == "ArrowRight" {
    1.0
  } else {
    0.0
  }
  let dy = if key == "ArrowUp" {
    -1.0
  } else if key == "ArrowDown" {
    1.0
  } else {
    0.0
  }
  if dx == 0 && dy == 0 {
    return
  }
  let base = project_crop_base(s)
  let c = s.crop_candidate
  if c.width < 2 || c.height < 2 {
    return
  }
  s.focus = "project-crop-region"
  s.crop_candidate = if shift {
    {
      x: c.x,
      y: c.y,
      width: clamp(c.width + dx * 2, 2, base.x + base.width - c.x),
      height: clamp(c.height + dy * 2, 2, base.y + base.height - c.y),
    }
  } else {
    {
      x: clamp(c.x + dx, base.x, base.x + base.width - c.width),
      y: clamp(c.y + dy, base.y, base.y + base.height - c.height),
      width: c.width,
      height: c.height,
    }
  }
}

///|
fn project_crop_overlay(s : UI) -> Array[Json] {
  let commands : Array[Json] = []
  if !s.crop_mode {
    return commands
  }
  let r = project_video_rect(s)
  let b = project_crop_base(s)
  let c = s.crop_candidate
  let x = r.x + (c.x - b.x) / b.width * r.width
  let y = r.y + (c.y - b.y) / b.height * r.height
  let width = c.width / b.width * r.width
  let height = c.height / b.height * r.height
  // Opaque outer masks use existing portable rect commands. The border sits
  // in a separate generic command plane above the native video surface.
  for
    mask in [
      { x: r.x, y: r.y, width: r.width, height: y - r.y, },
      {
        x: r.x,
        y: y + height,
        width: r.width,
        height: r.y + r.height - y - height,
      },
      { x: r.x, y, width: x - r.x, height, },
      { x: x + width, y, width: r.x + r.width - x - width, height, },
    ] {
    if mask.width > 0 && mask.height > 0 {
      draw_rect(commands, s, mask, 0, "#000000", "")
    }
  }
  if width > 0 && height > 0 {
    let color = palette(s).focus
    for
      (x1, y1, x2, y2) in [
        (x, y, x + width, y),
        (x, y + height, x + width, y + height),
        (x, y, x, y + height),
        (x + width, y, x + width, y + height),
      ] {
      draw_line(commands, s, x1, y1, x2, y2, color, 2)
    }
  }
  commands
}
