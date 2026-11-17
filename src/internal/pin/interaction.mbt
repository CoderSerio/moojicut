///|
/// One wheel notch is one step; touchpads/high-resolution wheels pass fractions.
pub fn scroll_scale(value : Double, steps : Double) -> Double {
  if !finite(value) || value <= 0 || !finite(steps) {
    return 0
  }
  let result = value * @math.pow(1.1, larger(-32, smaller(32, steps)))
  if finite(result) {
    result
  } else {
    0
  }
}

///|
/// Top-left coordinates. Bits: left=1, right=2, top=4, bottom=8; zero=move.
pub fn hit_handle(
  width : Double,
  height : Double,
  x : Double,
  y : Double,
  margin : Double,
) -> Int32 {
  if !dimensions_valid(width, height, width, height) ||
    !finite(x) ||
    !finite(y) ||
    !finite(margin) ||
    margin <= 0 ||
    x < 0 ||
    y < 0 ||
    x > width ||
    y > height {
    return 0
  }
  let mx = smaller(margin, width / 3)
  let my = smaller(margin, height / 3)
  let horizontal = if x <= mx { 1 } else if x >= width - mx { 2 } else { 0 }
  let vertical = if y <= my { 4 } else if y >= height - my { 8 } else { 0 }
  horizontal + vertical
}

///|
/// Resize from the gesture's original frame, keeping the opposite edge/corner
/// fixed. Top-left coordinates are shared across hosts; AppKit flips Y at FFI.
/// Owned [x,y,width,height,scale]; zeros reject invalid geometry.
pub fn resize_frame(
  platform : Int32,
  x : Double,
  y : Double,
  source_width : Double,
  source_height : Double,
  start_scale : Double,
  handle : Int32,
  dx : Double,
  dy : Double,
  work_x : Double,
  work_y : Double,
  work_width : Double,
  work_height : Double,
) -> FixedArray[Double] {
  if !dimensions_valid(source_width, source_height, work_width, work_height) ||
    !finite(x) ||
    !finite(y) ||
    !finite(work_x) ||
    !finite(work_y) ||
    !finite(start_scale) ||
    start_scale <= 0 ||
    !finite(dx) ||
    !finite(dy) ||
    !(handle == 1 ||
    handle == 2 ||
    handle == 4 ||
    handle == 8 ||
    handle == 5 ||
    handle == 6 ||
    handle == 9 ||
    handle == 10) {
    return [0, 0, 0, 0, 0]
  }
  let horizontal = if (handle & 1) != 0 {
    -1.0
  } else if (handle & 2) != 0 {
    1.0
  } else {
    0.0
  }
  let vertical = if (handle & 4) != 0 {
    -1.0
  } else if (handle & 8) != 0 {
    1.0
  } else {
    0.0
  }
  // Project corner motion onto the aspect-ratio diagonal. Normalize first to
  // avoid squaring large source dimensions or making a tiny pointer step jump.
  let basis = larger(source_width, source_height)
  let wx = source_width / basis * horizontal
  let hy = source_height / basis * vertical
  let delta = (dx / basis * wx + dy / basis * hy) / (wx * wx + hy * hy)
  let resolved = scale(
    platform,
    start_scale + delta,
    source_width,
    source_height,
    work_width,
    work_height,
  )
  if resolved <= 0 {
    return [0, 0, 0, 0, 0]
  }
  let width = source_width * resolved
  let height = source_height * resolved
  let next_x = x +
    (source_width * start_scale - width) *
    (if horizontal < 0 { 1.0 } else if horizontal > 0 { 0.0 } else { 0.5 })
  let next_y = y +
    (source_height * start_scale - height) *
    (if vertical < 0 { 1.0 } else if vertical > 0 { 0.0 } else { 0.5 })
  if !finite(next_x) || !finite(next_y) {
    return [0, 0, 0, 0, 0]
  }
  [
    larger(work_x, smaller(work_x + work_width - width, next_x)),
    larger(work_y, smaller(work_y + work_height - height, next_y)),
    width,
    height,
    resolved,
  ]
}
