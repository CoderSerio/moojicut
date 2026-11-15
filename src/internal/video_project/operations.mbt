///|
fn changed_clip(
  c : Clip,
  source_start : Double,
  source_end : Double,
  start : Double,
  duration : Double,
  link : String?,
) -> Clip {
  { id: c.id, kind: c.kind, source_start, source_end, start, duration, link, }
}

///|
fn shifted(c : Clip, delta : Double) -> Clip {
  changed_clip(
    c,
    c.source_start,
    c.source_end,
    c.start + delta,
    c.duration,
    c.link,
  )
}

///|
fn find_clip(p : Project, id : String) -> Clip raise @protocol.InputError {
  for c in p.clips {
    if c.id == id {
      return c
    }
  }
  raise @protocol.InputError("unknown_clip", "Clip \{id} no longer exists")
}

///|
fn detach(p : Project, c : Clip) -> Unit {
  match c.link {
    None => ()
    Some(group) =>
      p.clips = p.clips.map(item => {
        if item.link == Some(group) {
          changed_clip(
            item,
            item.source_start,
            item.source_end,
            item.start,
            item.duration,
            None,
          )
        } else {
          item
        }
      })
  }
}

///|
fn targets(
  p : Project,
  c : Clip,
  linked : Bool,
) -> Array[Clip] raise @protocol.InputError {
  if linked {
    match c.link {
      Some(group) => p.clips.filter(item => item.link == Some(group))
      None => [c]
    }
  } else {
    if c.link != None {
      raise @protocol.InputError(
        "linked_clip", "请先解除音画联动，再单独编辑这个片段。",
      )
    }
    [c]
  }
}

///|
// All callers reduce output ticks to frames before multiplication. At the
// seven-day bound the largest product is < 9.88e17, within signed Int64.
// Floating multiplication can choose the wrong side of a half-tick boundary.
fn rounded_ratio(numerator : Int64, denominator : Int64) -> Double {
  let quotient = numerator / denominator
  let remainder = numerator % denominator
  (quotient + (if remainder * 2 >= denominator { 1L } else { 0L })).to_double()
}

///|
fn includes(clips : Array[Clip], id : String) -> Bool {
  clips.any(c => c.id == id)
}

///|
fn allocate(next : Ref[Int32]) -> Int32 raise @protocol.InputError {
  if next.val >= 999999999 {
    raise @protocol.InputError("id_limit", "Project identifier space exhausted")
  }
  let value = next.val
  next.val = value + 1
  value
}

///|
// The first release has no independent-track ripple policy. A crossing audio
// clip must be explicitly unlinked/repositioned by the caller, never silently
// shortened or duplicated. Entire clips after the boundary shift together.
fn ripple_other(
  c : Clip,
  from : Double,
  boundary : Double,
  delta : Double,
) -> Clip raise @protocol.InputError {
  if delta == 0 {
    return c
  }
  if c.start >= boundary {
    return shifted(c, delta)
  }
  if c.start + c.duration > from {
    raise @protocol.InputError(
      "ambiguous_ripple", "独立音频跨过编辑范围，请关闭合拢或先调整音频位置。",
    )
  }
  c
}

///|
fn resize(
  p : Project,
  selected : Array[Clip],
  source_start : Double,
  source_end : Double,
  duration : Double,
  ripple : Bool,
) -> Unit raise @protocol.InputError {
  let primary = selected[0]
  if duration < frame_ticks {
    raise @protocol.InputError(
      "too_short", "Result must contain at least one output frame",
    )
  }
  let delta = duration - primary.duration
  let result : Array[Clip] = []
  for c in p.clips {
    if includes(selected, c.id) {
      result.push(
        changed_clip(c, source_start, source_end, c.start, duration, c.link),
      )
    } else {
      result.push(
        if ripple {
          ripple_other(
            c,
            primary.start,
            primary.start + primary.duration,
            delta,
          )
        } else {
          c
        },
      )
    }
  }
  p.clips = result
}

///|
fn split_clip(
  p : Project,
  c : Clip,
  op : Map[String, Json],
  next : Ref[Int32],
) -> Unit raise @protocol.InputError {
  let selected = targets(p, c, boolean(op, "linked", default=true))
  let at = quantized(op, "atTicks", 0, max_ticks)
  let left_duration = at - c.start
  let right_duration = c.duration - left_duration
  if left_duration < frame_ticks || right_duration < frame_ticks {
    raise @protocol.InputError(
      "too_short", "Split must leave at least one output frame on both sides",
    )
  }
  let ordinal = allocate(next)
  let result : Array[Clip] = []
  for item in p.clips {
    if !includes(selected, item.id) {
      result.push(item)
      continue
    }
    let numerator = (item.source_end - item.source_start).to_int64() *
      (left_duration / frame_ticks).to_int64()
    let middle = item.source_start +
      rounded_ratio(numerator, (item.duration / frame_ticks).to_int64())
    if middle - item.source_start < frame_ticks ||
      item.source_end - middle < frame_ticks {
      raise @protocol.InputError(
        "too_short", "Split must leave at least one source frame on both sides",
      )
    }
    result.push(
      changed_clip(
        item,
        item.source_start,
        middle,
        item.start,
        left_duration,
        item.link,
      ),
    )
    result.push({
      id: "\{if item.kind == "video" { "v" } else { "a" }}\{ordinal}",
      kind: item.kind,
      source_start: middle,
      source_end: item.source_end,
      start: at,
      duration: right_duration,
      link: if selected.length() == 2 {
        Some("g\{ordinal}")
      } else {
        None
      },
    })
  }
  p.clips = result
}

///|
fn remove_clip(
  p : Project,
  c : Clip,
  op : Map[String, Json],
) -> Unit raise @protocol.InputError {
  let selected = targets(p, c, boolean(op, "linked", default=true))
  let ripple = boolean(op, "ripple", default=true)
  let result : Array[Clip] = []
  for item in p.clips {
    if includes(selected, item.id) {
      continue
    }
    result.push(
      if ripple {
        ripple_other(item, c.start, c.start + c.duration, -c.duration)
      } else {
        item
      },
    )
  }
  p.clips = result
}

///|
fn remove_gap(
  p : Project,
  op : Map[String, Json],
) -> Unit raise @protocol.InputError {
  // Unlike a dragged edge, this operation names an existing complete interval.
  // Do not round an approximate/stale selection into a different valid gap.
  let start = integer(op, "startTicks", 0, max_ticks)
  let end = integer(op, "endTicks", 0, max_ticks)
  if end <= start || !grid(start) || !grid(end) {
    raise @protocol.InputError(
      "invalid_gap", "请选择时间轴上完整的空隙。",
    )
  }
  let mut output_end = 0.0
  for c in p.clips {
    output_end = @protocol.larger(output_end, c.start + c.duration)
  }
  let mut previous_end = 0.0
  let mut found = false
  for c in ordered(p.clips.filter(c => c.kind == "video")) {
    if previous_end == start && c.start == end {
      found = true
    }
    previous_end = c.start + c.duration
  }
  if previous_end == start && output_end == end {
    found = true
  }
  if !found {
    raise @protocol.InputError(
      "invalid_gap", "空隙已改变，请重新选择。",
    )
  }
  let result : Array[Clip] = []
  for c in p.clips {
    // Touching either boundary is safe; any positive overlap would delete
    // sound or silently change its timing, even while the project is muted.
    if c.kind == "audio" && c.start < end && c.start + c.duration > start {
      raise @protocol.InputError(
        "ambiguous_ripple", "空隙内仍有独立音频，请先调整音频位置。",
      )
    }
    result.push(if c.start >= end { shifted(c, start - end) } else { c })
  }
  p.clips = result
}

///|
fn move_clip(
  p : Project,
  c : Clip,
  op : Map[String, Json],
) -> Unit raise @protocol.InputError {
  let selected = targets(p, c, boolean(op, "linked", default=true))
  if !selected.any(item => item.kind == "video") {
    raise @protocol.InputError(
      "independent_audio_move", "独立音频请使用时间偏移，不参与视频重排。",
    )
  }
  let before = match op.get("beforeClipId") {
    Some(Null) => None
    Some(String(id)) => Some(id)
    _ =>
      raise @protocol.InputError(
        "invalid_input", "beforeClipId must be a clip identifier or null",
      )
  }
  let moving_video = selected.any(item => item.kind == "video")
  let kind = if moving_video { "video" } else { "audio" }
  match before {
    Some(id) => {
      let target = find_clip(p, id)
      if includes(selected, id) {
        return
      }
      if target.kind != kind {
        raise @protocol.InputError(
          "invalid_move", "Move target must be on the same track",
        )
      }
    }
    None => ()
  }
  // Remove the selected interval, then insert it at the destination. Both
  // phases are tentative and the caller commits them as one transaction.
  let remaining : Array[Clip] = []
  for item in p.clips {
    if !includes(selected, item.id) {
      remaining.push(
        ripple_other(item, c.start, c.start + c.duration, -c.duration),
      )
    }
  }
  let mut insertion = 0.0
  match before {
    Some(id) =>
      for item in remaining {
        if item.id == id {
          insertion = item.start
          break
        }
      }
    None =>
      for item in remaining {
        if item.kind == kind {
          insertion = @protocol.larger(insertion, item.start + item.duration)
        }
      }
  }
  let result : Array[Clip] = []
  for item in remaining {
    if item.start >= insertion {
      result.push(shifted(item, c.duration))
    } else if item.start + item.duration > insertion {
      raise @protocol.InputError(
        "ambiguous_ripple", "独立音频跨过插入位置，请先调整音频位置。",
      )
    } else {
      result.push(item)
    }
  }
  for item in selected {
    result.push(shifted(item, insertion - c.start))
  }
  p.clips = result
}

///|
fn speed_clip(
  p : Project,
  c : Clip,
  op : Map[String, Json],
) -> Unit raise @protocol.InputError {
  let has_rate = op.contains("rate")
  let has_duration = op.contains("targetDurationTicks")
  if has_rate == has_duration {
    raise @protocol.InputError(
      "invalid_input", "Provide rate or targetDurationTicks, exclusively",
    )
  }
  let source_span = c.source_end - c.source_start
  let duration = if has_rate {
    let rate = @protocol.object_field(op, "rate")
    let num = integer(rate, "num", 1, 1000000)
    let den = integer(rate, "den", 1, 1000000)
    let value = num / den
    if value < 0.25 || value > 4 {
      raise @protocol.InputError(
        "unsupported_speed", "片段速度须在 0.25–4 倍之间。",
      )
    }
    let numerator = source_span.to_int64() * den.to_int64()
    let denominator = num.to_int64() * 3000L
    if numerator < denominator {
      raise @protocol.InputError(
        "too_short", "此速度会使片段不足一帧，请降低速度。",
      )
    }
    rounded_ratio(numerator, denominator) * frame_ticks
  } else {
    quantized(op, "targetDurationTicks", frame_ticks, max_ticks)
  }
  let selected = targets(p, c, boolean(op, "linked", default=true))
  resize(
    p,
    selected,
    c.source_start,
    c.source_end,
    duration,
    boolean(op, "ripple", default=true),
  )
}

///|
fn trim_clip(
  p : Project,
  c : Clip,
  op : Map[String, Json],
) -> Unit raise @protocol.InputError {
  let limit = source_limit(p.source)
  // A split can create an exact non-frame source boundary (e.g. 4500 ticks at
  // 1.5x). An unchanged opposite edge must not be quantized a second time.
  let start = match op.get("sourceStartTicks") {
    Some(Number(value, ..)) if value == c.source_start => value
    _ => quantized(op, "sourceStartTicks", 0, limit)
  }
  let end = match op.get("sourceEndTicks") {
    Some(Number(value, ..)) if value == c.source_end => value
    _ => quantized(op, "sourceEndTicks", 0, limit)
  }
  if end - start < frame_ticks {
    raise @protocol.InputError(
      "too_short", "Trim must retain at least one source frame",
    )
  }
  let numerator = (end - start).to_int64() *
    (c.duration / frame_ticks).to_int64()
  let denominator = (c.source_end - c.source_start).to_int64()
  if numerator < denominator {
    raise @protocol.InputError(
      "too_short", "Trim must retain at least one output frame",
    )
  }
  let duration = rounded_ratio(numerator, denominator) * frame_ticks
  let selected = targets(p, c, boolean(op, "linked", default=true))
  resize(p, selected, start, end, duration, boolean(op, "ripple", default=true))
}

///|
fn apply_operation(
  p : Project,
  op : Map[String, Json],
  next : Ref[Int32],
) -> Unit raise @protocol.InputError {
  let action = text(op, "type")
  if action == "mute" || action == "crop" {
    if action == "mute" {
      p.muted = boolean(op, "muted")
    } else {
      p.crop = crop_value(op, p.source)
    }
    validate(p)
    return
  }
  if action == "removeGap" {
    remove_gap(p, op)
    validate(p)
    return
  }
  let c = find_clip(p, text(op, "clipId"))
  match action {
    "split" => split_clip(p, c, op, next)
    "remove" => remove_clip(p, c, op)
    "move" => move_clip(p, c, op)
    "setSpeed" => speed_clip(p, c, op)
    "trim" => trim_clip(p, c, op)
    "unlink" => detach(p, c)
    "offset" => {
      if c.kind != "audio" || c.link != None {
        raise @protocol.InputError(
          "linked_audio", "Offset requires an unlinked audio clip",
        )
      }
      let delta = quantized(op, "deltaTicks", -max_ticks, max_ticks)
      p.clips = p.clips.map(item => {
        if item.id == c.id {
          shifted(item, delta)
        } else {
          item
        }
      })
    }
    _ =>
      raise @protocol.InputError(
        "invalid_command", "Unknown project edit operation",
      )
  }
  validate(p)
}
