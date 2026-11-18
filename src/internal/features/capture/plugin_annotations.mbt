///|
// Host allocation is independent of plugin-supplied data and of native tool
// counters. Cancelled candidates may consume IDs; IDs are never reused after
// undo, and allocation never changes the document or its history.
let plugin_annotation_batch : Ref[Int32] = Ref(1)

///|
// A ticket-local guard avoids changing the historical gesture semantics of
// property/toolbar candidates. candidate_retire_session removes this lease.
let plugin_annotation_gestures : Map[Int32, Int32] = Map([])

///|
fn plugin_annotation_color(value : Json?) -> String? {
  let color = match value {
    Some(String(color)) if color.length() == 7 && color[0] == '#' => color
    _ => return None
  }
  for index in 1..<7 {
    let c = color[index]
    if !((c >= '0' && c <= '9') ||
      (c >= 'a' && c <= 'f') ||
      (c >= 'A' && c <= 'F')) {
      return None
    }
  }
  Some(color.to_lower())
}

///|
fn plugin_annotation(
  raw : Json,
  viewport_x : Double,
  viewport_y : Double,
  viewport_width : Double,
  viewport_height : Double,
) -> Map[String, Json]? {
  let source = match raw {
    Object(source) => source
    _ => return None
  }
  let kind = image_string(source, "type", "")
  let keys = match kind {
    "rect" => ["type", "x", "y", "width", "height", "color", "stroke"]
    "text" => ["type", "x", "y", "width", "height", "color", "text", "fontSize"]
    _ => return None
  }
  if source.length() != keys.length() {
    return None
  }
  for key in keys {
    if !source.contains(key) {
      return None
    }
  }
  let x = image_number(source, "x", -1)
  let y = image_number(source, "y", -1)
  let width = image_number(source, "width", -1)
  let height = image_number(source, "height", -1)
  // Positive, bounded comparisons also reject NaN/infinity. Coordinates are
  // source pixels relative to the current cropped viewport, never screen/DPI.
  if !(x >= 0 &&
    y >= 0 &&
    width > 0 &&
    height > 0 &&
    x + width <= viewport_width &&
    y + height <= viewport_height) {
    return None
  }
  let color = match plugin_annotation_color(source.get("color")) {
    Some(color) => color
    None => return None
  }
  let annotation : Map[String, Json] = {
    "type": Json(kind),
    "x": Json(viewport_x + x),
    "y": Json(viewport_y + y),
    "width": Json(width),
    "height": Json(height),
    "color": Json(color),
  }
  if kind == "rect" {
    let stroke = image_number(source, "stroke", -1)
    if !(stroke >= 1 && stroke <= 24) {
      return None
    }
    annotation["stroke"] = Json(stroke)
  } else {
    let label = image_string(source, "text", "")
    if !@fields.valid_text(label, 80) || text_blank(label) {
      return None
    }
    for c in label {
      let code = c.to_int()
      if code < 32 || (code >= 127 && code <= 159) {
        return None
      }
    }
    let font = image_number(source, "fontSize", -1)
    if !(font >= 8 && font <= 96) {
      return None
    }
    annotation["text"] = Json(label)
    annotation["fontSize"] = Json(font)
  }
  Some(annotation)
}

///|
/// Prepare one atomic add command from a plugin's bounded annotation result.
/// Input is an exact array of 1–16 rect/text objects with viewport-relative
/// source-pixel geometry. Labels contain at most 80 UTF-16 code units, no C0/C1
/// controls and at least one non-whitespace character. Plugin IDs/style extras
/// are rejected; stable IDs are allocated by the host. Preparation changes no
/// document/defaults/history. Use ordinary candidate_ready/commit/close; stale
/// revisions and active property/text/IME/gesture drafts reject without loss.
pub fn image_session_prepare_plugin_annotations(
  session : Int32,
  revision : Double,
  annotations : String,
) -> Int32 {
  let current = match native_image_sessions.get(session) {
    Some(current) => current
    None => return 0
  }
  if image_session_revision(session) != revision ||
    text_active.contains(session) ||
    text_candidate_sessions.contains(session) ||
    @capture_ui.active(current.gesture) ||
    !@fields.valid_text(annotations, 65536) {
    return 0
  }
  let items = match
    (@json.parse(annotations, max_nesting_depth=8, reject_duplicate_keys=true) catch {
      _ => return 0
    }) {
    Array(items) if items.length() >= 1 && items.length() <= 16 => items
    _ => return 0
  }
  let viewport = match current.document.get("viewport") {
    Some(Object(viewport)) => viewport
    _ => return 0
  }
  let prepared : Array[Map[String, Json]] = []
  for item in items {
    match
      plugin_annotation(
        item,
        image_number(viewport, "x", 0),
        image_number(viewport, "y", 0),
        image_number(viewport, "width", 0),
        image_number(viewport, "height", 0),
      ) {
      Some(annotation) => prepared.push(annotation)
      None => return 0
    }
  }
  let existing : Map[String, Bool] = Map([])
  for item in native_image_annotations(session) {
    if item is Object(annotation) {
      existing[image_string(annotation, "id", "")] = true
    }
  }
  let mut batch = plugin_annotation_batch.val
  while batch < 2147483647 {
    let mut collision = false
    for i in 0..<prepared.length() {
      if existing.contains("plugin-\{batch}-\{i}") {
        collision = true
      }
    }
    if !collision {
      break
    }
    batch += 1
  }
  if batch >= 2147483647 {
    return 0
  }
  let result : Array[Json] = []
  for i in 0..<prepared.length() {
    prepared[i]["id"] = Json("plugin-\{batch}-\{i}")
    result.push(Json::object(prepared[i]))
  }
  let candidate = image_session_prepare_command(
    session,
    0,
    revision,
    Json::object({ "type": Json("add"), "annotations": Json::array(result) }).stringify(),
    "null",
  )
  if candidate > 0 {
    plugin_annotation_batch.val = batch + 1
    plugin_annotation_gestures[candidate] = current.gesture
  }
  candidate
}
