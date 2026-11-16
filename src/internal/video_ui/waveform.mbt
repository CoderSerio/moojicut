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
      let start = clamp(
        c.source_start + (project_time(s, left) * 90 - c.start) * rate,
        c.source_start,
        c.source_end,
      )
      let end = clamp(
        c.source_start + (project_time(s, right) * 90 - c.start) * rate,
        c.source_start,
        c.source_end,
      )
      waveform_peak(wave, start / 90, end / 90)
    }
  }
}

///|
fn project_draw_waveform(
  commands : Array[Json],
  s : UI,
  c : ProjectClip,
  r : Rect,
) -> Unit {
  if c.kind != "audio" || r.width < 4 || !has_waveform(s) {
    return
  }
  let p = palette(s)
  let color = if project(s).muted { p.disabled } else { p.text }
  let center = r.y + 27
  // Only visible pixels are drawn. Max-pooling preserves short transients when
  // zoomed out; square-root display gain reveals quiet speech without changing
  // the source envelope or the exported audio level.
  for x = r.x + 2; x < r.x + r.width - 2; x = x + 2 {
    let peak = project_waveform_peak(
      s,
      c,
      x,
      @protocol.smaller(x + 2, r.x + r.width),
    )
    let extent = @protocol.larger(0.5, peak.sqrt() * 12)
    draw_line(commands, s, x, center - extent, x, center + extent, color, 1)
  }
}
