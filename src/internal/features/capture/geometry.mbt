///|
/// Geometry-only adapter for native hosts. Keep persisted text and styles out
/// of the old pending-text/Int font path. -1 preserves font size; an explicit
/// positive font size is meaningful only for a text resize. Revision and ID
/// belong to the same gesture snapshot, not a mutable annotation index.
pub fn image_session_geometry(
  session : Int32,
  revision : Double,
  annotation_id : String,
  x : Double,
  y : Double,
  width : Double,
  height : Double,
  font_size : Double,
) -> Int32 {
  let s = match native_image_sessions.get(session) {
    Some(s) => s
    None => return 0
  }
  if image_session_revision(session) != revision ||
    text_active.contains(session) {
    return 0
  }
  let mut found : Map[String, Json]? = None
  for item in native_image_annotations(session) {
    if item is Object(a) && image_string(a, "id", "") == annotation_id {
      found = Some(a)
    }
  }
  let annotation = match found {
    Some(a) => a
    None => return 0
  }
  let kind = image_string(annotation, "type", "")
  if !["rect", "ellipse", "arrow", "redact", "mosaic", "text"].contains(kind) {
    return 0
  }
  // Validate before JSON encoding: NaN/Infinity must not become null in a patch.
  for value in [x, y, width, height] {
    if !(value >= -65536 && value <= 65536) {
      return 0
    }
  }
  if kind != "arrow" && !(width > 0 && height > 0) {
    return 0
  }
  let patch : Map[String, Json] = { "x": Json(x), "y": Json(y) }
  if kind == "arrow" {
    patch["x2"] = Json(x + width)
    patch["y2"] = Json(y + height)
    // Legacy arrow snapshots may also carry extent fields. Keep them coherent
    // without introducing unused fields into canonical endpoint-only arrows.
    if annotation.contains("width") {
      patch["width"] = Json(width)
    }
    if annotation.contains("height") {
      patch["height"] = Json(height)
    }
  } else {
    patch["width"] = Json(width)
    patch["height"] = Json(height)
  }
  if font_size != -1 {
    if kind != "text" || !@image.editor_style_value_valid(3, font_size) {
      return 0
    }
    patch["fontSize"] = Json(font_size)
  }
  let mut changed = false
  for key, value in patch {
    if annotation.get(key) != Some(value) {
      changed = true
    }
  }
  if !changed {
    return 1
  }
  native_image_command(
    s,
    Json::object({
      "type": Json("update"),
      "id": Json(annotation_id),
      "patch": Json::object(patch),
    }),
  )
}
