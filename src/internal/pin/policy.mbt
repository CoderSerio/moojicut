// Platform profiles: 1 macOS, 2 Windows, 3 Linux. These intentionally retain
// existing host differences, rather than changing behavior during extraction.

///|
fn finite(value : Double) -> Bool {
  value > -1.0 / 0.0 && value < 1.0 / 0.0
}

///|
fn smaller(a : Double, b : Double) -> Double {
  if a < b {
    a
  } else {
    b
  }
}

///|
fn larger(a : Double, b : Double) -> Double {
  if a > b {
    a
  } else {
    b
  }
}

///|
fn valid_platform(platform : Int32) -> Bool {
  platform >= 1 && platform <= 3
}

///|
fn dimensions_valid(
  width : Double,
  height : Double,
  work_width : Double,
  work_height : Double,
) -> Bool {
  finite(width) &&
  finite(height) &&
  finite(work_width) &&
  finite(work_height) &&
  width > 0 &&
  height > 0 &&
  work_width > 0 &&
  work_height > 0
}

///|
/// Zero means invalid geometry/request: hosts keep the current window intact.
pub fn scale(
  platform : Int32,
  requested : Double,
  width : Double,
  height : Double,
  work_width : Double,
  work_height : Double,
) -> Double {
  if !valid_platform(platform) ||
    !finite(requested) ||
    !dimensions_valid(width, height, work_width, work_height) {
    return 0
  }
  let margin = if platform == 1 { 0.95 } else { 1.0 }
  let maximum = smaller(
    8,
    smaller(work_width * margin / width, work_height * margin / height),
  )
  let minimum = smaller(0.1, maximum)
  larger(minimum, smaller(maximum, requested))
}

///|
/// macOS's unanchored initial placement fits within 75% of the work area.
/// Anchored capture rectangles bypass this sizing rule in each host.
pub fn initial_scale(
  width : Double,
  height : Double,
  work_width : Double,
  work_height : Double,
) -> Double {
  if !dimensions_valid(width, height, work_width, work_height) {
    return 0
  }
  smaller(1, smaller(work_width * 0.75 / width, work_height * 0.75 / height))
}

///|
pub fn zoom_step(value : Double, direction : Int32) -> Double {
  if !finite(value) {
    return 0
  }
  let factor = if direction > 0 {
    1.1
  } else if direction < 0 {
    1 / 1.1
  } else {
    1.0
  }
  let result = value * factor
  if finite(result) {
    result
  } else {
    0
  }
}

///|
/// Windows keeps its byte alpha domain and 26-unit step. Other hosts use unit
/// opacity and 0.1 increments. Nonfinite values recover to the visible default.
pub fn opacity(platform : Int32, value : Double, direction : Int32) -> Double {
  if !valid_platform(platform) {
    return 0
  }
  let maximum = if platform == 2 { 255.0 } else { 1.0 }
  let minimum = if platform == 2 { 26.0 } else { 0.1 }
  if !finite(value) {
    return maximum
  }
  let delta = if direction > 0 {
    minimum
  } else if direction < 0 {
    -minimum
  } else {
    0.0
  }
  let result = larger(minimum, smaller(maximum, value + delta))
  if platform == 2 {
    @double.floor(result)
  } else {
    result
  }
}

///|
/// 0=no change, 1=show selected, 2=hide selected, 3=show hidden group,
/// 4=hide group, 5=recovery key unavailable. Selection/focus effects stay native.
pub fn visibility_action(
  platform : Int32,
  has_selected : Int32,
  selected_hidden : Int32,
  selected_passthrough : Int32,
  any_hidden : Int32,
  recovery_available : Int32,
) -> Int32 {
  if !valid_platform(platform) {
    return 0
  }
  // Windows requires its registered recovery key even when restoring. Linux's
  // local action remains available; its X11 global handler checks registration.
  if platform == 2 && recovery_available == 0 {
    return 5
  }
  if has_selected != 0 && selected_passthrough != 0 {
    return 0
  }
  if has_selected != 0 && selected_hidden != 0 {
    return 1
  }
  if has_selected == 0 && any_hidden != 0 {
    return 3
  }
  if platform == 1 && recovery_available == 0 {
    return 5
  }
  if has_selected != 0 {
    2
  } else {
    4
  }
}

///|
/// Apply a decision to one pin. Action 6 is explicit "restore hidden pins";
/// Linux preserves its legacy restore-all behavior even for pass-through pins.
pub fn hidden_after(
  platform : Int32,
  action : Int32,
  hidden : Int32,
  passthrough : Int32,
  target : Int32,
) -> Int32 {
  let unchanged = if hidden != 0 { 1 } else { 0 }
  if !valid_platform(platform) {
    return unchanged
  }
  match action {
    1 | 2 =>
      if target == 0 || passthrough != 0 {
        unchanged
      } else if action == 2 {
        1
      } else {
        0
      }
    3 | 4 =>
      if passthrough != 0 && platform != 2 {
        unchanged
      } else if action == 4 {
        1
      } else {
        0
      }
    6 => if passthrough != 0 && platform != 3 { unchanged } else { 0 }
    _ => unchanged
  }
}
