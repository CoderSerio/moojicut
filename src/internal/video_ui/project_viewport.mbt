// Viewport and gap selection are UI state, never reducer commands/history.

///|
priv struct ProjectGap {
  start : Double
  end : Double
}

///|
fn project_gap_id(g : ProjectGap) -> String {
  "gap:\{g.start.to_int64()}:\{g.end.to_int64()}"
}

///|
fn project_gaps(s : UI) -> Array[ProjectGap] {
  let gaps : Array[ProjectGap] = []
  let mut end = 0.0
  for c in project_clips(s, "video") {
    if c.start > end {
      gaps.push({ start: end, end: c.start, })
    }
    end = @protocol.larger(end, c.start + c.duration)
  }
  // Only bounded output is selectable; core rejects audio crossing a gap.
  if end < s.snapshot.duration * 90 {
    gaps.push({ start: end, end: s.snapshot.duration * 90, })
  }
  gaps
}

///|
fn project_gap_target(s : UI, id : String) -> ProjectGap? {
  if id == "" {
    return None
  }
  for g in project_gaps(s) {
    if project_gap_id(g) == id {
      return Some(g)
    }
  }
  None
}

///|
fn project_min_span(s : UI) -> Double {
  @protocol.smaller(100, s.snapshot.duration)
}

///|
fn project_viewport_sync(s : UI) -> Unit {
  let total = s.snapshot.duration
  // Editing changes the output, not the ruler scale. Keep room to extend a
  // trimmed clip back into its source, including after a slow-motion edit.
  s.viewport_extent = @protocol.larger(
    s.viewport_extent,
    @protocol.larger(total, project(s).source_duration / 90),
  )
  if s.viewport_span <= 0 {
    s.viewport_start = 0
    s.viewport_span = total
  } else if s.viewport_fit {
    s.viewport_span = @protocol.larger(s.viewport_span, total)
  }
  s.viewport_span = clamp(
    s.viewport_span,
    project_min_span(s),
    s.viewport_extent,
  )
  s.viewport_start = clamp(
    s.viewport_start,
    0,
    s.viewport_extent - s.viewport_span,
  )
}

///|
fn project_visible(s : UI, ms : Double) -> Bool {
  ms >= s.viewport_start && ms <= s.viewport_start + s.viewport_span
}

///|
fn project_zoom(s : UI, factor : Double, anchor : Double) -> Unit {
  if s.gesture != "" {
    return
  }
  let old = s.viewport_span
  let span = clamp(old * factor, project_min_span(s), s.viewport_extent)
  let fraction = clamp((anchor - s.viewport_start) / old, 0, 1)
  s.viewport_span = span
  s.viewport_start = clamp(
    anchor - fraction * span,
    0,
    s.viewport_extent - span,
  )
  s.viewport_fit = span >= s.snapshot.duration && s.viewport_start == 0
  s.hover = ""
}

///|
fn project_zoom_action(s : UI, id : String) -> Unit {
  if s.gesture != "" {
    return
  }
  if id == "project-zoom-fit" {
    s.viewport_fit = true
    s.viewport_start = 0
    s.viewport_span = s.snapshot.duration
    project_viewport_sync(s)
  } else {
    let anchor = if project_visible(s, s.source_time) {
      s.source_time
    } else {
      s.viewport_start + s.viewport_span / 2
    }
    project_zoom(s, if id == "project-zoom-in" { 0.5 } else { 2.0 }, anchor)
  }
}

///|
fn project_follow_playhead(s : UI) -> Unit {
  if s.gesture != "" || s.viewport_fit || project_visible(s, s.source_time) {
    return
  }
  s.viewport_start = clamp(
    s.source_time - s.viewport_span * 0.15,
    0,
    s.viewport_extent - s.viewport_span,
  )
}

///|
fn project_scroll(
  s : UI,
  input : Map[String, Json],
) -> Unit raise @protocol.InputError {
  let x = number(input, "x") / s.scale
  let y = number(input, "y") / s.scale
  let dx = number(input, "deltaX")
  let dy = number(input, "deltaY")
  let modifier = boolean(input, "mod")
  ignore(boolean(input, "shift"))
  let precise = match input.get("precise") {
    None => true
    Some(True) => true
    Some(False) => false
    _ =>
      raise @protocol.InputError("invalid_field", "precise must be a boolean")
  }
  let row = project_track(s, "video")
  let area : Rect = {
    x: row.x,
    y: row.y - 24,
    width: row.width,
    height: if s.audio_expanded {
      project_track(s, "audio").y + project_track(s, "audio").height - row.y + 24
    } else {
      54
    },
  }
  if !s.framed ||
    s.crop_mode ||
    s.gesture != "" ||
    s.rate_menu ||
    s.clip_speed_menu ||
    !contains(area, x, y) {
    return
  }
  let delta = if dx != 0 { dx } else { dy }
  if modifier {
    if delta != 0 {
      project_zoom(s, if delta > 0 { 0.8 } else { 1.25 }, project_time(s, x))
    }
  } else {
    s.viewport_fit = false
    let pixels = delta * (if precise { 1.0 } else { 24.0 }) / s.scale
    s.viewport_start = clamp(
      s.viewport_start - pixels / row.width * s.viewport_span,
      0,
      s.viewport_extent - s.viewport_span,
    )
    s.hover = ""
  }
}

///|
fn project_interval_rect(
  s : UI,
  start : Double,
  end : Double,
  kind : String,
) -> Rect {
  let row = project_track(s, kind)
  let x = project_x(s, start)
  {
    x,
    y: row.y,
    width: @protocol.larger(0, project_x(s, end) - x),
    height: row.height,
  }
}

///|
fn project_gap_rect(s : UI, g : ProjectGap) -> Rect {
  project_interval_rect(s, g.start, g.end, "video")
}

///|
fn project_handle_visible(s : UI, id : String) -> Bool {
  match project_selected(s) {
    Some(c) =>
      (c.kind == "video" || s.audio_expanded) &&
      project_visible(
        s,
        (if id == "project-trim-start" {
          c.start
        } else {
          c.start + c.duration
        }) /
        90,
      )
    None => false
  }
}
