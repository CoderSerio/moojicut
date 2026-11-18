///|
priv struct PropertyPlacement {
  descriptor : Map[String, Json]
  label_x : Double
  label_width : Double
  x : Double
  width : Double
}

///|
fn property_number(
  m : Map[String, Json],
  key : String,
  fallback : Double,
) -> Double {
  match m.get(key) {
    Some(Number(n, ..)) if n >= 0 && n <= 4096 => n
    _ => fallback
  }
}

///|
fn property_string(
  m : Map[String, Json],
  key : String,
  fallback : String,
) -> String {
  match m.get(key) {
    Some(String(s)) => s
    _ => fallback
  }
}

///|
fn property_layout(descriptors : Json) -> Array[PropertyPlacement] {
  let descriptors = match descriptors {
    Array(a) if a.length() <= 16 => a
    _ => return []
  }
  let placements : Array[PropertyPlacement] = []
  let mut x = 4.0
  for item in descriptors {
    if item is Object(descriptor) {
      let label_width = property_number(descriptor, "labelWidth", 0)
      let width = property_number(descriptor, "width", 58)
      let label_gap = if label_width > 0 { 6.0 } else { 0.0 }
      placements.push({
        descriptor,
        label_x: x,
        label_width,
        x: x + label_width + label_gap,
        width,
      })
      x += label_width +
        label_gap +
        width +
        editor_style_group_gap().to_double()
    }
  }
  placements
}

///|
pub fn text_row_size(descriptors : Json) -> FixedArray[Double] {
  let layout = property_layout(descriptors)
  if layout.is_empty() {
    [8, 34]
  } else {
    let last = layout[layout.length() - 1]
    [last.x + last.width + 4, 34]
  }
}

///|
fn property_rect(
  x : Double,
  y : Double,
  width : Double,
  height : Double,
) -> Map[String, Json] {
  { "x": Json(x), "y": Json(y), "width": Json(width), "height": Json(height) }
}

///|
fn property_command(
  kind : String,
  x : Double,
  y : Double,
  width : Double,
  height : Double,
) -> Map[String, Json] {
  let result = property_rect(x, y, width, height)
  result["type"] = Json(kind)
  result
}

///|
fn property_field_state(states : Json, id : String) -> Map[String, Json]? {
  if states is Array(items) {
    for item in items {
      if item is Object(s) && s.get("id") == Some(Json(id)) {
        let copy : Map[String, Json] = Map([])
        for key, value in s {
          copy[key] = value
        }
        return Some(copy)
      }
    }
  }
  None
}

///|
/// Contribution descriptions and draft snapshots enter from the feature root.
/// Field raw text is rendered only by the native editing surface, never twice.
pub fn text_properties_frame(
  descriptors : Json,
  states : Json,
  rgb : String,
  active : String,
  enabled : Bool,
  width : Double,
  height : Double,
  dark : Bool,
  pressed : Bool,
  hovered : Bool,
) -> String {
  let commands : Array[Json] = []
  let semantics : Array[Json] = []
  let fields : Array[Json] = []
  let text_color = if dark { "#eeeeee" } else { "#222222" }
  let border = if dark { "#666666" } else { "#aaaaaa" }
  let fill = if dark { "#292929" } else { "#ffffff" }
  let control_height = @protocol.smaller(24, height)
  let y = (height - control_height) / 2
  for placement in property_layout(descriptors) {
    let d = placement.descriptor
    let id = property_string(d, "id", "")
    let label = property_string(d, "label", "")
    let tooltip = property_string(d, "tooltip", label)
    let label_command = property_command(
      "text",
      placement.label_x,
      y,
      placement.label_width,
      control_height,
    )
    label_command["text"] = Json(label)
    label_command["size"] = Json(13)
    label_command["color"] = Json(text_color)
    label_command["valign"] = Json("center")
    commands.push(Json::object(label_command))
    let control_width = @protocol.smaller(
      placement.width,
      @protocol.larger(0, width - placement.x),
    )
    if property_string(d, "kind", "") == "color" {
      let diameter = @protocol.smaller(
        control_width,
        @protocol.smaller(22, height),
      )
      let cy = (height - diameter) / 2
      let circle = property_command("rect", placement.x, cy, diameter, diameter)
      circle["radius"] = Json(diameter / 2)
      circle["fill"] = Json(rgb)
      circle["stroke"] = Json(
        if pressed || hovered {
          text_color
        } else {
          border
        },
      )
      circle["lineWidth"] = Json(if pressed { 2 } else { 1 })
      commands.push(Json::object(circle))
      let node = property_rect(placement.x, cy, diameter, diameter)
      node["id"] = Json(id)
      node["role"] = Json("button")
      node["label"] = Json(label)
      node["tooltip"] = Json(tooltip)
      node["enabled"] = Json(enabled)
      node["focused"] = Json(enabled && active == id)
      semantics.push(Json::object(node))
    } else if property_field_state(states, id) is Some(field) {
      let background = property_command(
        "rect",
        placement.x,
        y,
        control_width,
        control_height,
      )
      background["radius"] = Json(4)
      background["fill"] = Json(fill)
      background["stroke"] = Json(
        if property_string(field, "error", "") != "" {
          "#d34b4b"
        } else {
          border
        },
      )
      commands.push(Json::object(background))
      field["x"] = Json(placement.x + 4)
      field["y"] = Json(y + 2)
      field["width"] = Json(@protocol.larger(0, control_width - 8))
      field["height"] = Json(@protocol.larger(0, control_height - 4))
      field["fontSize"] = Json(13)
      field["weight"] = Json("regular")
      field["color"] = Json(text_color)
      field["opacity"] = Json(1)
      field["multiline"] = Json(false)
      field["enabled"] = Json(enabled)
      field["readOnly"] = Json(!enabled)
      field["focused"] = Json(enabled && active == id)
      field["label"] = Json(label)
      field["tooltip"] = Json(tooltip)
      fields.push(Json::object(field))
    }
  }
  Json::object({
    "ok": Json(true),
    "commands": Json::array(commands),
    "overlayCommands": Json::array([]),
    "semantics": Json::array(semantics),
    "editableFields": Json::array(fields),
    "cursor": Json(if enabled && hovered { "pointer" } else { "default" }),
  }).stringify()
}

///|
/// Shared hit policy for a color action. Returns (handled/request-color, pressed,
/// hovered). Native code only executes the requested system color picker.
pub fn text_property_event(
  descriptors : Json,
  event : Json,
  width : Double,
  height : Double,
  pressed : Bool,
) -> (Int32, Bool, Bool) {
  let event = match event {
    Object(m) => m
    _ => return (0, pressed, false)
  }
  let kind = property_string(event, "type", "")
  if kind == "cancel" {
    return (1, false, false)
  }
  if kind == "pointerDown" || kind == "pointerMove" || kind == "pointerUp" {
    for key in ["x", "y"] {
      match event.get(key) {
        Some(Number(n, ..)) if n >= -1000000 && n <= 1000000 => ()
        _ => return (0, pressed, false)
      }
    }
  }
  let x = match event.get("x") {
    Some(Number(x, ..)) if x >= -1000000 && x <= 1000000 => x
    _ => -1.0
  }
  let y = match event.get("y") {
    Some(Number(y, ..)) if y >= -1000000 && y <= 1000000 => y
    _ => -1.0
  }
  let mut hit = false
  let mut activate = false
  for p in property_layout(descriptors) {
    if property_string(p.descriptor, "kind", "") == "color" {
      let diameter = @protocol.smaller(
        @protocol.smaller(p.width, @protocol.larger(0, width - p.x)),
        @protocol.smaller(22, height),
      )
      let cy = (height - diameter) / 2
      hit = x >= p.x &&
        x < p.x + diameter &&
        x < width &&
        y >= cy &&
        y < cy + diameter
      activate = event.get("id") == p.descriptor.get("id")
    }
  }
  match kind {
    "activate" if activate => (2, false, false)
    "pointerDown" => (1, hit, hit)
    "pointerMove" => (1, pressed, hit)
    "pointerUp" => (if pressed && hit { 2 } else { 1 }, false, hit)
    _ => (0, pressed, hit)
  }
}

///|
pub fn text_inline_frame(
  state : Json,
  width : Double,
  height : Double,
  font : Double,
  color : String,
  opacity : Double,
  enabled : Bool,
  focused : Bool,
) -> String {
  let fields : Array[Json] = []
  if state is Object(s) {
    let field : Map[String, Json] = Map([])
    for key, value in s {
      field[key] = value
    }
    field["x"] = Json(0)
    field["y"] = Json(0)
    field["width"] = Json(width)
    field["height"] = Json(height)
    field["fontSize"] = Json(font)
    field["weight"] = Json("semibold")
    field["color"] = Json(color)
    field["opacity"] = Json(opacity)
    field["multiline"] = Json(true)
    field["enabled"] = Json(enabled)
    field["readOnly"] = Json(!enabled)
    field["focused"] = Json(enabled && focused)
    field["label"] = Json("画布文字编辑")
    field["tooltip"] = Json("编辑标注文字")
    fields.push(Json::object(field))
  }
  Json::object({
    "ok": Json(true),
    "commands": Json::array([]),
    "overlayCommands": Json::array([]),
    "semantics": Json::array([]),
    "editableFields": Json::array(fields),
    "cursor": Json("default"),
  }).stringify()
}
