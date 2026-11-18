using @json {type Json}

///|
fn image_string(m : Map[String, Json], key : String, fallback : String) -> String {
  match m.get(key) { Some(String(s)) => s; _ => fallback }
}

///|
fn image_number(m : Map[String, Json], key : String, fallback : Double) -> Double {
  match m.get(key) { Some(Number(n, ..)) => n; _ => fallback }
}

///|
// A small typed C ABI for hosts without a JSON library. All mutations still
// pass through the same image reducer used by the macOS editor.
priv struct NativeImageSession {
  mut document : Map[String, Json]
  mut text : String
  mut next_annotation : Int
  gesture : Int
  mut preview : Json
  mut contribution : String
  mut gesture_revision : Json
}

///|
let native_image_sessions : Map[Int, NativeImageSession] = Map([])

///|
let native_image_next_id : Ref[Int] = Ref(1)

///|
fn native_image_document(result : String) -> Map[String, Json]? {
  let parsed = @json.parse(result) catch { _ => return None }
  match parsed {
    Object({ "ok": True, "document": Object(document), .. }) => Some(document)
    _ => None
  }
}

///|
fn native_image_create(request : Json) -> Int {
  if native_image_sessions.length() >= 16 || native_image_next_id.val >= 2147483647 { return 0 }
  let document = match native_image_document(@image.image_create(request.stringify())) {
    Some(document) => document
    None => return 0
  }
  let id = native_image_next_id.val
  native_image_next_id.val = id + 1
  let gesture = @capture_ui.open(image_number(document, "width", 0), image_number(document, "height", 0))
  if gesture == 0 { return 0 }
  native_image_sessions[id] = { document, text: "文本", next_annotation: 1, gesture, preview: Json::null(),
    contribution: "", gesture_revision: Json::null() }
  id
}

///|
pub fn image_session_create(width : Int, height : Int) -> Int {
  native_image_create(Json::object({ "width": Json(width), "height": Json(height) }))
}

///|
// Initial region selection is the document baseline, not an undoable edit.
pub fn image_session_create_viewport(
  width : Int, height : Int, x : Int, y : Int, viewport_width : Int, viewport_height : Int,
) -> Int {
  native_image_create(Json::object({
    "width": Json(width), "height": Json(height),
    "viewport": Json::object({ "x": Json(x), "y": Json(y), "width": Json(viewport_width), "height": Json(viewport_height) }),
  }))
}

///|
fn native_image_command(session : NativeImageSession, command : Json) -> Int {
  let request = Json::object({
    "document": Json::object(session.document),
    "expectedRevision": session.document["revision"], "command": command,
  })
  match native_image_document(@image.image_apply(request.stringify())) {
    Some(document) => { session.document = document; 1 }
    None => 0
  }
}

///|
fn native_image_color(color : Int) -> String {
  let digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
  let mut value = color
  let mut result = ""
  for _ in 0..<6 {
    result = digits[value % 16] + result
    value = value / 16
  }
  "#" + result
}

///|
pub fn image_session_add(
  id : Int, kind : Int, x : Int, y : Int, width : Int, height : Int,
  color : Int, stroke : Int,
) -> Int {
  image_session_add_styled(id, kind, x, y, width, height, color, stroke, 24)
}

///|
pub fn image_session_add_styled(
  id : Int, kind : Int, x : Int, y : Int, width : Int, height : Int,
  color : Int, stroke : Int, font_size : Int,
) -> Int {
  image_session_add_rgba(id, kind, x, y, width, height, color, stroke, font_size, 1)
}

///|
pub fn image_session_add_rgba(
  id : Int, kind : Int, x : Int, y : Int, width : Int, height : Int,
  color : Int, stroke : Int, font_size : Int, opacity : Double,
) -> Int {
  let session = match native_image_sessions.get(id) { Some(value) => value; None => return 0 }
  if kind < 1 || kind > 4 || color < 0 || color > 16777215 || !(opacity >= 0 && opacity <= 1) { return 0 }
  let name = ["rect", "arrow", "text", "redact"][kind - 1]
  let annotation : Map[String, Json] = {
    "id": Json("native-\{session.next_annotation}"), "type": Json(name),
    "x": Json(x), "y": Json(y), "width": Json(width), "height": Json(height),
    "color": Json(native_image_color(color)), "stroke": Json(stroke), "opacity": Json(opacity),
  }
  if kind == 2 {
    annotation["x2"] = Json(x.to_double() + width.to_double())
    annotation["y2"] = Json(y.to_double() + height.to_double())
  }
  if kind == 3 { annotation["text"] = Json(session.text); annotation["fontSize"] = Json(font_size) }
  let result = native_image_command(session, Json::object({
    "type": Json("add"), "annotations": Json::array([Json::object(annotation)]),
  }))
  if result == 1 { session.next_annotation = session.next_annotation + 1 }
  result
}

///|
// Hosts keep live drag/typing drafts outside the document, then commit once.
pub fn image_session_update(
  id : Int, index : Int, x : Int, y : Int, width : Int, height : Int,
  color : Int, stroke : Int, font_size : Int,
) -> Int {
  let annotation = match native_image_annotation(id, index) { Some(value) => value; None => return 0 }
  image_session_update_rgba(id, index, x, y, width, height, color, stroke, font_size,
    image_number(annotation, "opacity", 1))
}

///|
pub fn image_session_update_rgba(
  id : Int, index : Int, x : Int, y : Int, width : Int, height : Int,
  color : Int, stroke : Int, font_size : Int, opacity : Double,
) -> Int {
  let session = match native_image_sessions.get(id) { Some(value) => value; None => return 0 }
  let annotation = match native_image_annotation(id, index) { Some(value) => value; None => return 0 }
  if color < 0 || color > 16777215 || !(opacity >= 0 && opacity <= 1) { return 0 }
  let patch : Map[String, Json] = {
    "x": Json(x), "y": Json(y), "width": Json(width), "height": Json(height),
    "color": Json(native_image_color(color)), "stroke": Json(stroke), "opacity": Json(opacity),
  }
  let kind = image_string(annotation, "type", "")
  if kind == "arrow" {
    patch["x2"] = Json(x.to_double() + width.to_double())
    patch["y2"] = Json(y.to_double() + height.to_double())
  }
  if kind == "text" { patch["text"] = Json(session.text); patch["fontSize"] = Json(font_size) }
  // Clicking a selection or finishing unchanged text must not consume undo.
  let mut changed = false
  for key, value in patch {
    if annotation.get(key) != Some(value) { changed = true }
  }
  if !changed { return 1 }
  native_image_command(session, Json::object({
    "type": Json("update"), "id": annotation["id"], "patch": Json::object(patch),
  }))
}

///|
pub fn image_session_remove(id : Int, index : Int) -> Int {
  let session = match native_image_sessions.get(id) { Some(value) => value; None => return 0 }
  let annotation = match native_image_annotation(id, index) { Some(value) => value; None => return 0 }
  native_image_command(session, Json::object({
    "type": Json("remove"), "ids": Json::array([annotation["id"]]),
  }))
}

///|
pub fn image_session_crop(id : Int, x : Int, y : Int, width : Int, height : Int) -> Int {
  let session = match native_image_sessions.get(id) { Some(value) => value; None => return 0 }
  let rect = Json::object({ "x": Json(x), "y": Json(y), "width": Json(width), "height": Json(height) })
  if session.document.get("viewport") == Some(rect) { return 1 }
  native_image_command(session, Json::object({ "type": Json("crop"), "rect": rect }))
}

///|
pub fn image_session_viewport_value(id : Int, field : Int) -> Double {
  let session = match native_image_sessions.get(id) { Some(value) => value; None => return 0 }
  let viewport = match session.document.get("viewport") { Some(Object(rect)) => rect; _ => return 0 }
  let key = match field { 0 => "x"; 1 => "y"; 2 => "width"; 3 => "height"; _ => return 0 }
  image_number(viewport, key, 0)
}

///|
pub fn image_session_set_text(id : Int, text : String) -> Int {
  let session = match native_image_sessions.get(id) { Some(value) => value; None => return 0 }
  if text.is_empty() || text.length() > 10000 { return 0 }
  session.text = text
  1
}

///|
pub fn image_session_undo(id : Int) -> Int {
  let session = match native_image_sessions.get(id) { Some(value) => value; None => return 0 }
  native_image_command(session, Json::object({ "type": Json("undo") }))
}

///|
pub fn image_session_redo(id : Int) -> Int {
  let session = match native_image_sessions.get(id) { Some(value) => value; None => return 0 }
  native_image_command(session, Json::object({ "type": Json("redo") }))
}

///|
fn native_image_annotations(id : Int) -> Array[Json] {
  match native_image_sessions.get(id) {
    Some(session) => match session.document.get("annotations") {
      Some(Array(items)) => items
      _ => []
    }
    None => []
  }
}

///|
pub fn image_session_count(id : Int) -> Int { native_image_annotations(id).length() }

///|
pub fn image_session_hit(id : Int, x : Double, y : Double, tolerance : Double, text_only : Int) -> Int {
  if !(x >= -65536 && x <= 65536 && y >= -65536 && y <= 65536 &&
       tolerance >= 0 && tolerance <= 65536) || (text_only != 0 && text_only != 1) { return -1 }
  @image.image_hit_index(native_image_annotations(id), x, y, tolerance, text_only == 1)
}

///|
fn native_image_annotation(id : Int, index : Int) -> Map[String, Json]? {
  let items = native_image_annotations(id)
  if index < 0 || index >= items.length() { return None }
  match items[index] { Object(value) => Some(value); _ => None }
}

///|
pub fn image_session_value(id : Int, index : Int, field : Int) -> Double {
  let annotation = match native_image_annotation(id, index) { Some(value) => value; None => return 0 }
  native_annotation_value(annotation, field)
}

///|
fn native_annotation_value(annotation : Map[String, Json], field : Int) -> Double {
  let kind = image_string(annotation, "type", "")
  if field == 0 {
    return match kind {
      "rect" | "ellipse" => 1; "arrow" => 2; "text" => 3; "redact" | "mosaic" => 4; _ => 0
    }
  }
  if field == 9 {
    return if kind == "mosaic" { 2 } else if kind == "ellipse" || image_string(annotation, "shape", "") == "ellipse" { 1 } else { 0 }
  }
  if field == 10 { return image_number(annotation, "blockSize", 12) }
  if kind == "arrow" && (field == 3 || field == 4) {
    return if field == 3 { image_number(annotation, "x2", 0) - image_number(annotation, "x", 0) }
      else { image_number(annotation, "y2", 0) - image_number(annotation, "y", 0) }
  }
  if field == 5 {
    let color = image_string(annotation, "color", "#000000")
    let mut number = 0
    for i in 1..<7 {
      let c = color[i].to_int()
      let digit = if c <= 57 { c - 48 } else if c <= 70 { c - 55 } else { c - 87 }
      number = number * 16 + digit
    }
    return number.to_double()
  }
  if field == 8 { return image_number(annotation, "opacity", 1) }
  let key = match field { 1 => "x"; 2 => "y"; 3 => "width"; 4 => "height"; 6 => "stroke"; 7 => "fontSize"; _ => return 0 }
  image_number(annotation, key, 0)
}

///|
pub fn image_session_text(id : Int, index : Int) -> String {
  match native_image_annotation(id, index) {
    Some(value) => image_string(value, "text", "")
    None => ""
  }
}

///|
pub fn image_session_dispose(id : Int) -> Unit {
  if capture_toolbar_owners.get(id) is Some(toolbar) {
    ignore(toolbar_close(toolbar))
  }
  text_dispose_session(id)
  if native_image_sessions.get(id) is Some(session) { @capture_ui.close(session.gesture) }
  native_image_sessions.remove(id)
}

///|
/// Read-only authoritative document snapshot; never accepts a host document.
pub fn image_session_document(id : Int) -> String {
  match native_image_sessions.get(id) {
    Some(s) => Json::object(s.document).stringify()
    None => ""
  }
}

///|
pub fn image_session_revision(id : Int) -> Double {
  match native_image_sessions.get(id) {
    Some(s) => image_number(s.document, "revision", 0)
    None => -1
  }
}

///|
pub fn image_session_annotation_id(id : Int, index : Int) -> String {
  match native_image_annotation(id, index) {
    Some(a) => image_string(a, "id", "")
    None => ""
  }
}

///|
pub fn image_session_command(id : Int, revision : Double, command : String) -> Int {
  let s = match native_image_sessions.get(id) { Some(s) => s; None => return 0 }
  if image_session_revision(id) != revision { return 0 }
  let command = text_json(command, 33554432) catch { _ => return 0 }
  if !(command is Object(_)) { return 0 }
  native_image_command(s, command)
}

///|
// Typed adapter to the SAME gesture reducer as the macOS JSON host. The core
// freezes style at begin; only end mutates the image document / undo stack.
pub fn image_session_shape_begin(id : Int, kind : Int, x : Double, y : Double,
  color : Int, stroke : Double, opacity : Double, shape : Int, block : Double) -> Int {
  let s = match native_image_sessions.get(id) { Some(s) => s; None => return 0 }
  if color < 0 || color > 16777215 { return 0 }
  let result = @json.parse(@capture_ui.event(Json::object({
    "session": Json(s.gesture), "type": Json("begin"), "id": Json("native-\{s.next_annotation}"),
    "kind": Json(kind), "x": Json(x), "y": Json(y), "color": Json(native_image_color(color)),
    "stroke": Json(stroke), "opacity": Json(opacity), "shape": Json(shape), "blockSize": Json(block),
    "shapeCount": Json(@annotation_tools.editor_style_shape_count(kind)),
  }).stringify())) catch { _ => return 0 }
  match result { Object({ "ok": True, .. }) => {
    s.preview = Json::null(); s.contribution = ""; s.gesture_revision = s.document["revision"]; 1
  }; _ => 0 }
}

///|
// The descriptor's dragRect interaction reuses rectangle input and rendering;
// the feature handler builds a checked, atomic document command at gesture end.
pub fn image_session_tool_begin(id : Int, command : String, x : Double, y : Double,
  color : Int, stroke : Double, opacity : Double, _shape : Int, block : Double) -> Int {
  if command != "capture.numberedRectangle" { return 0 }
  if image_session_shape_begin(id, 1, x, y, color, stroke, opacity, 0, block) == 0 { return 0 }
  native_image_sessions[id].contribution = command
  1
}

///|
// phase: 0=move, 1=end, 2=cancel. A no-area end succeeds without adding history.
pub fn image_session_shape_event(id : Int, phase : Int, x : Double, y : Double) -> Int {
  let s = match native_image_sessions.get(id) { Some(s) => s; None => return 0 }
  let name = match phase { 0 => "move"; 1 => "end"; 2 => "cancel"; _ => return 0 }
  let result = @json.parse(@capture_ui.event(Json::object({
    "session": Json(s.gesture), "type": Json(name), "x": Json(x), "y": Json(y),
  }).stringify())) catch { _ => return 0 }
  match result {
    Object({ "ok": True, "preview": preview, "command": command, .. }) => {
      s.preview = preview
      if command != Json::null() {
        let contribution = s.contribution
        s.contribution = ""
        if s.gesture_revision != s.document["revision"] { return 0 }
        let command = if contribution == "" { command } else {
          let rectangle = match command { Object({ "annotations": Array(items), .. }) if items.length() == 1 => items[0]; _ => return 0 }
          @annotation_tools.contribution_drag_command(contribution, rectangle, native_image_annotations(id)) catch { _ => return 0 }
        }
        let applied = native_image_command(s, command)
        if applied == 1 { s.next_annotation += 1 }
        applied
      } else { if phase != 0 { s.contribution = "" }; 1 }
    }
    _ => 0
  }
}

///|
pub fn image_session_preview_value(id : Int, field : Int) -> Double {
  match native_image_sessions.get(id) {
    Some({ preview: Object(annotation), .. }) => native_annotation_value(annotation, field)
    _ => 0
  }
}

///|
pub fn image_session_set_variant(id : Int, index : Int, field : Int, value : Double) -> Int {
  let s = match native_image_sessions.get(id) { Some(s) => s; None => return 0 }
  let annotation = match native_image_annotation(id, index) { Some(a) => a; None => return 0 }
  if !@image.editor_style_value_valid(field, value) { return 0 }
  let kind = native_annotation_value(annotation, 0).to_int()
  if field == 4 {
    if value >= @annotation_tools.editor_style_shape_count(kind).to_double() { return 0 }
    if native_annotation_value(annotation, 9) == value { return 1 }
    native_image_command(s, Json::object({ "type": Json("setShape"), "id": annotation["id"], "shape": Json(value) }))
  } else if field == 5 && image_string(annotation, "type", "") == "mosaic" {
    if native_annotation_value(annotation, 10) == value { return 1 }
    native_image_command(s, Json::object({ "type": Json("update"), "id": annotation["id"],
      "patch": Json::object({ "blockSize": Json(value) }) }))
  } else { 0 }
}
