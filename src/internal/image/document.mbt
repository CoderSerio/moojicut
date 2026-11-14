using @json {type Json}

using @protocol {type InputError}

///|
// Image documents are data only: UI and agent use the same checked command reducer.
fn image_request(text : String) -> Map[String, Json] raise InputError {
  if text.length() > 33554432 { raise InputError("invalid_input", "Image request exceeds 32 MiB") }
  match (@json.parse(text, max_nesting_depth=32, reject_duplicate_keys=true) catch {
    _ => raise InputError("invalid_json", "Expected image JSON")
  }) {
    Object(fields) => fields
    _ => raise InputError("invalid_input", "Expected an image object")
  }
}

///|
fn image_string(m : Map[String, Json], key : String, fallback : String) -> String {
  match m.get(key) { Some(String(s)) => s; _ => fallback }
}

///|
fn image_number(m : Map[String, Json], key : String, fallback : Double) -> Double {
  match m.get(key) { Some(Number(n, ..)) => n; _ => fallback }
}

///|
fn image_array(m : Map[String, Json], key : String) -> Array[Json] raise InputError {
  match m.get(key) { Some(Array(a)) => a; _ => raise InputError("invalid_input", "\{key} must be an array") }
}

///|
fn image_copy(m : Map[String, Json]) -> Map[String, Json] {
  let result : Map[String, Json] = Map([])
  for key, value in m { result[key] = value }
  result
}

///|
fn image_rect(m : Map[String, Json], width : Double, height : Double) -> Json raise InputError {
  let x = @protocol.integer_field(m, "x", 0, width - 1)
  let y = @protocol.integer_field(m, "y", 0, height - 1)
  let w = @protocol.integer_field(m, "width", 1, width - x)
  let h = @protocol.integer_field(m, "height", 1, height - y)
  Json::object({ "x": Json(x), "y": Json(y), "width": Json(w), "height": Json(h) })
}

///|
fn image_annotation(raw : Json) -> Json raise InputError {
  let m = match raw { Object(m) => image_copy(m); _ => raise InputError("invalid_annotation", "Annotation must be an object") }
  let id = image_string(m, "id", "")
  if id == "" || id.length() > 160 { raise InputError("invalid_annotation", "Annotation requires a stable id") }
  let kind = image_string(m, "type", "")
  if !["rect", "ellipse", "arrow", "pencil", "marker", "redact", "mosaic", "text"].contains(kind) {
    raise InputError("invalid_annotation", "Unknown annotation type")
  }
  for key in ["x", "y"] {
    let n = image_number(m, key, 1.0 / 0.0)
    if !(n >= -65536 && n <= 65536) { raise InputError("invalid_annotation", "Invalid coordinate") }
  }
  for key in ["width", "height", "x2", "y2", "stroke", "opacity", "fontSize", "blockSize"] {
    if m.contains(key) {
      let n = image_number(m, key, 1.0 / 0.0)
      if !(n >= -65536 && n <= 65536) { raise InputError("invalid_annotation", "Invalid numeric style") }
    }
  }
  if kind == "rect" || kind == "ellipse" || kind == "redact" || kind == "mosaic" || kind == "text" {
    if image_number(m, "width", 0) <= 0 || image_number(m, "height", 0) <= 0 { raise InputError("invalid_annotation", "Positive dimensions required") }
  }
  if kind == "arrow" && (!m.contains("x2") || !m.contains("y2")) { raise InputError("invalid_annotation", "Arrow endpoints required") }
  if kind == "pencil" || kind == "marker" {
    let points = image_array(m, "points")
    if points.length() < 2 || points.length() > 12000 { raise InputError("invalid_annotation", "Stroke needs 2–12000 points") }
    for point in points {
      match point {
        Object(p) => {
          for key in ["x", "y"] {
            let n = image_number(p, key, 1.0 / 0.0)
            if !(n >= -65536 && n <= 65536) { raise InputError("invalid_annotation", "Invalid stroke point") }
          }
        }
        _ => raise InputError("invalid_annotation", "Invalid stroke point")
      }
    }
  }
  let opacity = image_number(m, "opacity", if kind == "marker" { 0.3 } else { 1.0 })
  if !@style.editor_style_value_valid(1, opacity) { raise InputError("invalid_annotation", "Opacity must be 0–1") }
  // Filled covers share editable RGBA style. Mosaic remains an opaque filter.
  m["opacity"] = Json(if kind == "mosaic" { 1.0 } else { opacity })
  let stroke = image_number(m, "stroke", if kind == "marker" { 24 } else { 3 })
  if !@style.editor_style_value_valid(2, stroke) { raise InputError("invalid_annotation", "Stroke must be 1–96 px") }
  m["stroke"] = Json(stroke)
  let color = image_string(m, "color", "#ef4444")
  if color.length() != 7 || !color.has_prefix("#") { raise InputError("invalid_annotation", "Expected #rrggbb color") }
  for index in 1..<7 {
    let c = color[index].to_int()
    if !((c >= 48 && c <= 57) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102)) { raise InputError("invalid_annotation", "Invalid color") }
  }
  m["color"] = Json(color)
  for key in ["fill", "dash", "bold"] {
    match m.get(key) { None | Some(True) | Some(False) => (); _ => raise InputError("invalid_annotation", "Boolean style required") }
  }
  if !["none", "end", "both"].contains(image_string(m, "arrowHead", "end")) { raise InputError("invalid_annotation", "Invalid arrow style") }
  if !["left", "center", "right"].contains(image_string(m, "align", "left")) { raise InputError("invalid_annotation", "Invalid text alignment") }
  if kind == "text" {
    let text = image_string(m, "text", "")
    if text == "" || text.length() > 10000 { raise InputError("invalid_annotation", "Text must have 1–10000 characters") }
    let size = image_number(m, "fontSize", 24)
    if !@style.editor_style_value_valid(3, size) { raise InputError("invalid_annotation", "Font size must be 8–128") }
    m["fontSize"] = Json(size)
  }
  if kind == "mosaic" {
    let block = image_number(m, "blockSize", 12)
    if block < 4 || block > 48 { raise InputError("invalid_annotation", "Mosaic block must be 4–48") }
    m["blockSize"] = Json(block)
  }
  Json::object(m)
}

///|
fn image_snapshot(doc : Map[String, Json]) -> Json {
  Json::object({ "annotations": doc.get("annotations").unwrap(), "viewport": doc.get("viewport").unwrap() })
}

///|
fn image_bounded_history(a : Array[Json]) -> Array[Json] {
  let result : Array[Json] = []
  for i in 0..<a.length() { if i >= a.length() - 100 { result.push(a[i]) } }
  result
}

///|
pub fn image_create(request : String) -> String {
  @protocol.response(() => {
    let m = image_request(request)
    let width = @protocol.integer_field(m, "width", 1, 32768)
    let height = @protocol.integer_field(m, "height", 1, 32768)
    let viewport = match m.get("viewport") {
      Some(Null) => Json::null()
      Some(Object(rect)) => image_rect(rect, width, height)
      _ => Json::object({ "x": Json(0), "y": Json(0), "width": Json(width), "height": Json(height) })
    }
    Json::object({ "ok": Json(true), "document": Json::object({
      "schemaVersion": Json(1), "width": Json(width), "height": Json(height), "revision": Json(0),
      "viewport": viewport, "annotations": Json::array([]), "undo": Json::array([]), "redo": Json::array([]),
    }) })
  })
}

///|
fn image_translate(raw : Json, dx : Double, dy : Double) -> Json raise InputError {
  let m = match raw { Object(m) => image_copy(m); _ => raise InputError("invalid_annotation", "Invalid annotation") }
  m["x"] = Json(image_number(m, "x", 0) + dx)
  m["y"] = Json(image_number(m, "y", 0) + dy)
  if m.contains("x2") { m["x2"] = Json(image_number(m, "x2", 0) + dx); m["y2"] = Json(image_number(m, "y2", 0) + dy) }
  match m.get("points") {
    Some(Array(points)) => m["points"] = Json::array(points.map(p => {
      match p { Object(p) => Json::object({ "x": Json(image_number(p, "x", 0) + dx), "y": Json(image_number(p, "y", 0) + dy) }); _ => p }
    }))
    _ => ()
  }
  image_annotation(Json::object(m))
}

///|
pub fn image_apply(request : String) -> String {
  @protocol.response(() => {
    let req = image_request(request)
    let doc = image_copy(@protocol.object_field(req, "document"))
    let width = @protocol.integer_field(doc, "width", 1, 32768)
    let height = @protocol.integer_field(doc, "height", 1, 32768)
    let revision = @protocol.integer_field(doc, "revision", 0, 9007199254740990)
    if req.contains("expectedRevision") && @protocol.integer_field(req, "expectedRevision", 0, 9007199254740990) != revision {
      raise InputError("revision_conflict", "Screenshot changed; read the latest revision")
    }
    let command = @protocol.object_field(req, "command")
    let kind = image_string(command, "type", "")
    let before = image_snapshot(doc)
    let annotations = image_array(doc, "annotations")
    let undo = image_array(doc, "undo")
    let redo = image_array(doc, "redo")
    if kind == "undo" || kind == "redo" {
      let from = if kind == "undo" { undo } else { redo }
      let to = if kind == "undo" { redo } else { undo }
      if from.length() == 0 { return Json::object({ "ok": Json(true), "document": Json::object(doc) }) }
      let snapshot = from.pop().unwrap()
      match snapshot {
        Object(s) => { doc["annotations"] = s.get("annotations").unwrap(); doc["viewport"] = s.get("viewport").unwrap() }
        _ => raise InputError("invalid_document", "Invalid history snapshot")
      }
      to.push(before)
    } else {
      let id = image_string(command, "id", "")
      let next : Array[Json] = []
      let mut found = false
      if kind == "crop" {
        doc["viewport"] = image_rect(@protocol.object_field(command, "rect"), width, height)
        for a in annotations { next.push(a) }
      } else if kind == "add" {
        for a in annotations { next.push(a) }
        for a in image_array(command, "annotations") {
          let valid = image_annotation(a)
          let aid = match valid { Object(m) => image_string(m, "id", ""); _ => "" }
          for old in next {
            match old { Object(m) => if image_string(m, "id", "") == aid { raise InputError("duplicate_id", "Annotation id already exists") }; _ => () }
          }
          next.push(valid)
        }
      } else if kind == "update" || kind == "resize" || kind == "move" || kind == "remove" || kind == "order" {
        let removals = if kind == "remove" { image_array(command, "ids") } else { [] }
        let mut ordered : Json = Json::null()
        for a in annotations {
          let am = match a { Object(m) => m; _ => raise InputError("invalid_document", "Invalid annotation") }
          let aid = image_string(am, "id", "")
          if kind == "remove" {
            if !removals.contains(Json(aid)) { next.push(a) } else { found = true }
          } else if aid != id { next.push(a) } else {
            found = true
            if kind == "move" {
              let dx = image_number(command, "dx", 0)
              let dy = image_number(command, "dy", 0)
              next.push(image_translate(a, dx, dy))
            } else if kind == "order" {
              let annotation_type = image_string(am, "type", "")
              if annotation_type == "redact" || annotation_type == "mosaic" { raise InputError("invalid_command", "Mask stacking is fixed") }
              ordered = a
            } else {
              let patch = @protocol.object_field(command, if kind == "resize" { "rect" } else { "patch" })
              let copy = image_copy(am)
              for key, value in patch { if key != "id" && key != "type" { copy[key] = value } }
              next.push(image_annotation(Json::object(copy)))
            }
          }
        }
        if !found { raise InputError("unknown_annotation", "Annotation no longer exists") }
        if kind == "order" {
          if image_string(command, "position", "front") == "back" { next.insert(0, ordered) } else { next.push(ordered) }
        }
      } else { raise InputError("invalid_command", "Unknown image command") }
      if next.length() > 1000 { raise InputError("document_limit", "Maximum 1000 annotations") }
      if kind != "crop" { doc["annotations"] = Json::array(next) }
      undo.push(before)
      redo.clear()
    }
    doc["undo"] = Json::array(image_bounded_history(undo))
    doc["redo"] = Json::array(image_bounded_history(redo))
    doc["revision"] = Json(revision + 1)
    Json::object({ "ok": Json(true), "document": Json::object(doc) })
  })
}

///|
pub fn image_finalize(request : String) -> String {
  @protocol.response(() => {
    let req = image_request(request)
    let doc = image_copy(@protocol.object_field(req, "document"))
    let v = @protocol.object_field(doc, "viewport")
    let x = image_number(v, "x", 0)
    let y = image_number(v, "y", 0)
    let width = image_number(v, "width", 0)
    let height = image_number(v, "height", 0)
    doc["annotations"] = Json::array(image_array(doc, "annotations").map(a => image_translate(a, -x, -y)))
    doc["width"] = Json(width); doc["height"] = Json(height)
    doc["viewport"] = Json::object({ "x": Json(0), "y": Json(0), "width": Json(width), "height": Json(height) })
    doc["undo"] = Json::array([]); doc["redo"] = Json::array([])
    doc["revision"] = Json(image_number(doc, "revision", 0) + 1)
    Json::object({ "ok": Json(true), "document": Json::object(doc) })
  })
}
