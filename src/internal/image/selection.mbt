///|
fn selection_number(m : Map[String, Json], key : String) -> Double raise InputError {
  let value = image_number(m, key, 1.0 / 0.0)
  if !(value >= -65536 && value <= 65536) {
    raise InputError("invalid_input", "Invalid selection coordinate")
  }
  value
}

///|
fn segment_distance_squared(
  x : Double, y : Double, x2 : Double, y2 : Double, px : Double, py : Double,
) -> Double {
  let dx = x2 - x
  let dy = y2 - y
  let length = dx * dx + dy * dy
  let t = if length == 0 { 0.0 } else {
    @protocol.larger(0, @protocol.smaller(1, ((px - x) * dx + (py - y) * dy) / length))
  }
  let ex = px - x - t * dx
  let ey = py - y - t * dy
  ex * ex + ey * ey
}

///|
// Image coordinates, before the host applies its viewport/scale transform.
fn arrowhead_points(
  x : Double, y : Double, x2 : Double, y2 : Double, stroke : Double,
) -> (Double, Double, Double, Double) {
  let dx = x2 - x
  let dy = y2 - y
  let length = (dx * dx + dy * dy).sqrt()
  if length == 0 { return (x2, y2, x2, y2) }
  let head = @protocol.smaller(length * 0.45, @protocol.larger(14, stroke * 3.5))
  let ux = dx / length
  let uy = dy / length
  let along = head * @math.cos(0.5)
  let across = head * @math.sin(0.5)
  (x2 - along * ux + across * uy, y2 - along * uy - across * ux,
   x2 - along * ux - across * uy, y2 - along * uy + across * ux)
}

///|
pub fn image_arrowhead_value(
  x : Double, y : Double, x2 : Double, y2 : Double, stroke : Double, field : Int,
) -> Double {
  if !(x >= -65536 && x <= 65536 && y >= -65536 && y <= 65536 &&
       x2 >= -65536 && x2 <= 65536 && y2 >= -65536 && y2 <= 65536 &&
       stroke >= 0 && stroke <= 96) { return 0 }
  let (ax, ay, bx, by) = arrowhead_points(x, y, x2, y2, stroke)
  match field { 0 => ax; 1 => ay; 2 => bx; 3 => by; _ => 0 }
}

///|
fn annotation_contains(m : Map[String, Json], px : Double, py : Double, tolerance : Double) -> Bool {
  let kind = image_string(m, "type", "")
  let x = image_number(m, "x", 0)
  let y = image_number(m, "y", 0)
  let width = image_number(m, "width", 0)
  let height = image_number(m, "height", 0)
  let stroke = image_number(m, "stroke", 3)
  let radius = tolerance + stroke / 2
  if kind == "arrow" {
    let x2 = image_number(m, "x2", x)
    let y2 = image_number(m, "y2", y)
    if segment_distance_squared(x, y, x2, y2, px, py) <= radius * radius { return true }
    let (ax, ay, bx, by) = arrowhead_points(x, y, x2, y2, stroke)
    return segment_distance_squared(ax, ay, x2, y2, px, py) <= radius * radius ||
      segment_distance_squared(bx, by, x2, y2, px, py) <= radius * radius
  }
  if kind == "ellipse" || (kind == "redact" && image_string(m, "shape", "rect") == "ellipse") {
    if width <= 0 || height <= 0 { return false }
    let dx = px - x - width / 2
    let dy = py - y - height / 2
    let rx = width / 2
    let ry = height / 2
    if kind == "redact" { return dx * dx / (rx * rx) + dy * dy / (ry * ry) <= 1 }
    let outer = dx * dx / ((rx + radius) * (rx + radius)) + dy * dy / ((ry + radius) * (ry + radius))
    if outer > 1 { return false }
    if rx <= radius || ry <= radius { return true }
    return dx * dx / ((rx - radius) * (rx - radius)) + dy * dy / ((ry - radius) * (ry - radius)) >= 1
  }
  if kind == "text" || kind == "redact" || kind == "mosaic" {
    return @selection.contains(x, y, width, height, px, py) != 0
  }
  kind == "rect" && @selection.border_contains(x, y, width, height, px, py, radius) != 0
}

///|
// Both front ends pass annotations validated by the same document reducer.
fn annotation_hit_index(
  annotations : Array[Json], px : Double, py : Double, tolerance : Double, text_only : Bool,
) -> Int {
  // Filled covers are painted above other annotations on every platform.
  for cover in [true, false] {
    for index = annotations.length() - 1; index >= 0; index = index - 1 {
      let annotation = match annotations[index] { Object(m) => m; _ => continue }
      let kind = image_string(annotation, "type", "")
      if (kind == "redact" || kind == "mosaic") != cover || (text_only && kind != "text") { continue }
      if annotation_contains(annotation, px, py, tolerance) { return index }
    }
  }
  -1
}

///|
pub fn image_selection(request : String) -> String {
  @protocol.response(() => {
    let fields = image_request(request)
    let action = image_string(fields, "action", "")
    let px = selection_number(fields, "x")
    let py = selection_number(fields, "y")
    if action == "hit" {
      let tolerance = selection_number(fields, "tolerance")
      if tolerance < 0 { raise InputError("invalid_input", "Invalid hit tolerance") }
      let annotations = image_array(fields, "annotations").map(annotation => image_annotation(annotation))
      let text_only = fields.get("textOnly") == Some(Json(true))
      let index = annotation_hit_index(annotations, px, py, tolerance, text_only)
      if index >= 0 {
        let annotation = match annotations[index] { Object(m) => m; _ => Map([]) }
        return Json::object({ "ok": Json(true), "document": Json::object({ "id": annotation.get("id").unwrap() }) })
      }
      // Once selected, an outlined box can also be dragged from its interior.
      // A visible object underneath still wins the normal hit pass above.
      let selected = image_string(fields, "selectedID", "")
      if !text_only && selected != "" {
        for raw in annotations {
          match raw {
            Object(m) => {
              if image_string(m, "id", "") == selected && ["rect", "ellipse"].contains(image_string(m, "type", "")) &&
                @selection.contains(image_number(m, "x", 0), image_number(m, "y", 0),
                  image_number(m, "width", 0), image_number(m, "height", 0), px, py) != 0 {
                return Json::object({ "ok": Json(true), "document": Json::object({ "id": Json(selected) }) })
              }
            }
            _ => ()
          }
        }
      }
      return Json::object({ "ok": Json(true), "document": Json::object({ "id": Json::null() }) })
    }
    if action != "transform" { raise InputError("invalid_input", "Unknown selection operation") }
    let raw = @protocol.object_field(fields, "annotation")
    let result = match image_annotation(Json::object(raw)) { Object(m) => image_copy(m); _ => Map([]) }
    let width = @protocol.integer_field(fields, "sourceWidth", 1, 32768)
    let height = @protocol.integer_field(fields, "sourceHeight", 1, 32768)
    let ax = selection_number(fields, "anchorX")
    let ay = selection_number(fields, "anchorY")
    let handle = @protocol.integer_field(fields, "handle", -1, 7).to_int()
    let x = image_number(result, "x", 0)
    let y = image_number(result, "y", 0)
    if image_string(result, "type", "") == "arrow" {
      let x2 = image_number(result, "x2", x)
      let y2 = image_number(result, "y2", y)
      if handle == 0 || handle == 4 {
        let key_x = if handle == 0 { "x" } else { "x2" }
        let key_y = if handle == 0 { "y" } else { "y2" }
        result[key_x] = Json(@protocol.larger(0, @protocol.smaller(width, image_number(result, key_x, 0) + px - ax)))
        result[key_y] = Json(@protocol.larger(0, @protocol.smaller(height, image_number(result, key_y, 0) + py - ay)))
      } else if handle < 0 {
        let moved = @selection.transform(x, y, x2 - x, y2 - y, ax, ay, px, py, -1, 0, 0, width, height, 0, directed=true)
        result["x"] = Json(moved[0]); result["y"] = Json(moved[1])
        result["x2"] = Json(moved[0] + moved[2]); result["y2"] = Json(moved[1] + moved[3])
      } else { raise InputError("invalid_input", "Arrows use endpoint handles") }
      result["width"] = Json(@protocol.larger(1, (image_number(result, "x2", 0) - image_number(result, "x", 0)).abs()))
      result["height"] = Json(@protocol.larger(1, (image_number(result, "y2", 0) - image_number(result, "y", 0)).abs()))
    } else {
      let rect = @selection.transform(x, y, image_number(result, "width", 1), image_number(result, "height", 1),
        ax, ay, px, py, handle, 0, 0, width, height, 2)
      result["x"] = Json(rect[0]); result["y"] = Json(rect[1]); result["width"] = Json(rect[2]); result["height"] = Json(rect[3])
    }
    Json::object({ "ok": Json(true), "document": image_annotation(Json::object(result)) })
  })
}
