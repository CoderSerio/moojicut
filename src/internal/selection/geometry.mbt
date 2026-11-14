///|
fn lower(a : Double, b : Double) -> Double {
  if a < b { a } else { b }
}

///|
fn upper(a : Double, b : Double) -> Double {
  if a > b { a } else { b }
}

///|
pub fn region(ax : Double, ay : Double, bx : Double, by : Double) -> FixedArray[Double] {
  let left = lower(ax, bx)
  let top = lower(ay, by)
  [left, top, upper(ax, bx) - left, upper(ay, by) - top]
}

///|
fn midpoint(value : Double, mode : Int) -> Double {
  if mode == 1 {
    if value < 0 { @double.ceil(value) } else { @double.floor(value) }
  } else {
    value
  }
}

///|
// The Windows host truncates the final midpoint toward zero. Truncating half
// the width before adding the origin differs at odd negative coordinates.
fn handle_position(
  x : Double, y : Double, width : Double, height : Double,
  handle : Int, midpoint_mode : Int,
) -> (Double, Double) {
  match handle {
    0 => (x, y)
    1 => (midpoint(x + width / 2, midpoint_mode), y)
    2 => (x + width, y)
    3 => (x + width, midpoint(y + height / 2, midpoint_mode))
    4 => (x + width, y + height)
    5 => (midpoint(x + width / 2, midpoint_mode), y + height)
    6 => (x, y + height)
    7 => (x, midpoint(y + height / 2, midpoint_mode))
    _ => (0, 0)
  }
}

///|
pub fn handle_point(
  x : Double, y : Double, width : Double, height : Double,
  handle : Int, midpoint_mode : Int,
) -> FixedArray[Double] {
  let (px, py) = handle_position(x, y, width, height, handle, midpoint_mode)
  [px, py]
}

///|
pub fn hit_handle(
  x : Double, y : Double, width : Double, height : Double,
  px : Double, py : Double, radius : Double,
  midpoint_mode : Int,
) -> Int {
  for handle in 0..<8 {
    let (cx, cy) = handle_position(x, y, width, height, handle, midpoint_mode)
    // Match NSMakeRect(center - radius, radius * 2) before testing its bounds.
    // Reassociating the maximum as center + radius can shift a fractional edge.
    let left = cx - radius
    let top = cy - radius
    if px >= left && py >= top &&
      px < left + radius * 2 && py < top + radius * 2 {
      return handle
    }
  }
  -1
}

///|
// Directed rectangles are used by the Linux editor for arrows. Containment
// normalizes their bounds without changing the direction stored by the host.
pub fn contains(
  x : Double, y : Double, width : Double, height : Double,
  px : Double, py : Double,
) -> Int {
  if px >= lower(x, x + width) && px <= upper(x, x + width) &&
    py >= lower(y, y + height) && py <= upper(y, y + height) {
    1
  } else {
    0
  }
}

///|
fn contains_half_open(
  x : Double, y : Double, width : Double, height : Double,
  px : Double, py : Double,
) -> Bool {
  width > 0 && height > 0 && px >= x && py >= y &&
  px < x + width && py < y + height
}

///|
pub fn border_contains(
  x : Double, y : Double, width : Double, height : Double,
  px : Double, py : Double, radius : Double,
) -> Int {
  let outside = contains_half_open(
    x - radius, y - radius, width + 2 * radius, height + 2 * radius, px, py,
  )
  let inside = contains_half_open(
    x + radius, y + radius, width - 2 * radius, height - 2 * radius, px, py,
  )
  if outside && !inside { 1 } else { 0 }
}
