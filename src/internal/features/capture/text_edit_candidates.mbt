///|
priv struct StylePatch {
  tool : Int32
  values : Map[Int32, Double]
}

///|
priv struct TextCandidate {
  session : Int32
  revision : Double
  style : Int32
  style_revision : Int32
  edit : Int32
  edit_version : Int32
  purpose : Int32
  document : Map[String, Json]
  defaults : StylePatch?
}

///|
let text_candidates : Map[Int32, TextCandidate] = Map([])

///|
let text_candidate_sessions : Map[Int32, Int32] = Map([])

///|
let text_next_candidate : Ref[Int32] = Ref(1)

///|
fn candidate_retire_session(session : Int32) -> Unit {
  if text_candidate_sessions.get(session) is Some(ticket) {
    text_candidates.remove(ticket)
    text_candidate_sessions.remove(session)
  }
}

///|
fn candidate_store(candidate : TextCandidate) -> Int32 {
  if text_next_candidate.val >= 2147483647 {
    return 0
  }
  let ticket = text_next_candidate.val
  text_next_candidate.val += 1
  candidate_retire_session(candidate.session)
  text_candidate_sessions[candidate.session] = ticket
  text_candidates[ticket] = candidate
  ticket
}

///|
fn candidate_apply(
  document : Map[String, Json],
  command : Json,
) -> Map[String, Json]? {
  if command == Json::null() {
    return Some(document)
  }
  native_image_document(
    @image.image_apply(
      Json::object({
        "document": Json::object(document),
        "expectedRevision": document["revision"],
        "command": command,
      }).stringify(),
    ),
  )
}

///|
fn text_copy(source : Map[String, Json]) -> Map[String, Json] {
  let result : Map[String, Json] = Map([])
  for key, value in source {
    result[key] = value
  }
  result
}

///|
fn style_patch_changed(style : Int32, patch : StylePatch) -> Bool {
  for key, value in patch.values {
    if editor_style_get(style, patch.tool, key) != value {
      return true
    }
  }
  false
}

///|
/// Pure layout feedback for this exact draft version. Composition and numeric
/// intermediate input may still be displayed using the validated preview style.
/// Existing text keeps its original rectangle until body or font size changes;
/// color/opacity and equivalent LF drafts never resize a manually adjusted box.
/// This never stores geometry or changes draft/document/history.
pub fn text_measured_height(
  session : Int32,
  edit : Int32,
  version : Int32,
  measurement : Double,
) -> Double {
  let e = match text_current(session, edit) {
    Some(e) => e
    None => return -1
  }
  if !text_fresh(e) || e.version != version {
    return -1
  }
  if e.mode == 0 {
    return 0
  }
  if e.mode == 2 &&
    text_raw(e.body) == e.initial_body &&
    e.preview_font == e.initial_font {
    return e.height
  }
  if !(measurement > 0 && measurement <= 65536) {
    return -1
  }
  let height = @protocol.smaller(
    measurement,
    image_number(native_image_sessions[session].document, "height", 0) - e.y,
  )
  if height > 0 {
    height
  } else {
    -1
  }
}

///|
/// Preparation is read-only. Native text measurement belongs to this exact
/// version, in source pixels. A preview candidate can never be published.
pub fn text_prepare(
  session : Int32,
  edit : Int32,
  version : Int32,
  purpose : Int32,
  measured_height : Double,
) -> Int32 {
  let e = match text_current(session, edit) {
    Some(e) => e
    None => return 0
  }
  if e.version != version ||
    (purpose != 0 && purpose != 1) ||
    text_error(e) != "" {
    return 0
  }
  let s = native_image_sessions[session]
  let raw = text_raw(e.body)
  let text = if e.mode == 2 && raw == e.initial_body {
    match e.original {
      Object(a) => image_string(a, "text", raw)
      _ => raw
    }
  } else {
    raw
  }
  let opacity = match @fields.snapshot(e.opacity) {
    Some(s) => text_edit_numeric(e, s, 1).unwrap()
    None => return 0
  }
  let font = match @fields.snapshot(e.font) {
    Some(s) => text_edit_numeric(e, s, 3).unwrap()
    None => return 0
  }
  let mut command = Json::null()
  if e.mode != 0 {
    if text_blank(text) {
      if e.mode == 2 {
        command = Json::object({
          "type": Json("remove"),
          "ids": Json::array([Json(e.annotation_id)]),
        })
      }
    } else {
      let height = text_measured_height(session, edit, version, measured_height)
      if height <= 0 {
        return 0
      }
      let annotation = match e.original {
        Object(a) => text_copy(a)
        _ => Map([])
      }
      annotation["id"] = Json(e.annotation_id)
      annotation["type"] = Json("text")
      annotation["x"] = Json(e.x)
      annotation["y"] = Json(e.y)
      annotation["width"] = Json(e.width)
      annotation["height"] = Json(height)
      annotation["text"] = Json(text)
      annotation["fontSize"] = Json(font)
      if e.mode != 2 ||
        native_annotation_value(annotation, 5).to_int() != e.color {
        annotation["color"] = Json(native_image_color(e.color))
      }
      annotation["opacity"] = Json(opacity)
      if e.mode == 1 {
        annotation["stroke"] = Json(3)
      }
      if e.mode == 1 {
        command = Json::object({
          "type": Json("add"),
          "annotations": Json::array([Json::object(annotation)]),
        })
      } else if Json::object(annotation) != e.original {
        command = Json::object({
          "type": Json("update"),
          "id": Json(e.annotation_id),
          "patch": Json::object(annotation),
        })
      }
    }
  }
  let document = match candidate_apply(s.document, command) {
    Some(d) => d
    None => return 0
  }
  let defaults = if e.mode != 2 {
    let patch : StylePatch = {
      tool: 3,
      values: { 0: e.color.to_double(), 1: opacity, 3: font },
    }
    if style_patch_changed(e.style, patch) {
      if e.style_revision >= 2147483647 {
        return 0
      }
      Some(patch)
    } else {
      None
    }
  } else {
    None
  }
  candidate_store({
    session,
    revision: e.base_revision,
    style: e.style,
    style_revision: e.style_revision,
    edit,
    edit_version: version,
    purpose,
    document,
    defaults,
  })
}

///|
pub fn candidate_document(ticket : Int32) -> String {
  match text_candidates.get(ticket) {
    Some(c) => Json::object(c.document).stringify()
    None => ""
  }
}

///|
pub fn candidate_ready(session : Int32, ticket : Int32) -> Int32 {
  let c = match text_candidates.get(ticket) {
    Some(c) if c.session == session => c
    _ => return 0
  }
  if text_candidate_sessions.get(session) != Some(ticket) ||
    image_session_revision(session) != c.revision {
    return 0
  }
  if c.style != 0 {
    match editor_style_sessions.get(c.style) {
      Some(bank) if bank.revision == c.style_revision => ()
      _ => return 0
    }
  }
  if c.edit != 0 {
    match text_current(session, c.edit) {
      Some(e) if e.version == c.edit_version && text_fresh(e) => ()
      _ => return 0
    }
  } else if text_active.contains(session) {
    return 0
  }
  1
}

///|
pub fn candidate_close(ticket : Int32) -> Int32 {
  match text_candidates.get(ticket) {
    Some(c) => {
      candidate_retire_session(c.session)
      1
    }
    None => 0
  }
}

///|
fn candidate_publish(c : TextCandidate) -> Unit {
  // All validation/allocation precedes this block. No host callback is invoked.
  native_image_sessions[c.session].document = c.document
  if c.defaults is Some(patch) {
    let bank = editor_style_sessions[c.style]
    let values = bank.tools[patch.tool]
    for key, value in patch.values {
      match key {
        0 => values.color = value.to_int()
        1 => values.opacity = value
        2 => values.stroke = value
        3 => values.font = value
        4 => values.shape = value
        5 => values.block = value
        _ => () // checked before candidate creation
      }
    }
    bank.revision += 1
  }
  if c.edit != 0 {
    text_retire(c.edit)
  }
  candidate_retire_session(c.session)
}

///|
pub fn candidate_commit(session : Int32, ticket : Int32) -> Int32 {
  if candidate_ready(session, ticket) == 0 {
    return 0
  }
  let c = text_candidates[ticket]
  if c.purpose != 1 {
    return 0
  }
  candidate_publish(c)
  1
}

///|
/// A configuration coordinator uses one checked operation after storage succeeds.
/// Duplicate sessions or conflicting writes to one style bank reject atomically.
pub fn candidate_commit_many(request : String) -> Int32 {
  let requests = match (text_json(request, 65536) catch { _ => return 0 }) {
    Array(items) if items.length() > 0 && items.length() <= 16 => items
    _ => return 0
  }
  let checked : Array[TextCandidate] = []
  let sessions : Map[Int32, Bool] = Map([])
  let styles : Map[Int32, Bool] = Map([])
  for request in requests {
    let request = match request {
      Object(m) => m
      _ => return 0
    }
    let session = (@protocol.integer_field(request, "session", 1, 2147483646) catch {
      _ => return 0
    }).to_int()
    let ticket = (@protocol.integer_field(request, "candidate", 1, 2147483646) catch {
      _ => return 0
    }).to_int()
    if sessions.contains(session) || candidate_ready(session, ticket) == 0 {
      return 0
    }
    let c = text_candidates[ticket]
    if c.purpose != 1 {
      return 0
    }
    if c.defaults is Some(_) {
      if styles.contains(c.style) {
        return 0
      }
      styles[c.style] = true
    }
    sessions[session] = true
    checked.push(c)
  }
  for c in checked {
    candidate_publish(c)
  }
  1
}

///|
pub fn image_session_prepare_command(
  session : Int32,
  style : Int32,
  revision : Double,
  command : String,
  defaults : String,
) -> Int32 {
  let s = match native_image_sessions.get(session) {
    Some(s) => s
    None => return 0
  }
  if text_active.contains(session) ||
    image_session_revision(session) != revision {
    return 0
  }
  let style_revision = if style == 0 {
    0
  } else {
    match editor_style_sessions.get(style) {
      Some(bank) => bank.revision
      None => return 0
    }
  }
  let command = text_json(command, 33554432) catch { _ => return 0 }
  if !(command is Object(_) || command is Null) {
    return 0
  }
  let defaults = text_json(defaults, 65536) catch { _ => return 0 }
  let patch = match defaults {
    Null => None
    Object(m) => {
      if style == 0 {
        return 0
      }
      let tool = (@protocol.integer_field(m, "tool", 0, 4) catch {
        _ => return 0
      }).to_int()
      let values = @protocol.object_field(m, "values") catch { _ => return 0 }
      let checked : Map[Int32, Double] = Map([])
      for key, raw in values {
        let property = match key {
          "0" => 0
          "1" => 1
          "2" => 2
          "3" => 3
          "4" => 4
          "5" => 5
          _ => return 0
        }
        let value = match raw {
          Number(value, ..) => value
          _ => return 0
        }
        if !@image.editor_style_value_valid(property, value) ||
          (@annotation_tools.editor_style_property_mask(tool) & (1 << property)) ==
          0 ||
          (
            property == 4 &&
            value >=
            @annotation_tools.editor_style_shape_count(tool).to_double()
          ) {
          return 0
        }
        checked[property] = value
      }
      let patch : StylePatch = { tool, values: checked, }
      if style_patch_changed(style, patch) {
        if style_revision >= 2147483647 {
          return 0
        }
        Some(patch)
      } else {
        None
      }
    }
    _ => return 0
  }
  let document = match candidate_apply(s.document, command) {
    Some(doc) => doc
    None => return 0
  }
  candidate_store({
    session,
    revision,
    style,
    style_revision,
    edit: 0,
    edit_version: 0,
    purpose: 1,
    document,
    defaults: patch,
  })
}
