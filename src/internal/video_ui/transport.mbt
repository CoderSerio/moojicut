// Transport operates on the validated edited plan, never source time deltas.
// This is UI navigation only: no document mutation or separate undo history.

///|
let preview_rates : Array[Double] = [0.5, 1, 1.5, 2, 3]

///|
let rate_ids : Array[String] = [
  "rate-0.5", "rate-1", "rate-1.5", "rate-2", "rate-3",
]

///|
fn rate_index(id : String) -> Int32 {
  for i, candidate in rate_ids {
    if candidate == id {
      return i
    }
  }
  -1
}

///|
fn valid_rate(rate : Double) -> Bool {
  preview_rates.contains(rate)
}

///|
fn rate_label(rate : Double) -> String {
  if rate == 0.5 {
    "0.5×"
  } else if rate == 1.5 {
    "1.5×"
  } else {
    "\{rate.to_int()}×"
  }
}

///|
fn source_to_output(snapshot : Snapshot, source : Double) -> Double {
  for segment in snapshot.segments {
    if source < segment.source_start {
      return segment.output_start
    }
    if source < segment.source_end {
      return segment.output_start + source - segment.source_start
    }
  }
  snapshot.output_duration - 1
}

///|
fn output_to_source(snapshot : Snapshot, output : Double) -> Double {
  let time = clamp(output, 0, snapshot.output_duration - 1)
  for segment in snapshot.segments {
    if time < segment.output_end {
      return segment.source_start + time - segment.output_start
    }
  }
  snapshot.retained_end - 1
}

///|
fn navigate(s : UI, effects : Array[Json], target : String) -> Unit {
  if !s.media_ready {
    return
  }
  pause(s, effects)
  let current = source_to_output(s.snapshot, s.source_time)
  let step = @protocol.smaller(s.snapshot.output_duration * 0.01, 5000)
  let output = match target {
    "start" => 0.0
    "end" => s.snapshot.output_duration - 1
    "backward" => current - step
    _ => current + step
  }
  seek(s, effects, output_to_source(s.snapshot, output), false)
  if is_project(s) {
    project_follow_playhead(s)
  }
}

///|
fn close_rate_menu(s : UI) -> Unit {
  if s.rate_menu {
    s.rate_menu = false
    s.focus = "preview-rate"
  }
}

///|
fn rate_menu_key(s : UI, effects : Array[Json], key : String) -> Bool {
  if !s.rate_menu {
    return false
  }
  let current = rate_index(s.focus)
  let index = if current >= 0 { current } else { 0 }
  match key {
    "Escape" => {
      close_rate_menu(s)
      true
    }
    "ArrowUp" | "ArrowLeft" => {
      s.focus = rate_ids[(index + rate_ids.length() - 1) % rate_ids.length()]
      true
    }
    "ArrowDown" | "ArrowRight" => {
      s.focus = rate_ids[(index + 1) % rate_ids.length()]
      true
    }
    "Home" => {
      s.focus = rate_ids[0]
      true
    }
    "End" => {
      s.focus = rate_ids[rate_ids.length() - 1]
      true
    }
    "Space" | "Enter" => {
      activate(s, effects, s.focus)
      true
    }
    "Tab" => {
      close_rate_menu(s)
      false
    }
    _ => false
  }
}
