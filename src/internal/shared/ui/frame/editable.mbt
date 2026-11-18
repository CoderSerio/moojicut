///|
priv struct Editable {
  integers : Array[Int32]
  numbers : Array[Double]
  texts : Array[String]
}

///|
fn integer(
  fields : Map[String, Json],
  key : String,
  low : Int32,
  high : Int32,
) -> Int32 raise InputError {
  let n = number(fields, key, low.to_double(), high.to_double(), None)
  let value = n.to_int()
  if value.to_double() != n {
    raise InputError("invalid_frame", "Expected integer \{key}")
  }
  value
}

///|
fn canonical_text(text : String, maximum : Int32) -> Bool {
  if !@edit_fields.valid_text(text, maximum) {
    return false
  }
  for unit in text.code_units() {
    if unit == 13 {
      return false
    }
  }
  true
}

///|
fn editable_field(value : Json) -> Editable raise InputError {
  let fields = object(value)
  let id = string(fields, "id", 256, None)
  let raw = string(fields, "raw", 32768, None)
  if id.is_empty() ||
    !@edit_fields.valid_text(id, 256) ||
    !canonical_text(raw, 32768) {
    raise InputError(
      "invalid_frame", "Invalid field identity or canonical UTF-16 text",
    )
  }
  let rect = rectangle(fields)
  let clip = match fields.get("clip") {
    None => rect
    Some(value) => rectangle(object(value))
  }
  let size = number(fields, "fontSize", 0.000001, 4096, None)
  let opacity = number(fields, "opacity", 0, 1, Some(1))
  let enabled = boolean(fields, "enabled", true)
  let focused = boolean(fields, "focused", false)
  if focused == 1 && enabled == 0 {
    raise InputError("invalid_frame", "Disabled field cannot own focus")
  }
  let integers = [
    integer(fields, "token", 1, 2147483646),
    integer(fields, "version", 0, 2147483647),
    enabled,
    boolean(fields, "readOnly", false),
    focused,
    boolean(fields, "multiline", false),
    0,
    0,
    0,
    0,
    -1,
    -1,
    color(fields, "color", false),
    boolean(fields, "canUndo", false),
    boolean(fields, "canRedo", false),
    enum_string(
      fields,
      "weight",
      ["regular", "medium", "bold", "semibold"],
      "regular",
    ),
    color(fields, "background", true),
  ]
  let selection = object(fields.get("selection").unwrap_or(Json::null()))
  let kind = string(selection, "kind", 16, None)
  match kind {
    "unknown" =>
      if selection.contains("anchor") || selection.contains("focus") {
        raise InputError("invalid_frame", "Unknown selection has no offsets")
      }
    "directed" | "undirected" => {
      let anchor = integer(selection, "anchor", 0, raw.length())
      let focus = integer(selection, "focus", 0, raw.length())
      if !@edit_fields.boundary(raw, anchor) ||
        !@edit_fields.boundary(raw, focus) ||
        (kind == "undirected" && anchor > focus) {
        raise InputError("invalid_frame", "Invalid UTF-16 selection")
      }
      integers[6] = 1
      integers[7] = if kind == "directed" { 1 } else { 0 }
      integers[8] = anchor
      integers[9] = focus
    }
    _ => raise InputError("invalid_frame", "Unknown selection kind")
  }
  match fields.get("marked") {
    None | Some(Null) => ()
    Some(value) => {
      let marked = object(value)
      let start = integer(marked, "start", 0, raw.length())
      let end = integer(marked, "end", 0, raw.length())
      if start > end ||
        !@edit_fields.boundary(raw, start) ||
        !@edit_fields.boundary(raw, end) ||
        (
          integers[6] == 1 &&
          (
            integers[8] < start ||
            integers[8] > end ||
            integers[9] < start ||
            integers[9] > end
          )
        ) ||
        integers[13] != 0 ||
        integers[14] != 0 {
        raise InputError("invalid_frame", "Invalid marked text metadata")
      }
      integers[10] = start
      integers[11] = end
    }
  }
  let label = string(fields, "label", 4096, Some(""))
  let tooltip = string(fields, "tooltip", 4096, Some(label))
  {
    integers,
    numbers: [
      rect[0],
      rect[1],
      rect[2],
      rect[3],
      clip[0],
      clip[1],
      clip[2],
      clip[3],
      size,
      opacity,
    ],
    texts: [
      id,
      raw,
      label,
      if tooltip == "" {
        label
      } else {
        tooltip
      },
      string(fields, "error", 4096, Some("")),
    ],
  }
}

///|
pub fn field_count(handle : Int32) -> Int32 {
  match frames.get(handle) {
    Some(frame) => frame.editable.length()
    None => -1
  }
}

///|
fn editable(handle : Int32, index : Int32) -> Editable? {
  match frames.get(handle) {
    Some(frame) if index >= 0 && index < frame.editable.length() =>
      Some(frame.editable[index])
    _ => None
  }
}

///|
pub fn field_value(handle : Int32, index : Int32, key : Int32) -> Int32 {
  match editable(handle, index) {
    Some(field) if key >= 0 && key < field.integers.length() =>
      field.integers[key]
    _ => -1
  }
}

///|
pub fn field_number(handle : Int32, index : Int32, key : Int32) -> Double {
  match editable(handle, index) {
    Some(field) if key >= 0 && key < field.numbers.length() =>
      field.numbers[key]
    _ => 0
  }
}

///|
pub fn field_text(handle : Int32, index : Int32, key : Int32) -> String {
  match editable(handle, index) {
    Some(field) if key >= 0 && key < field.texts.length() => field.texts[key]
    _ => ""
  }
}

///|
pub fn text_event(
  kind : Int32,
  id : String,
  token : Int32,
  version : Int32,
  start : Int32,
  end : Int32,
  text : String,
  selection_kind : Int32,
  anchor : Int32,
  focus : Int32,
) -> String {
  if kind < 1 ||
    kind > 8 ||
    token < 1 ||
    token >= 2147483647 ||
    version < 0 ||
    id.is_empty() ||
    !@edit_fields.valid_text(id, 256) ||
    !canonical_text(text, 32768) ||
    start < 0 ||
    end < start ||
    end > 32768 ||
    selection_kind < 0 ||
    selection_kind > 2 ||
    anchor < 0 ||
    anchor > 32768 ||
    focus < 0 ||
    focus > 32768 {
    return ""
  }
  if kind != 1 && kind != 4 && kind != 5 && text != "" {
    return ""
  }
  if kind != 1 && kind != 3 && (start != 0 || end != 0) {
    return ""
  }
  if (selection_kind == 0 && (anchor != 0 || focus != 0)) ||
    (selection_kind == 2 && anchor > focus) ||
    (kind >= 6 && (selection_kind != 0 || anchor != 0 || focus != 0)) {
    return ""
  }
  let names = [
    "replace", "select", "compositionStart", "compositionUpdate", "compositionCommit",
    "compositionCancel", "undo", "redo",
  ]
  let edit : Map[String, Json] = { "type": Json(names[kind - 1]) }
  if kind == 1 || kind == 3 {
    edit["start"] = Json(start)
    edit["end"] = Json(end)
  }
  if kind == 1 || kind == 4 || kind == 5 {
    edit["text"] = Json(text)
  }
  if kind <= 5 {
    edit["selection"] = if selection_kind == 0 {
      Json::object({ "kind": Json("unknown") })
    } else {
      Json::object({
        "kind": Json(
          if selection_kind == 1 {
            "directed"
          } else {
            "undirected"
          },
        ),
        "anchor": Json(anchor),
        "focus": Json(focus),
      })
    }
  }
  Json::object({
    "type": Json("field"),
    "id": Json(id),
    "token": Json(token),
    "expectedVersion": Json(version),
    "edit": Json::object(edit),
  }).stringify()
}
