///|
fn project_close_speed(s : UI) -> Unit {
  if s.clip_speed_menu {
    s.clip_speed_menu = false
    s.focus = "project-speed"
  }
}

///|
fn project_cancel(s : UI, effects : Array[Json]) -> Unit {
  let gesture = s.gesture
  s.gesture = ""
  if gesture == "project-crop-region" {
    s.crop_candidate = s.crop_saved
  }
  project_sync_selection(s)
  if gesture == "playhead" {
    seek(s, effects, s.saved_time, false)
  }
}

///|
fn project_command(
  s : UI,
  effects : Array[Json],
  op : Map[String, Json],
) -> Unit {
  pause(s, effects)
  project_close_speed(s)
  command(effects, Json::object(op))
}

///|
fn project_activate(s : UI, effects : Array[Json], target : String) -> Bool {
  if project_crop_activate(s, effects, target) {
    return true
  }
  if target == "project-mute" {
    project_command(s, effects, {
      "type": Json("mute"),
      "muted": Json(!project(s).muted),
    })
    return true
  }
  if target != "project-speed" && clip_rate_index(target) < 0 {
    project_close_speed(s)
  }
  if target == "project-zoom-in" ||
    target == "project-zoom-out" ||
    target == "project-zoom-fit" {
    close_rate_menu(s)
    project_zoom_action(s, target)
    s.focus = target
    return true
  }
  if project_gap_target(s, target) is Some(_) {
    close_rate_menu(s)
    s.selected_gap = target
    s.focus = target
    return true
  }
  if target == "project-remove" {
    project_remove(s, effects, false)
    return true
  }
  match project_clip_target(s, target) {
    Some(c) => {
      project_close_speed(s)
      close_rate_menu(s)
      project_select(s, c.id)
      s.focus = target
      return true
    }
    None => ()
  }
  if target == "project-audio-toggle" {
    project_close_speed(s)
    s.audio_expanded = !s.audio_expanded
    if !s.audio_expanded {
      match project_selected(s) {
        Some(c) if c.kind == "audio" =>
          project_select(s, project_clips(s, "video")[0].id)
        _ => ()
      }
    }
    s.focus = target
    return true
  }
  if target == "preview-rate" {
    project_close_speed(s)
    return false
  }
  if target == "project-speed" {
    close_rate_menu(s)
    if s.clip_speed_menu {
      project_close_speed(s)
    } else {
      s.clip_speed_menu = true
      s.focus = clip_rate_ids[1]
      match project_selected(s) {
        Some(c) =>
          for i, rate in preview_rates {
            if (clip_rate(c) - rate).abs() < 0.01 &&
              enabled(s, clip_rate_ids[i]) {
              s.focus = clip_rate_ids[i]
            }
          }
        None => ()
      }
    }
    return true
  }
  let selected = match project_selected(s) {
    Some(c) => c
    None => return false
  }
  let index = clip_rate_index(target)
  if index >= 0 {
    let num = match index {
      0 => 1
      2 => 3
      3 => 2
      4 => 3
      _ => 1
    }
    let den = if index == 0 || index == 2 { 2 } else { 1 }
    project_command(s, effects, {
      "type": Json("setSpeed"),
      "clipId": Json(selected.id),
      "rate": Json::object({ "num": Json(num), "den": Json(den) }),
      "linked": Json(true),
      "ripple": Json(project_ripple(selected)),
    })
    return true
  }
  match target {
    "project-split" => {
      let ticks = (s.source_time * 90 / 3000 + 0.5).to_int().to_double() * 3000
      project_command(s, effects, {
        "type": Json("split"),
        "clipId": Json(selected.id),
        "atTicks": Json(ticks),
      })
    }
    "project-unlink" =>
      project_command(s, effects, {
        "type": Json("unlink"),
        "clipId": Json(selected.id),
      })
    "project-move-earlier" | "project-move-later" => {
      let clips = project_clips(s, "video")
      let at = project_video_index(s, selected.id)
      let before = if target == "project-move-earlier" {
        Json(clips[at - 1].id)
      } else if at + 2 < clips.length() {
        Json(clips[at + 2].id)
      } else {
        Json::null()
      }
      project_command(s, effects, {
        "type": Json("move"),
        "clipId": Json(selected.id),
        "beforeClipId": before,
      })
    }
    "project-offset-earlier" | "project-offset-later" => {
      let requested = @protocol.smaller(
        s.snapshot.output_duration * 0.01 * 90,
        450000,
      )
      let step = @protocol.larger(
        3000,
        (requested / 3000 + 0.5).to_int().to_double() * 3000,
      )
      let delta = if target == "project-offset-earlier" {
        -@protocol.smaller(selected.start, step)
      } else {
        step
      }
      project_command(s, effects, {
        "type": Json("offset"),
        "clipId": Json(selected.id),
        "deltaTicks": Json(delta),
      })
    }
    "project-trim-start" | "project-trim-end" => s.focus = target
    _ => return false
  }
  true
}

///|
fn project_update_trim(s : UI, x : Double) -> Unit {
  let c = match project_selected(s) {
    Some(c) => c
    None => return
  }
  let rate = clip_rate(c)
  if x == s.clip_drag_x {
    s.clip_trim_start = c.source_start
    s.clip_trim_end = c.source_end
    return
  }
  let delta = (x - s.clip_drag_x) /
    project_track(s, "video").width *
    s.viewport_span *
    90 *
    rate
  let minimum_span = @protocol.larger(3000, rate * 3000)
  let limit = project(s).source_duration
  if s.gesture == "project-trim-start" {
    let maximum = @protocol.larger(
      0,
      ((c.source_end - minimum_span) / 3000).to_int().to_double() * 3000,
    )
    let candidate = clamp(c.source_start + delta, 0, maximum)
    s.clip_trim_start = clamp(
      (candidate / 3000 + 0.5).to_int().to_double() * 3000,
      0,
      maximum,
    )
  } else if s.gesture == "project-trim-end" {
    let minimum = ((c.source_start + minimum_span + 2999) / 3000)
      .to_int()
      .to_double() *
      3000
    let candidate = clamp(c.source_end + delta, minimum, limit)
    s.clip_trim_end = clamp(
      (candidate / 3000 + 0.5).to_int().to_double() * 3000,
      minimum,
      limit,
    )
  }
}

///|
fn project_pointer(
  s : UI,
  effects : Array[Json],
  kind : String,
  x : Double,
  y : Double,
) -> Unit {
  if s.crop_mode {
    project_crop_pointer(s, effects, kind, x, y)
    return
  }
  if kind == "pointerDown" {
    cancel(s, effects)
  }
  s.hover = project_hit(s, x, y)
  if kind == "pointerDown" {
    if s.hover == "" {
      if s.rate_menu && !contains(rate_menu_rect(s), x, y) {
        close_rate_menu(s)
      }
      if s.clip_speed_menu && !contains(project_speed_rect(s), x, y) {
        project_close_speed(s)
      }
    }
    s.gesture = s.hover
    if s.gesture == "" {
      return
    }
    s.focus = s.gesture
    s.saved_time = s.source_time
    match project_clip_target(s, s.gesture) {
      Some(c) => project_select(s, c.id)
      None => ()
    }
    if s.gesture == "project-trim-start" || s.gesture == "project-trim-end" {
      pause(s, effects)
      s.clip_drag_x = x
      project_sync_selection(s)
    } else if s.gesture == "playhead" {
      pause(s, effects)
      seek(s, effects, project_time(s, x), false)
    }
  } else if kind == "pointerMove" {
    if s.gesture == "project-trim-start" || s.gesture == "project-trim-end" {
      project_update_trim(s, x)
    } else if s.gesture == "playhead" {
      seek(s, effects, project_time(s, x), false)
    }
  } else {
    let gesture = s.gesture
    if gesture == "project-trim-start" || gesture == "project-trim-end" {
      project_update_trim(s, x)
      s.gesture = ""
      match project_selected(s) {
        Some(c) =>
          if s.clip_trim_start != c.source_start ||
            s.clip_trim_end != c.source_end {
            project_command(s, effects, {
              "type": Json("trim"),
              "clipId": Json(c.id),
              "sourceStartTicks": Json(s.clip_trim_start),
              "sourceEndTicks": Json(s.clip_trim_end),
              "ripple": Json(project_ripple(c)),
            })
            seek(s, effects, c.start / 90, false)
          }
        None => ()
      }
      project_sync_selection(s)
    } else {
      s.gesture = ""
      if gesture == "playhead" {
        seek(s, effects, project_time(s, x), false)
      } else if gesture != "" && gesture == s.hover {
        activate(s, effects, gesture)
      }
    }
  }
}

///|
fn project_keyboard(
  s : UI,
  effects : Array[Json],
  key : String,
  modifier : Bool,
  shift : Bool,
) -> Bool {
  if s.crop_mode {
    project_crop_key(s, effects, key, shift)
    return true
  }
  if key == "Escape" {
    cancel(s, effects)
    close_rate_menu(s)
    project_close_speed(s)
    return true
  }
  if s.clip_speed_menu {
    match key {
      "ArrowLeft" | "ArrowUp" => project_rate_focus(s, -1, false)
      "ArrowRight" | "ArrowDown" => project_rate_focus(s, 1, false)
      "Home" => project_rate_focus(s, 1, true)
      "End" => project_rate_focus(s, -1, true)
      "Enter" | "Space" => activate(s, effects, s.focus)
      "Tab" => {
        project_close_speed(s)
        return false
      }
      _ =>
        if modifier {
          project_close_speed(s)
          return false
        }
    }
    return true
  }
  if s.focus == "project-speed" && (key == "ArrowDown" || key == "Space") {
    activate(s, effects, "project-speed")
    return true
  }
  if key == "Delete" || key == "Backspace" {
    cancel(s, effects)
    if enabled(s, "project-remove") {
      project_remove(s, effects, shift)
    }
    return true
  }
  if (s.focus == "project-trim-start" || s.focus == "project-trim-end") &&
    (key == "ArrowLeft" || key == "ArrowRight") {
    if !enabled(s, s.focus) {
      return true
    }
    let c = match project_selected(s) {
      Some(c) => c
      None => return true
    }
    let start = s.focus == "project-trim-start"
    s.gesture = s.focus
    s.clip_drag_x = project_x(
      s,
      if start {
        c.start
      } else {
        c.start + c.duration
      },
    )
    let direction = if key == "ArrowLeft" { -1.0 } else { 1.0 }
    let pixels = project_track(s, "video").width *
      (if shift { 30000.0 } else { 3000.0 }) /
      (s.viewport_span * 90)
    project_update_trim(s, s.clip_drag_x + direction * pixels)
    s.gesture = ""
    if c.source_start != s.clip_trim_start || c.source_end != s.clip_trim_end {
      project_command(s, effects, {
        "type": Json("trim"),
        "clipId": Json(c.id),
        "sourceStartTicks": Json(s.clip_trim_start),
        "sourceEndTicks": Json(s.clip_trim_end),
        "ripple": Json(project_ripple(c)),
      })
      seek(s, effects, c.start / 90, false)
    }
    project_sync_selection(s)
    return true
  }
  if !s.rate_menu && (key == "ArrowLeft" || key == "ArrowRight") {
    cancel(s, effects)
    if s.media_ready {
      pause(s, effects)
      s.focus = "playhead"
      let direction = if key == "ArrowLeft" { -1.0 } else { 1.0 }
      let frame = (s.source_time * 90 / 3000 + 0.5).to_int().to_double()
      seek(
        s,
        effects,
        (frame + direction * (if shift { 10.0 } else { 1.0 })) * 3000 / 90,
        false,
      )
      project_follow_playhead(s)
    }
    return true
  }
  false
}

///|
fn project_ripple(c : ProjectClip) -> Bool {
  c.kind != "audio" || c.link_group != ""
}

///|
fn project_rate_focus(s : UI, direction : Int32, edge : Bool) -> Unit {
  let count = clip_rate_ids.length()
  let old = clip_rate_index(s.focus)
  let mut index = if edge {
    if direction > 0 {
      count - 1
    } else {
      0
    }
  } else if old >= 0 {
    old
  } else {
    0
  }
  for _ in 0..<count {
    index = (index + count + direction) % count
    if enabled(s, clip_rate_ids[index]) {
      s.focus = clip_rate_ids[index]
      return
    }
  }
}

///|
fn project_remove(s : UI, effects : Array[Json], ripple : Bool) -> Unit {
  match project_gap_target(s, s.selected_gap) {
    Some(g) =>
      project_command(s, effects, {
        "type": Json("removeGap"),
        "startTicks": Json(g.start),
        "endTicks": Json(g.end),
      })
    None =>
      match project_selected(s) {
        Some(c) =>
          project_command(s, effects, {
            "type": Json("remove"),
            "clipId": Json(c.id),
            "ripple": Json(ripple && project_ripple(c)),
          })
        None => ()
      }
  }
}
