///|
fn command(effects : Array[Json], value : Json) -> Unit {
  effects.push(Json::object({ "type": Json("command"), "command": value }))
}

///|
fn seek(s : UI, effects : Array[Json], ms : Double, preview : Bool) -> Unit {
  s.source_time = clamp(ms, 0, s.snapshot.duration - 1)
  if is_project(s) {
    effects.push(
      Json::object({
        "type": Json("seekOutput"),
        "outputMs": Json(s.source_time),
        "preview": Json(false),
      }),
    )
  } else {
    effects.push(
      Json::object({
        "type": Json("seek"),
        "sourceMs": Json(s.source_time),
        "preview": Json(preview),
      }),
    )
  }
}

///|
fn pause(s : UI, effects : Array[Json]) -> Unit {
  if s.playing {
    s.playing = false
    effects.push(Json::object({ "type": Json("play"), "playing": Json(false) }))
  }
}

///|
fn restore(s : UI, effects : Array[Json], ms : Double) -> Unit {
  s.source_time = clamp(ms, 0, s.snapshot.duration - 1)
  effects.push(
    Json::object({
      "type": Json("restorePreview"),
      "sourceMs": Json(s.source_time),
    }),
  )
}

///|
fn cancel(s : UI, effects : Array[Json]) -> Unit {
  if is_project(s) {
    project_cancel(s, effects)
    return
  }
  let gesture = s.gesture
  s.gesture = ""
  s.preview_start = s.snapshot.start
  s.preview_end = s.snapshot.end
  if gesture == "trim-start" || gesture == "trim-end" {
    restore(s, effects, s.saved_time)
  } else if gesture == "playhead" {
    seek(s, effects, s.saved_time, false)
  }
}

///|
fn trim_command(start : Double, end : Double) -> Json {
  Json::object({
    "type": Json("trim"),
    "trim": Json::object({ "startMs": Json(start), "endMs": Json(end) }),
  })
}

///|
fn activate(s : UI, effects : Array[Json], target : String) -> Unit {
  if !enabled(s, target) {
    return
  }
  if is_project(s) && project_activate(s, effects, target) {
    return
  }
  let rate = rate_index(target)
  if rate >= 0 {
    s.preview_rate = preview_rates[rate]
    close_rate_menu(s)
    effects.push(
      Json::object({ "type": Json("previewRate"), "rate": Json(s.preview_rate) }),
    )
    return
  }
  if target != "preview-rate" {
    close_rate_menu(s)
  }
  s.focus = target
  match target {
    "preview-rate" =>
      if s.rate_menu {
        close_rate_menu(s)
      } else {
        s.rate_menu = true
        for i, value in preview_rates {
          if value == s.preview_rate {
            s.focus = rate_ids[i]
          }
        }
      }
    "start" | "backward" | "forward" | "end" => navigate(s, effects, target)
    "play" => {
      // The last playable frame can precede trim.end when the tail is cut.
      // Request a seek before play; the core/host resolves leading cuts.
      if !s.playing && s.source_time >= s.snapshot.retained_end - 1 {
        seek(s, effects, s.snapshot.start, false)
      }
      s.playing = !s.playing
      effects.push(
        Json::object({ "type": Json("play"), "playing": Json(s.playing) }),
      )
    }
    "undo" | "redo" => command(effects, Json::object({ "type": Json(target) }))
    "export" => {
      s.export_busy = true
      s.message = "正在保存视频…"
      s.message_error = false
      effects.push(Json::object({ "type": Json("export") }))
    }
    _ => ()
  }
}

///|
fn update_drag(s : UI, effects : Array[Json], x : Double) -> Unit {
  let r = track(s)
  let candidate = @video.timeline_time_for_x(
    x,
    s.snapshot.duration,
    r.x,
    r.width,
  )
  match s.gesture {
    "trim-start" | "trim-end" => {
      let is_start = s.gesture == "trim-start"
      let value = @video.timeline_trim_boundary(
        if is_start {
          0
        } else {
          1
        },
        candidate,
        s.snapshot.start,
        s.snapshot.end,
        s.snapshot.duration,
        1,
      )
      if value.is_nan() {
        return
      }
      if is_start {
        s.preview_start = value
      } else {
        s.preview_end = value
      }
      seek(s, effects, if is_start { value } else { value - 1 }, true)
    }
    "playhead" => seek(s, effects, candidate, false)
    _ => ()
  }
}

///|
fn next_focus(s : UI, backwards : Bool) -> Unit {
  let targets : Array[String] = if is_project(s) {
    project_focus_targets(s)
  } else {
    [
      "undo", "redo", "export", "start", "backward", "play", "forward", "end", "preview-rate",
      "trim-start", "trim-end", "playhead",
    ]
  }
  let mut index = 0
  for i, target in targets {
    if target == s.focus {
      index = i
    }
  }
  for _ in 0..<targets.length() {
    index = (index + (if backwards { targets.length() - 1 } else { 1 })) %
      targets.length()
    if enabled(s, targets[index]) {
      s.focus = targets[index]
      return
    }
  }
}

///|
fn keyboard(
  s : UI,
  effects : Array[Json],
  key : String,
  modifier : Bool,
  shift : Bool,
) -> Unit {
  if is_project(s) && project_keyboard(s, effects, key, modifier, shift) {
    return
  }
  if key == "Escape" {
    cancel(s, effects)
    close_rate_menu(s)
    return
  }
  // A key action first ends the current pointer transaction, so one gesture
  // cannot accidentally commit again on a later mouseUp.
  cancel(s, effects)
  if rate_menu_key(s, effects, key) {
    return
  }
  if s.focus == "preview-rate" && (key == "ArrowDown" || key == "ArrowUp") {
    activate(s, effects, "preview-rate")
    return
  }
  if key == "Tab" {
    next_focus(s, shift)
    return
  }
  if modifier && (key == "z" || key == "Z") {
    activate(s, effects, if shift { "redo" } else { "undo" })
    return
  }
  if key == "Space" {
    activate(
      s,
      effects,
      if s.focus == "preview-rate" {
        "preview-rate"
      } else {
        "play"
      },
    )
    return
  }
  if key == "Enter" {
    activate(s, effects, s.focus)
    return
  }
  if key != "ArrowLeft" && key != "ArrowRight" && key != "Home" && key != "End" {
    return
  }
  let step = if shift { 1000.0 } else { 33.0 }
  let direction = if key == "ArrowLeft" { -1.0 } else { 1.0 }
  if s.focus == "trim-start" || s.focus == "trim-end" {
    if !enabled(s, s.focus) {
      return
    }
    let is_start = s.focus == "trim-start"
    let old = if is_start { s.snapshot.start } else { s.snapshot.end }
    let candidate = if key == "Home" {
      0.0
    } else if key == "End" {
      s.snapshot.duration
    } else {
      old + direction * step
    }
    let value = @video.timeline_trim_boundary(
      if is_start {
        0
      } else {
        1
      },
      candidate,
      s.snapshot.start,
      s.snapshot.end,
      s.snapshot.duration,
      1,
    )
    if value.is_nan() || value == old {
      return
    }
    pause(s, effects)
    command(
      effects,
      trim_command(
        if is_start {
          value
        } else {
          s.snapshot.start
        },
        if is_start {
          s.snapshot.end
        } else {
          value
        },
      ),
    )
    restore(s, effects, if is_start { value } else { value - 1 })
  } else {
    if !enabled(s, "playhead") {
      return
    }
    s.focus = "playhead"
    if key == "Home" || key == "End" {
      navigate(s, effects, if key == "Home" { "start" } else { "end" })
    } else {
      pause(s, effects)
      seek(
        s,
        effects,
        output_to_source(
          s.snapshot,
          source_to_output(s.snapshot, s.source_time) + direction * step,
        ),
        false,
      )
    }
  }
}

///|
pub fn event(id : Int32, event_json : String) -> String {
  @protocol.response(() => {
    let s = session(id)
    let input = ui_input_object(event_json)
    let kind = string(input, "type")
    let effects : Array[Json] = []
    match kind {
      "appearance" => {
        let mode = string(input, "mode")
        if mode != "dark" && mode != "light" {
          raise @protocol.InputError(
            "invalid_appearance", "Appearance must be dark or light",
          )
        }
        s.appearance = mode
      }
      "snapshot" => {
        let next = decode_snapshot(@protocol.object_field(input, "snapshot"))
        cancel(s, effects)
        s.snapshot = next
        s.crop_mode = false
        project_sync_selection(s)
        s.clip_speed_menu = false
        s.preview_start = next.start
        s.preview_end = next.end
        s.source_time = clamp(s.source_time, 0, next.duration - 1)
        if !enabled(s, s.focus) {
          s.focus = "play"
        }
      }
      "previewRateStatus" => {
        let rate = number(input, "rate")
        let message = string(input, "message")
        let failed = boolean(input, "error")
        if !valid_rate(rate) {
          raise @protocol.InputError("invalid_rate", "Unsupported preview rate")
        }
        // Validate every field before correcting optimistic local UI state.
        s.preview_rate = rate
        s.message = message
        s.message_error = failed
      }
      "playback" => {
        let time = number(
          input,
          if is_project(s) {
            "outputMs"
          } else {
            "sourceMs"
          },
        )
        let playing = boolean(input, "playing")
        if s.gesture == "" && s.media_ready {
          s.source_time = clamp(time, 0, s.snapshot.duration - 1)
          s.playing = playing
          if is_project(s) && playing {
            project_follow_playhead(s)
          }
        }
      }
      "error" => {
        let message = string(input, "message")
        cancel(s, effects)
        s.crop_mode = false
        s.message = message
        s.message_error = true
      }
      "waveform" => receive_waveform(s, input)
      "mediaStatus" => {
        let ready = boolean(input, "ready")
        let message = string(input, "message")
        s.media_ready = ready
        s.message = message
        s.message_error = !ready
        if !ready {
          s.crop_mode = false
          // The host already invalidated the media plan. Do not request
          // restorePreview here: that could re-enter the failing sync path.
          s.playing = false
          close_rate_menu(s)
          s.clip_speed_menu = false
          project_sync_selection(s)
          s.gesture = ""
          s.clip_drag_active = false
          s.hover = ""
          s.preview_start = s.snapshot.start
          s.preview_end = s.snapshot.end
        }
      }
      "exportStatus" => {
        let busy = boolean(input, "busy")
        let message = string(input, "message")
        let is_error = boolean(input, "error")
        if busy {
          cancel(s, effects)
          s.crop_mode = false
        }
        s.export_busy = busy
        s.message = message
        s.message_error = is_error
      }
      "cancel" => {
        cancel(s, effects)
        s.crop_mode = false
        close_rate_menu(s)
        s.clip_speed_menu = false
        s.hover = ""
      }
      "activate" => {
        let target = string(input, "id")
        cancel(s, effects)
        activate(s, effects, target)
      }
      "key" => {
        let key = string(input, "key")
        let modifier = boolean(input, "mod")
        let shift = boolean(input, "shift")
        keyboard(s, effects, key, modifier, shift)
      }
      "scroll" => if is_project(s) { project_scroll(s, input) }
      "pointerDown" | "pointerMove" | "pointerUp" => {
        let x = number(input, "x") / s.scale
        let y = number(input, "y") / s.scale
        if !s.framed {
          raise @protocol.InputError(
            "missing_viewport", "Call frame before pointer input",
          )
        }
        if is_project(s) {
          project_pointer(s, effects, kind, x, y)
        } else {
          if kind == "pointerDown" {
            cancel(s, effects)
          }
          s.hover = hit(s, x, y)
          if kind == "pointerDown" {
            if s.rate_menu &&
              s.hover == "" &&
              !contains(rate_menu_rect(s), x, y) {
              close_rate_menu(s)
            }
            s.gesture = s.hover
            if s.gesture != "" {
              s.focus = s.gesture
              s.saved_time = s.source_time
            }
            if s.gesture == "trim-start" ||
              s.gesture == "trim-end" ||
              s.gesture == "playhead" {
              pause(s, effects)
              update_drag(s, effects, x)
            }
          } else if kind == "pointerMove" {
            update_drag(s, effects, x)
          } else {
            let gesture = s.gesture
            update_drag(s, effects, x)
            s.gesture = ""
            if gesture == "trim-start" || gesture == "trim-end" {
              let start = s.preview_start
              let end = s.preview_end
              if start != s.snapshot.start || end != s.snapshot.end {
                command(effects, trim_command(start, end))
              }
              restore(s, effects, s.source_time)
              s.preview_start = s.snapshot.start
              s.preview_end = s.snapshot.end
            } else if gesture != "" && gesture == s.hover {
              activate(s, effects, gesture)
            }
          }
        }
      }
      _ =>
        raise @protocol.InputError("invalid_event", "Unknown shared UI event")
    }
    Json::object({
      "ok": Json(true),
      "effects": Json::array(effects),
      "capture": Json(s.gesture != ""),
      "cursor": Json(cursor(s)),
    })
  })
}
