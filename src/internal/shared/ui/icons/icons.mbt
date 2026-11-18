///|
pub fn color(rgb : Int32) -> String {
  let digits = [
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f",
  ]
  let mut value = "#"
  for shift in [20, 16, 12, 8, 4, 0] {
    value += digits[(rgb >> shift) & 15]
  }
  value
}

///|
fn blend(foreground : Int32, background : Int32, opacity : Double) -> Int32 {
  let mut result = 0
  for shift in [16, 8, 0] {
    let f = ((foreground >> shift) & 255).to_double()
    let b = ((background >> shift) & 255).to_double()
    result = result | ((b + (f - b) * opacity + 0.5).to_int() << shift)
  }
  result
}

///|
/// Canonical, build-time compiled icon geometry. Unknown assets use the same
/// project-owned puzzle fallback on every host. Coordinates are logical units;
/// the caller supplies the actual background for relative mosaic opacity.
pub fn commands(
  name : String,
  x : Double,
  y : Double,
  size : Double,
  foreground : Int32,
  background : Int32,
) -> Array[@json.Json] {
  if !(size > 0 &&
    size <= 4096 &&
    x >= -1000000 &&
    x <= 1000000 &&
    y >= -1000000 &&
    y <= 1000000) {
    return []
  }
  let shape = paths(name)
  let shape = if shape.is_empty() { paths("plugin") } else { shape }
  let scale = size / 24
  shape.map(primitive => {
    let (filled, x1, y1, x2, y2, alpha) = primitive
    let ink = color(blend(foreground, background, alpha))
    if filled {
      @json.Json::object({
        "type": @json.Json("rect"),
        "x": @json.Json(x + x1 * scale),
        "y": @json.Json(y + y1 * scale),
        "width": @json.Json(x2 * scale),
        "height": @json.Json(y2 * scale),
        "fill": @json.Json(ink),
      })
    } else {
      @json.Json::object({
        "type": @json.Json("line"),
        "x1": @json.Json(x + x1 * scale),
        "y1": @json.Json(y + y1 * scale),
        "x2": @json.Json(x + x2 * scale),
        "y2": @json.Json(y + y2 * scale),
        "lineWidth": @json.Json(2.0 * scale),
        "color": @json.Json(ink),
      })
    }
  })
}
