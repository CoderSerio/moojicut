// Stateless timeline geometry. Times use milliseconds, independent of any
// document, recording controller, media decoder or native view framework.

///|
fn timeline_finite(value : Double) -> Bool {
  value > -1.0 / 0.0 && value < 1.0 / 0.0
}

///|
fn timeline_clamp(value : Double, minimum : Double, maximum : Double) -> Double {
  if value < minimum {
    minimum
  } else if value > maximum {
    maximum
  } else {
    value
  }
}

///|
fn timeline_valid_track(duration : Double, x : Double, width : Double) -> Bool {
  timeline_finite(duration) &&
  duration > 0 &&
  timeline_finite(x) &&
  timeline_finite(width) &&
  width > 0 &&
  timeline_finite(x + width) &&
  x + width > x
}

///|
/// Invalid geometry/nonfinite input returns NaN; finite times clamp to the track.
pub fn timeline_x_for_time(
  time_ms : Double,
  duration_ms : Double,
  track_x : Double,
  track_width : Double,
) -> Double {
  if !timeline_finite(time_ms) ||
    !timeline_valid_track(duration_ms, track_x, track_width) {
    return 0.0 / 0.0
  }
  track_x + timeline_clamp(time_ms, 0, duration_ms) / duration_ms * track_width
}

///|
/// Coordinates outside the track map to zero/duration, including pointer drags.
pub fn timeline_time_for_x(
  x : Double,
  duration_ms : Double,
  track_x : Double,
  track_width : Double,
) -> Double {
  if !timeline_finite(x) ||
    !timeline_valid_track(duration_ms, track_x, track_width) {
    return 0.0 / 0.0
  }
  if x <= track_x {
    return 0
  }
  if x >= track_x + track_width {
    return duration_ms
  }
  (x - track_x) / track_width * duration_ms
}

///|
/// Main ruler ticks use 1/2/5 × powers of ten, at least one millisecond.
/// Hosts supply label spacing after font measurement; invalid geometry is NaN.
pub fn timeline_tick_step(
  duration_ms : Double,
  track_width : Double,
  min_label_spacing : Double,
) -> Double {
  if !timeline_valid_track(duration_ms, 0, track_width) ||
    !timeline_finite(min_label_spacing) ||
    min_label_spacing <= 0 {
    return 0.0 / 0.0
  }
  let target = duration_ms / track_width * min_label_spacing
  if !timeline_finite(target) {
    return 0.0 / 0.0
  }
  let mut unit = 1.0
  while target > 5 * unit {
    unit = unit * 10
  }
  let step = if target <= unit {
    unit
  } else if target <= 2 * unit {
    2 * unit
  } else {
    5 * unit
  }
  if timeline_finite(step) {
    step
  } else {
    0.0 / 0.0
  }
}

///|
/// Move one trim edge (0=start, 1=end), preserving its opposite edge. Existing
/// bounds/duration are integer milliseconds. Candidate rounds to nearest ms;
/// minimum span rounds up, capped at the full source duration for short clips.
/// An invalid or impossible fixed-edge constraint returns NaN, never a new range.
pub fn timeline_trim_boundary(
  edge : Int32,
  candidate_ms : Double,
  start_ms : Double,
  end_ms : Double,
  duration_ms : Double,
  min_span_ms : Double,
) -> Double {
  if (edge != 0 && edge != 1) ||
    !timeline_finite(candidate_ms) ||
    !timeline_finite(start_ms) ||
    !timeline_finite(end_ms) ||
    !timeline_finite(duration_ms) ||
    !timeline_finite(min_span_ms) ||
    duration_ms < 1 ||
    min_span_ms <= 0 ||
    start_ms < 0 ||
    start_ms >= end_ms ||
    end_ms > duration_ms ||
    @double.floor(start_ms) != start_ms ||
    @double.floor(end_ms) != end_ms ||
    @double.floor(duration_ms) != duration_ms {
    return 0.0 / 0.0
  }
  let requested_minimum = @double.ceil(min_span_ms)
  let minimum = if requested_minimum > duration_ms {
    duration_ms
  } else {
    requested_minimum
  }
  let candidate = @double.floor(
    timeline_clamp(candidate_ms, 0, duration_ms) + 0.5,
  )
  if edge == 0 {
    if end_ms < minimum {
      return 0.0 / 0.0
    }
    timeline_clamp(candidate, 0, end_ms - minimum)
  } else {
    if start_ms > duration_ms - minimum {
      return 0.0 / 0.0
    }
    timeline_clamp(candidate, start_ms + minimum, duration_ms)
  }
}
