// Media adapters supply a bounded, source-time amplitude envelope. The shared
// UI maps it through the authoritative clip times; edits never rewrite peaks.

///|
priv struct Waveform {
  duration_ms : Double
  count : Int32
  size : Int32
  tree : Array[Double]
}

///|
fn has_waveform(s : UI) -> Bool {
  match s.waveform {
    Some(wave) => wave.count > 0
    None => false
  }
}

///|
fn make_waveform(duration_ms : Double, peaks : Array[Double]) -> Waveform {
  let mut size = 1
  while size < peaks.length() {
    size = size * 2
  }
  let tree = Array::make(size * 2, 0.0)
  for i, peak in peaks {
    tree[size + i] = peak
  }
  for i = size - 1; i > 0; i = i - 1 {
    tree[i] = @protocol.larger(tree[i * 2], tree[i * 2 + 1])
  }
  { duration_ms, count: peaks.length(), size, tree, }
}

///|
fn receive_waveform(
  s : UI,
  input : Map[String, Json],
) -> Unit raise @protocol.InputError {
  let duration = @protocol.integer_field(input, "durationMs", 1, 604800000)
  let expected = if is_project(s) {
    project(s).source_duration / 90
  } else {
    s.snapshot.duration
  }
  if duration != expected {
    raise @protocol.InputError(
      "invalid_waveform", "Waveform must describe the original source",
    )
  }
  let peaks : Array[Double] = []
  match input.get("peaks") {
    Some(Array(values)) if values.length() <= 16384 =>
      for value in values {
        match value {
          Number(peak, ..) if peak >= 0 && peak <= 1 => peaks.push(peak)
          _ =>
            raise @protocol.InputError(
              "invalid_waveform", "Peak must be in [0,1]",
            )
        }
      }
    _ =>
      raise @protocol.InputError(
        "invalid_waveform", "Waveform has too many bins",
      )
  }
  s.waveform = Some(make_waveform(duration, peaks))
}

///|
fn waveform_peak(wave : Waveform, start_ms : Double, end_ms : Double) -> Double {
  let count = wave.count
  if count == 0 ||
    end_ms <= start_ms ||
    end_ms <= 0 ||
    start_ms >= wave.duration_ms {
    return 0
  }
  let first = @double.floor(
    clamp(
      start_ms / wave.duration_ms * count.to_double(),
      0,
      count.to_double() - 1,
    ),
  ).to_int()
  let end = @double.ceil(
    clamp(end_ms / wave.duration_ms * count.to_double(), 0, count.to_double()),
  ).to_int()
  let mut peak = 0.0
  let mut left = first + wave.size
  let mut right = end + wave.size
  // Range maxima stay logarithmic even for long clips shown at a tiny scale.
  while left < right {
    if left % 2 == 1 {
      peak = @protocol.larger(peak, wave.tree[left])
      left = left + 1
    }
    if right % 2 == 1 {
      right = right - 1
      peak = @protocol.larger(peak, wave.tree[right])
    }
    left = left / 2
    right = right / 2
  }
  peak
}

///|
fn project_waveform_peak(
  s : UI,
  c : ProjectClip,
  left : Double,
  right : Double,
) -> Double {
  match s.waveform {
    None => 0
    Some(wave) => {
      let rate = clip_rate(c)
      let display_start = project_display_start(s, c)
      let start = clamp(
        c.source_start + (project_time(s, left) * 90 - display_start) * rate,
        c.source_start,
        c.source_end,
      )
      let end = clamp(
        c.source_start + (project_time(s, right) * 90 - display_start) * rate,
        c.source_start,
        c.source_end,
      )
      waveform_peak(wave, start / 90, end / 90)
    }
  }
}

///|
// Clip rectangles are painted in row order. Their opaque interior will cover
// earlier waveform columns. Subtract the union once per clip, rather than
// testing every output pixel against every later clip. Work is O(clips^2 +
// visible columns), with the core limiting an audio row to 256 clips.
fn project_waveform_spans(
  s : UI,
  clips : Array[ProjectClip],
) -> Map[String, Array[(Double, Double)]] {
  let visible : Map[String, Array[(Double, Double)]] = Map([])
  let mut covered : Array[(Double, Double)] = []
  for i = clips.length() - 1; i >= 0; i = i - 1 {
    let clip = clips[i]
    let r = project_clip_rect(s, clip)
    let right = r.x + r.width
    let spans : Array[(Double, Double)] = []
    let mut cursor = r.x
    for interval in covered {
      if interval.1 <= cursor {
        continue
      }
      if interval.0 >= right {
        break
      }
      if interval.0 > cursor {
        spans.push((cursor, @protocol.smaller(interval.0, right)))
      }
      cursor = @protocol.larger(cursor, interval.1)
      if cursor >= right {
        break
      }
    }
    if cursor < right {
      spans.push((cursor, right))
    }
    visible[clip.id] = spans
    // Keep four logical points at either edge: rounded corners and the stroke
    // can leave an earlier column visible. Interior columns are fully covered.
    let mut left = r.x + 4
    let mut right = right - 4
    if right <= left {
      continue
    }
    let next : Array[(Double, Double)] = []
    let mut inserted = false
    for interval in covered {
      if interval.1 < left {
        next.push(interval)
      } else if interval.0 > right {
        if !inserted {
          next.push((left, right))
          inserted = true
        }
        next.push(interval)
      } else {
        left = @protocol.smaller(left, interval.0)
        right = @protocol.larger(right, interval.1)
      }
    }
    if !inserted {
      next.push((left, right))
    }
    covered = next
  }
  visible
}

///|
fn project_draw_visible_waveform(
  commands : Array[Json],
  s : UI,
  c : ProjectClip,
  r : Rect,
  visible : Array[(Double, Double)],
) -> Unit {
  if c.kind != "audio" || r.width * s.scale < 4 || !has_waveform(s) {
    return
  }
  let p = palette(s)
  let color = if project(s).muted { p.disabled } else { p.text }
  let center = r.y + 27
  // Geometry and project_time use logical coordinates; draw_line applies the
  // frame scale. Two output pixels per column bounds work even in a very short
  // window. Preserve the original column grid and source pooling interval when
  // skipping covered spans; visible waveform amplitudes/positions do not move.
  let stride = 2.0 / s.scale
  let origin = r.x + stride
  for span in visible {
    let first = origin +
      @protocol.larger(0, @double.ceil((span.0 - origin) / stride)) * stride
    let end = @protocol.smaller(r.x + r.width - stride, span.1)
    for x = first; x < end; x = x + stride {
      let peak = project_waveform_peak(
        s,
        c,
        x,
        @protocol.smaller(x + stride, r.x + r.width),
      )
      let extent = @protocol.larger(0.5, peak.sqrt() * 12)
      draw_line(commands, s, x, center - extent, x, center + extent, color, 1)
    }
  }
}
