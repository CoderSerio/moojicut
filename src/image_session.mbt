///|
// A small typed C ABI for hosts without a JSON library. All mutations still
// pass through the same image reducer used by the macOS editor.
priv struct NativeImageSession {
  mut document : Map[String, Json]
  mut text : String
  mut next_annotation : Int
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
  if native_image_sessions.length() >= 16 { return 0 }
  let document = match native_image_document(image_create(request.stringify())) {
    Some(document) => document
    None => return 0
  }
  let id = native_image_next_id.val
  native_image_next_id.val = id + 1
  native_image_sessions[id] = { document, text: "文本", next_annotation: 1 }
  id
}

///|
#export_name("image_session_create")
pub fn image_session_create(width : Int, height : Int) -> Int {
  native_image_create(Json::object({ "width": Json(width), "height": Json(height) }))
}

///|
// Initial region selection is the document baseline, not an undoable edit.
#export_name("image_session_create_viewport")
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
  match native_image_document(image_apply(request.stringify())) {
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
#export_name("image_session_add")
pub fn image_session_add(
  id : Int, kind : Int, x : Int, y : Int, width : Int, height : Int,
  color : Int, stroke : Int,
) -> Int {
  image_session_add_styled(id, kind, x, y, width, height, color, stroke, 24)
}

///|
#export_name("image_session_add_styled")
pub fn image_session_add_styled(
  id : Int, kind : Int, x : Int, y : Int, width : Int, height : Int,
  color : Int, stroke : Int, font_size : Int,
) -> Int {
  let session = match native_image_sessions.get(id) { Some(value) => value; None => return 0 }
  if kind < 1 || kind > 4 || color < 0 || color > 16777215 { return 0 }
  let name = ["rect", "arrow", "text", "redact"][kind - 1]
  let annotation : Map[String, Json] = {
    "id": Json("native-\{session.next_annotation}"), "type": Json(name),
    "x": Json(x), "y": Json(y), "width": Json(width), "height": Json(height),
    "color": Json(native_image_color(color)), "stroke": Json(stroke), "opacity": Json(1),
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
#export_name("image_session_update")
pub fn image_session_update(
  id : Int, index : Int, x : Int, y : Int, width : Int, height : Int,
  color : Int, stroke : Int, font_size : Int,
) -> Int {
  let session = match native_image_sessions.get(id) { Some(value) => value; None => return 0 }
  let annotation = match native_image_annotation(id, index) { Some(value) => value; None => return 0 }
  if color < 0 || color > 16777215 { return 0 }
  let patch : Map[String, Json] = {
    "x": Json(x), "y": Json(y), "width": Json(width), "height": Json(height),
    "color": Json(native_image_color(color)), "stroke": Json(stroke),
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
#export_name("image_session_remove")
pub fn image_session_remove(id : Int, index : Int) -> Int {
  let session = match native_image_sessions.get(id) { Some(value) => value; None => return 0 }
  let annotation = match native_image_annotation(id, index) { Some(value) => value; None => return 0 }
  native_image_command(session, Json::object({
    "type": Json("remove"), "ids": Json::array([annotation["id"]]),
  }))
}

///|
#export_name("image_session_crop")
pub fn image_session_crop(id : Int, x : Int, y : Int, width : Int, height : Int) -> Int {
  let session = match native_image_sessions.get(id) { Some(value) => value; None => return 0 }
  let rect = Json::object({ "x": Json(x), "y": Json(y), "width": Json(width), "height": Json(height) })
  if session.document.get("viewport") == Some(rect) { return 1 }
  native_image_command(session, Json::object({ "type": Json("crop"), "rect": rect }))
}

///|
#export_name("image_session_viewport_value")
pub fn image_session_viewport_value(id : Int, field : Int) -> Double {
  let session = match native_image_sessions.get(id) { Some(value) => value; None => return 0 }
  let viewport = match session.document.get("viewport") { Some(Object(rect)) => rect; _ => return 0 }
  let key = match field { 0 => "x"; 1 => "y"; 2 => "width"; 3 => "height"; _ => return 0 }
  image_number(viewport, key, 0)
}

///|
#export_name("image_session_set_text")
pub fn image_session_set_text(id : Int, text : String) -> Int {
  let session = match native_image_sessions.get(id) { Some(value) => value; None => return 0 }
  if text.is_empty() || text.length() > 10000 { return 0 }
  session.text = text
  1
}

///|
#export_name("image_session_undo")
pub fn image_session_undo(id : Int) -> Int {
  let session = match native_image_sessions.get(id) { Some(value) => value; None => return 0 }
  native_image_command(session, Json::object({ "type": Json("undo") }))
}

///|
#export_name("image_session_redo")
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
#export_name("image_session_count")
pub fn image_session_count(id : Int) -> Int { native_image_annotations(id).length() }

///|
fn native_image_annotation(id : Int, index : Int) -> Map[String, Json]? {
  let items = native_image_annotations(id)
  if index < 0 || index >= items.length() { return None }
  match items[index] { Object(value) => Some(value); _ => None }
}

///|
#export_name("image_session_value")
pub fn image_session_value(id : Int, index : Int, field : Int) -> Double {
  let annotation = match native_image_annotation(id, index) { Some(value) => value; None => return 0 }
  if field == 0 {
    return match image_string(annotation, "type", "") {
      "rect" => 1; "arrow" => 2; "text" => 3; "redact" => 4; _ => 0
    }
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
  let key = match field { 1 => "x"; 2 => "y"; 3 => "width"; 4 => "height"; 6 => "stroke"; 7 => "fontSize"; _ => return 0 }
  image_number(annotation, key, 0)
}

///|
#export_name("image_session_text")
pub fn image_session_text(id : Int, index : Int) -> String {
  match native_image_annotation(id, index) {
    Some(value) => image_string(value, "text", "")
    None => ""
  }
}

///|
#export_name("image_session_dispose")
pub fn image_session_dispose(id : Int) -> Unit { native_image_sessions.remove(id) }
