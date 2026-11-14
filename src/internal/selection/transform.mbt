///|
// macOS is the shared baseline, including an inverted clamp interval when a
// requested minimum edge is larger than the available image space.
fn clamp(value : Double, low : Double, high : Double) -> Double {
  upper(low, lower(value, high))
}

///|
fn clamp_leading_edge(value : Double, low : Double, high : Double) -> Double {
  lower(high, upper(low, value))
}

///|
// Pointer conversion and clamping happen in the host. The delta here is always
// measured from the gesture anchor, never accumulated from the previous frame.
pub fn transform(
  x : Double, y : Double, width : Double, height : Double,
  ax : Double, ay : Double, px : Double, py : Double,
  handle : Int,
  bounds_x : Double, bounds_y : Double, bounds_width : Double, bounds_height : Double,
  minimum : Double,
  directed~ : Bool = false,
) -> FixedArray[Double] {
  if handle > 7 { return [x, y, width, height] }
  let dx = px - ax
  let dy = py - ay
  let bounds_right = bounds_x + bounds_width
  let bounds_bottom = bounds_y + bounds_height
  if handle < 0 {
    // The default preserves macOS arithmetic even for negative rectangle sizes.
    // Directed annotations opt in to keeping both endpoints within the bounds.
    let min_x = if directed { bounds_x + upper(0, -width) } else { bounds_x }
    let min_y = if directed { bounds_y + upper(0, -height) } else { bounds_y }
    let max_x = bounds_right - (if directed { upper(0, width) } else { width })
    let max_y = bounds_bottom - (if directed { upper(0, height) } else { height })
    return [clamp(x + dx, min_x, max_x), clamp(y + dy, min_y, max_y), width, height]
  }
  let mut left = x
  let mut right = x + width
  let mut top = y
  let mut bottom = y + height
  if handle == 0 || handle == 6 || handle == 7 {
    left = clamp_leading_edge(left + dx, bounds_x, right - minimum)
  }
  if handle == 2 || handle == 3 || handle == 4 {
    right = clamp(right + dx, left + minimum, bounds_right)
  }
  if handle == 0 || handle == 1 || handle == 2 {
    top = clamp_leading_edge(top + dy, bounds_y, bottom - minimum)
  }
  if handle == 4 || handle == 5 || handle == 6 {
    bottom = clamp(bottom + dy, top + minimum, bounds_bottom)
  }
  [left, top, right - left, bottom - top]
}
