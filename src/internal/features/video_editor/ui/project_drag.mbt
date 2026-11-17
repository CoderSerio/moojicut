///|
fn project_moves_with(c : ProjectClip, selected : ProjectClip) -> Bool {
  c.id == selected.id ||
  (selected.link_group != "" && c.link_group == selected.link_group)
}

///|
fn project_move_allowed(s : UI, selected : ProjectClip, start : Double) -> Bool {
  if start < 0 || start + selected.duration > 54432000000 {
    return false
  }
  for moving in project(s).clips {
    if moving.kind != "video" || !project_moves_with(moving, selected) {
      continue
    }
    let a = moving.start + start - selected.start
    let b = a + moving.duration
    for other in project_clips(s, "video") {
      if !project_moves_with(other, selected) &&
        a < other.start + other.duration &&
        b > other.start {
        return false
      }
    }
  }
  true
}

///|
fn project_update_move(s : UI, effects : Array[Json], x : Double) -> Unit {
  let c = match project_clip_target(s, s.gesture) {
    Some(c) => c
    None => return
  }
  if !project_editable(s) {
    return
  }
  if !s.clip_drag_active && (x - s.clip_drag_x).abs() < 3 {
    return
  }
  if !s.clip_drag_active {
    pause(s, effects)
    s.clip_drag_active = true
    s.message = ""
    s.message_error = false
  }
  // Fixed pointer-down mapping, without project_time's viewport clamp. Dragging
  // beyond the right edge can extend output; fitting happens after commit.
  let raw = clamp(
    c.start + (x - s.clip_drag_x) * s.clip_drag_ticks_per_pixel,
    0,
    54432000000 - c.duration,
  )
  let rounded = @double.floor(raw / 3000 + 0.5) * 3000
  let mut candidate = rounded
  let mut distance = 6.0 * s.clip_drag_ticks_per_pixel
  let anchors : Array[Double] = [0]
  for other in project_clips(s, c.kind) {
    if project_moves_with(other, c) {
      continue
    }
    anchors.push(other.start)
    anchors.push(other.start + other.duration)
    anchors.push(other.start - c.duration)
    anchors.push(other.start + other.duration - c.duration)
  }
  for anchor in anchors {
    let gap = (anchor - raw).abs()
    if gap <= distance && project_move_allowed(s, c, anchor) {
      candidate = anchor
      distance = gap
    }
  }
  s.clip_move_start = candidate
  s.clip_move_valid = project_move_allowed(s, c, candidate)
}

///|
fn project_display_start(s : UI, c : ProjectClip) -> Double {
  if s.clip_drag_active {
    match project_selected(s) {
      Some(selected) if project_moves_with(c, selected) =>
        return c.start + s.clip_move_start - selected.start
      _ => ()
    }
  }
  c.start
}
