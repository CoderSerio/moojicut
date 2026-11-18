///|
using @json {type Json}

///|
using @protocol {type InputError}

///|
priv struct Draw {
  integers : Array[Int32]
  numbers : Array[Double]
  text : String
}

///|
priv struct Semantic {
  integers : Array[Int32]
  numbers : Array[Double]
  texts : Array[String]
}

///|
priv struct Frame {
  layers : Array[Array[Draw]]
  semantics : Array[Semantic]
  editable : Array[Editable]
  video : Array[Double]?
  cursor : Int32
}

///|
fn object(value : Json) -> Map[String, Json] raise InputError {
  match value {
    Object(fields) => fields
    _ => raise InputError("invalid_frame", "Expected an object")
  }
}

///|
fn string(
  fields : Map[String, Json],
  key : String,
  limit : Int32,
  fallback : String?,
) -> String raise InputError {
  match fields.get(key) {
    Some(String(s)) if s.length() <= limit => s
    None =>
      match fallback {
        Some(s) => s
        None => raise InputError("invalid_frame", "Missing \{key}")
      }
    _ => raise InputError("invalid_frame", "Invalid \{key}")
  }
}

///|
fn number(
  fields : Map[String, Json],
  key : String,
  low : Double,
  high : Double,
  fallback : Double?,
) -> Double raise InputError {
  match fields.get(key) {
    Some(Number(n, ..)) if n >= low && n <= high => n
    None =>
      match fallback {
        Some(n) => n
        None => raise InputError("invalid_frame", "Missing \{key}")
      }
    _ => raise InputError("invalid_frame", "Invalid \{key}")
  }
}

///|
fn boolean(
  fields : Map[String, Json],
  key : String,
  fallback : Bool,
) -> Int32 raise InputError {
  match fields.get(key) {
    Some(True) => 1
    Some(False) => 0
    None => if fallback { 1 } else { 0 }
    _ => raise InputError("invalid_frame", "Invalid \{key}")
  }
}

///|
fn rectangle(fields : Map[String, Json]) -> Array[Double] raise InputError {
  let x = number(fields, "x", -1000000, 1000000, None)
  let y = number(fields, "y", -1000000, 1000000, None)
  let w = number(fields, "width", 0, 1000000, None)
  let h = number(fields, "height", 0, 1000000, None)
  [x, y, w, h]
}

///|
fn color(
  fields : Map[String, Json],
  key : String,
  optional : Bool,
) -> Int32 raise InputError {
  let s = string(fields, key, 7, if optional { Some("") } else { None })
  if s == "" && optional {
    return -1
  }
  if s.length() != 7 || !s.has_prefix("#") {
    raise InputError("invalid_frame", "Invalid color")
  }
  let mut value = 0
  let mut index = 0
  for c in s.iter() {
    if index > 0 {
      let c = c.to_int()
      let digit = if c >= 48 && c <= 57 {
        c - 48
      } else if c >= 65 && c <= 70 {
        c - 55
      } else if c >= 97 && c <= 102 {
        c - 87
      } else {
        raise InputError("invalid_frame", "Invalid color")
      }
      value = value * 16 + digit
    }
    index += 1
  }
  value
}

///|
fn enum_string(
  fields : Map[String, Json],
  key : String,
  choices : Array[String],
  fallback : String,
) -> Int32 raise InputError {
  let value = string(fields, key, 32, Some(fallback))
  for index, option in choices {
    if value == option {
      return index
    }
  }
  raise InputError("invalid_frame", "Unknown \{key}")
}

///|
fn draw(value : Json) -> Draw raise InputError {
  let fields = object(value)
  let kind = string(fields, "type", 16, None)
  let numbers : Array[Double] = [0, 0, 0, 0, 0, 1, 0, 0, 0]
  let integers = [0, -1, -1, -1, 0, 0, 0]
  let mut text = ""
  match kind {
    "rect" | "text" => {
      let rect = rectangle(fields)
      for i in 0..<4 {
        numbers[i] = rect[i]
      }
      if kind == "rect" {
        integers[0] = 1
        integers[1] = color(fields, "fill", true)
        integers[2] = color(fields, "stroke", true)
        numbers[4] = number(fields, "radius", 0, 1000000, Some(0))
        numbers[5] = number(fields, "lineWidth", 0, 4096, Some(1))
      } else {
        integers[0] = 3
        integers[3] = color(fields, "color", false)
        integers[4] = enum_string(
          fields,
          "weight",
          ["regular", "medium", "bold"],
          "regular",
        )
        integers[5] = enum_string(
          fields,
          "align",
          ["left", "center", "right"],
          "left",
        )
        integers[6] = enum_string(fields, "valign", ["top", "center"], "top")
        text = string(fields, "text", 32768, None)
        numbers[8] = number(fields, "size", 0, 4096, None)
        if numbers[8] <= 0 {
          raise InputError("invalid_frame", "Font size must be positive")
        }
      }
    }
    "line" => {
      integers[0] = 2
      integers[3] = color(fields, "color", false)
      numbers[0] = number(fields, "x1", -1000000, 1000000, None)
      numbers[1] = number(fields, "y1", -1000000, 1000000, None)
      numbers[6] = number(fields, "x2", -1000000, 1000000, None)
      numbers[7] = number(fields, "y2", -1000000, 1000000, None)
      numbers[5] = number(fields, "lineWidth", 0, 4096, Some(1))
    }
    _ => raise InputError("invalid_frame", "Unknown draw command")
  }
  { integers, numbers, text, }
}

///|
fn semantic(value : Json) -> Semantic raise InputError {
  let fields = object(value)
  let rect = rectangle(fields)
  let id = string(fields, "id", 256, None)
  if id.length() == 0 {
    raise InputError("invalid_frame", "Semantic ID is empty")
  }
  let label = string(fields, "label", 4096, Some(""))
  let tooltip = string(fields, "tooltip", 4096, Some(label))
  let tooltip = if tooltip == "" { label } else { tooltip }
  let role = match string(fields, "role", 32, Some("group")) {
    "group" => 0
    "button" => 1
    "slider" => 2
    "checkbox" => 3
    "staticText" | "text" | "label" => 4
    _ => raise InputError("invalid_frame", "Unknown semantic role")
  }
  let integers = [
    role,
    boolean(fields, "enabled", true),
    boolean(fields, "focused", false),
    0,
    0,
    0,
    0,
  ]
  let numbers = [rect[0], rect[1], rect[2], rect[3], 0.0, 0.0, 0.0, 0.0]
  let mut value_text = ""
  match fields.get("value") {
    None | Some(Null) => ()
    Some(Number(n, ..)) if n >= -1.0e15 && n <= 1.0e15 => {
      integers[3] = 1
      numbers[4] = n
    }
    Some(String(s)) if s.length() <= 32768 => {
      integers[3] = 2
      value_text = s
    }
    Some(True) => {
      integers[3] = 3
      numbers[4] = 1
    }
    Some(False) => {
      integers[3] = 3
      numbers[4] = 0
    }
    _ => raise InputError("invalid_frame", "Invalid semantic value")
  }
  for (i, key) in [(0, "min"), (1, "max"), (2, "step")] {
    if fields.contains(key) {
      integers[4 + i] = 1
      numbers[5 + i] = number(fields, key, -1.0e15, 1.0e15, None)
    }
  }
  if (integers[4] == 1 && integers[5] == 1 && numbers[5] > numbers[6]) ||
    (integers[6] == 1 && numbers[7] <= 0) ||
    (role == 2 && integers[3] != 1) {
    raise InputError("invalid_frame", "Invalid slider metadata")
  }
  { integers, numbers, texts: [id, label, tooltip, value_text], }
}

///|
fn array(
  fields : Map[String, Json],
  key : String,
  required : Bool,
) -> Array[Json] raise InputError {
  match fields.get(key) {
    Some(Array(items)) => items
    None if !required => []
    _ => raise InputError("invalid_frame", "Expected \{key} array")
  }
}

///|
fn decode(text : String) -> Frame raise InputError {
  if text.length() > 4194304 {
    raise InputError("invalid_frame", "Frame is too large")
  }
  let fields = object(
    @json.parse(text, max_nesting_depth=32, reject_duplicate_keys=true) catch {
      _ => raise InputError("invalid_frame", "Invalid frame JSON")
    },
  )
  if fields.get("ok") != Some(Json(true)) {
    raise InputError("invalid_frame", "Unsuccessful frame")
  }
  let commands = array(fields, "commands", true)
  let overlay = array(fields, "overlayCommands", false)
  let nodes = array(fields, "semantics", false)
  let input_fields = array(fields, "editableFields", false)
  if commands.length() + overlay.length() > 32768 || nodes.length() > 16384 || input_fields.length() > 64 {
    raise InputError("invalid_frame", "Too many frame entries")
  }
  let layers : Array[Array[Draw]] = []
  for items in [commands, overlay] {
    let layer : Array[Draw] = []
    for item in items {
      layer.push(draw(item))
    }
    layers.push(layer)
  }
  let semantics : Array[Semantic] = []
  let ids : Map[String, Bool] = Map([])
  for item in nodes {
    let node = semantic(item)
    let id = node.texts[0]
    if ids.contains(id) {
      raise InputError("invalid_frame", "Duplicate semantic ID")
    }
    ids[id] = true
    semantics.push(node)
  }
  let editable : Array[Editable] = []
  let tokens : Map[Int, Bool] = Map([])
  let mut focused = false
  for item in input_fields {
    let input = editable_field(item)
    let id = input.texts[0]
    let token = input.integers[0]
    if ids.contains(id) || tokens.contains(token) || (focused && input.integers[4] == 1) {
      raise InputError("invalid_frame", "Duplicate editable field identity or focus")
    }
    ids[id] = true
    tokens[token] = true
    focused = focused || input.integers[4] == 1
    editable.push(input)
  }
  let video = match fields.get("videoRect") {
    None | Some(Null) => None
    Some(value) => Some(rectangle(object(value)))
  }
  let cursor = match string(fields, "cursor", 32, Some("default")) {
    "default" => 0
    "resize" | "resize-horizontal" => 1
    "pointingHand" | "pointer" => 2
    "crosshair" => 3
    _ => raise InputError("invalid_frame", "Unknown cursor")
  }
  { layers, semantics, editable, video, cursor, }
}
