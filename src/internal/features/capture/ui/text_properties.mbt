///|
priv struct PropertyPlacement {
  descriptor : Map[String, Json]
  label_x : Double
  label_width : Double
  x : Double
  width : Double
}

///|
let property_row_height : Double = 30

///|
let property_control_height : Double = 22

///|
let property_color_hit_size : Double = 22

///|
let property_choice_width : Double = 26

///|
let property_stepper_width : Double = 12

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
      let width = property_number(descriptor, "width", 54)
      let label_gap = if label_width > 0 { 3.0 } else { 0.0 }
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
    [8, property_row_height]
  } else {
    let last = layout[layout.length() - 1]
    [last.x + last.width + 4, property_row_height]
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
fn property_stepper_id(id : String, increase : Bool) -> String {
  id + (if increase { ".increase" } else { ".decrease" })
}

///|
fn property_has_stepper(width : Double, height : Double) -> Bool {
  width >= property_stepper_width + 18 && height >= 16
}

///|
fn property_stepper(
  commands : Array[Json],
  semantics : Array[Json],
  id : String,
  label : String,
  x : Double,
  y : Double,
  height : Double,
  enabled : Bool,
  pressed : String,
  hovered : String,
  dark : Bool,
) -> Unit {
  let border = property_command("rect", x, y + 2, 1, height - 4)
  border["fill"] = Json(if dark { "#48484f" } else { "#e0e0e5" })
  commands.push(Json::object(border))
  let half = height / 2
  for increase in [true, false] {
    let top = if increase { y } else { y + half }
    let action_id = property_stepper_id(id, increase)
    if enabled && (pressed == action_id || hovered == action_id) {
      let highlight = property_command(
        "rect", x + 1, top + 1, property_stepper_width - 2, half - 2,
      )
      highlight["radius"] = Json(2)
      highlight["fill"] = Json(
        if dark {
          if pressed == action_id { "#50505a" } else { "#414149" }
        } else {
          if pressed == action_id { "#d2d2dc" } else { "#eaeaf1" }
        },
      )
      commands.push(Json::object(highlight))
    }
    let ink = if enabled {
      if dark { "#bfbfc9" } else { "#5b5b64" }
    } else {
      if dark { "#686870" } else { "#acacb2" }
    }
    for row in 0..<3 {
      let weight = if increase { row } else { 2 - row }
      let span = (2 * weight + 1).to_double()
      let pixel = property_command(
        "rect",
        x + (property_stepper_width - span) / 2,
        top + (half - 3) / 2 + row.to_double(),
        span,
        1,
      )
      pixel["fill"] = Json(ink)
      commands.push(Json::object(pixel))
    }
    let node = property_rect(x, top, property_stepper_width, half)
    let name = (if increase { "增大" } else { "减小" }) + label
    node["id"] = Json(action_id)
    node["label"] = Json(name)
    node["tooltip"] = Json(name)
    node["role"] = Json("button")
    node["enabled"] = Json(enabled)
    semantics.push(Json::object(node))
  }
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
  pressed : String,
  hovered : String,
  choices_enabled : Bool,
) -> String {
  let commands : Array[Json] = []
  let semantics : Array[Json] = []
  let fields : Array[Json] = []
  let text_color = if dark { "#eeeeee" } else { "#222222" }
  let label_color = if dark { "#c4c4cc" } else { "#48484f" }
  let border = if dark { "#58585f" } else { "#b9b9c1" }
  let fill = if dark { "#303034" } else { "#fbfbfc" }
  let control_height = @protocol.smaller(property_control_height, height)
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
    label_command["size"] = Json(11)
    label_command["color"] = Json(label_color)
    label_command["valign"] = Json("center")
    commands.push(Json::object(label_command))
    let control_width = @protocol.smaller(
      placement.width,
      @protocol.larger(0, width - placement.x),
    )
    if property_string(d, "kind", "") == "color" {
      let hit_size = @protocol.smaller(
        control_width,
        @protocol.smaller(property_color_hit_size, height),
      )
      let diameter = @protocol.smaller(18, hit_size)
      let cy = (height - diameter) / 2
      let circle = property_command(
        "rect",
        placement.x + (hit_size - diameter) / 2,
        cy,
        diameter,
        diameter,
      )
      circle["radius"] = Json(diameter / 2)
      circle["fill"] = Json(rgb)
      circle["stroke"] = Json(
        if pressed == id || hovered == id {
          text_color
        } else {
          border
        },
      )
      circle["lineWidth"] = Json(if pressed == id { 2 } else { 1 })
      commands.push(Json::object(circle))
      let node = property_rect(
        placement.x,
        (height - hit_size) / 2,
        hit_size,
        hit_size,
      )
      node["id"] = Json(id)
      node["role"] = Json("button")
      node["label"] = Json(label)
      node["tooltip"] = Json(tooltip)
      node["enabled"] = Json(enabled)
      node["focused"] = Json(enabled && active == id)
      semantics.push(Json::object(node))
    } else if property_string(d, "kind", "") == "choice" {
      let options = match d.get("options") {
        Some(Array(a)) => a
        _ => []
      }
      let selected = property_number(d, "value", 0)
      let visible = @protocol.smaller(
        options.length().to_double(),
        (control_width / property_choice_width).floor(),
      ).to_int()
      if visible > 0 {
        let track = property_command(
          "rect",
          placement.x,
          y,
          visible.to_double() * property_choice_width,
          control_height,
        )
        track["radius"] = Json(5)
        track["fill"] = Json(if dark { "#38383e" } else { "#e6e6eb" })
        commands.push(Json::object(track))
      }
      for index, option in options {
        if option is Object(o) {
          if index >= visible {
            continue
          }
          let bx = placement.x + index.to_double() * property_choice_width
          let oid = property_string(o, "id", "")
          let chosen = property_number(o, "value", -1) == selected
          let pressed = enabled && choices_enabled && pressed == oid
          let hovered = enabled && choices_enabled && hovered == oid
          if chosen || pressed || hovered {
            let segment = property_command(
              "rect",
              bx + 2,
              y + 2,
              property_choice_width - 4,
              @protocol.larger(0, control_height - 4),
            )
            segment["radius"] = Json(3)
            segment["fill"] = Json(
              if pressed {
                if dark { "#5e5e68" } else { "#c6c6cf" }
              } else if chosen {
                if dark { "#51515a" } else { "#d3d3dc" }
              } else {
                if dark { "#46464f" } else { "#dddde4" }
              },
            )
            commands.push(Json::object(segment))
          }
          property_icon(
            commands,
            property_string(o, "icon", "rectangle"),
            bx + (property_choice_width - 14) / 2,
            y + (control_height - 14) / 2,
            if enabled && choices_enabled {
              text_color
            } else {
              border
            },
          )
          let node = property_rect(bx, y, property_choice_width, control_height)
          node["id"] = Json(oid)
          node["role"] = Json("button")
          let name = property_string(o, "label", label)
          node["label"] = Json(
            if chosen {
              name + "（已选）"
            } else {
              name
            },
          )
          node["tooltip"] = Json(
            if choices_enabled {
              name
            } else {
              "请先完成输入并修正属性值"
            },
          )
          node["value"] = Json(if chosen { 1 } else { 0 })
          node["enabled"] = Json(enabled && choices_enabled)
          node["focused"] = Json(enabled && active == id && chosen)
          semantics.push(Json::object(node))
        }
      }
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
      let has_stepper = property_has_stepper(control_width, control_height)
      let stepper_width = if has_stepper { property_stepper_width } else { 0.0 }
      if has_stepper {
        property_stepper(
          commands,
          semantics,
          id,
          label,
          placement.x + control_width - stepper_width,
          y,
          control_height,
          enabled && choices_enabled,
          pressed,
          hovered,
          dark,
        )
      }
      field["x"] = Json(placement.x + 4)
      field["y"] = Json(y + 2)
      field["width"] = Json(@protocol.larger(0, control_width - stepper_width - 6))
      field["height"] = Json(@protocol.larger(0, control_height - 4))
      field["fontSize"] = Json(12)
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
    "cursor": Json(if enabled && hovered != "" { "pointer" } else { "default" }),
  }).stringify()
}

///|
pub(all) enum PropertyAction {
  Ignore
  Feedback
  OpenColor
  SetShape(Int32)
  Nudge(String, Int32)
  Wheel(String, Double)
}

///|
/// The feature root validates and applies the request. Pointer release must
/// match its press ID, including between the + and − halves of a number field.
pub fn text_property_event(
  descriptors : Json,
  event : Json,
  width : Double,
  height : Double,
  pressed : String,
) -> (PropertyAction, String, String) {
  let event = match event {
    Object(m) => m
    _ => return (Ignore, pressed, "")
  }
  let kind = property_string(event, "type", "")
  if kind == "cancel" {
    return (Feedback, "", "")
  }
  if kind == "pointerDown" || kind == "pointerMove" || kind == "pointerUp" ||
    kind == "scroll" {
    for key in ["x", "y"] {
      match event.get(key) {
        Some(Number(n, ..)) if n >= -1000000 && n <= 1000000 => ()
        _ => return (Ignore, pressed, "")
      }
    }
  }
  let x = match event.get("x") {
    Some(Number(n, ..)) => n
    _ => -1.0
  }
  let y = match event.get("y") {
    Some(Number(n, ..)) => n
    _ => -1.0
  }
  let wheel = if kind == "scroll" {
    match (event.get("deltaX"), event.get("deltaY")) {
      (dx, Some(Number(dy, ..))) if dy >= -1000000 && dy <= 1000000 && dy != 0 => {
        let dx = match dx {
          Some(Number(n, ..)) => n
          _ => 0.0
        }
        if dx.abs() >= dy.abs() ||
          event.get("mod") == Some(Json(true)) ||
          event.get("shift") == Some(Json(true)) {
          return (Ignore, pressed, "")
        }
        dy / (if event.get("precise") == Some(Json(true)) { 12 } else { 1 })
      }
      _ => return (Ignore, pressed, "")
    }
  } else {
    0.0
  }
  let mut hit = ""
  let mut action = Ignore
  let requested = if kind == "activate" {
    property_string(event, "id", "")
  } else {
    ""
  }
  for p in property_layout(descriptors) {
    let d = p.descriptor
    let id = property_string(d, "id", "")
    let control = property_string(d, "kind", "")
    if control == "color" {
      let diameter = @protocol.smaller(
        @protocol.smaller(p.width, @protocol.larger(0, width - p.x)),
        @protocol.smaller(property_color_hit_size, height),
      )
      let cy = (height - diameter) / 2
      let dx = x - p.x - diameter / 2
      let dy = y - cy - diameter / 2
      let inside = diameter > 0 &&
        x >= p.x &&
        x < p.x + diameter &&
        y >= cy &&
        y < cy + diameter &&
        dx * dx + dy * dy <= diameter * diameter / 4
      if requested == id || inside {
        hit = id
        action = OpenColor
      }
    } else if control == "choice" {
      let options = match d.get("options") {
        Some(Array(a)) => a
        _ => []
      }
      let h = @protocol.smaller(property_control_height, height)
      let top = (height - h) / 2
      for index, option in options {
        if option is Object(o) {
          let left = p.x + index.to_double() * property_choice_width
          let oid = property_string(o, "id", "")
          let value = property_number(o, "value", -1)
          if left + property_choice_width <= width &&
            value >= 0 &&
            value <= 2 &&
            (
              requested == oid ||
              (x >= left && x < left + property_choice_width && y >= top && y < top + h)
            ) {
            hit = oid
            action = SetShape(value.to_int())
          }
        }
      }
    } else if control == "number" {
      let right = @protocol.smaller(width, p.x + p.width)
      let h = @protocol.smaller(property_control_height, height)
      let top = (height - h) / 2
      let inside = x >= p.x && x < right && y >= top && y < top + h
      if kind == "scroll" && inside {
        return (Wheel(id, wheel), pressed, "")
      }
      if property_has_stepper(right - p.x, h) {
        for increase in [true, false] {
          let action_id = property_stepper_id(id, increase)
          if requested == action_id ||
            (inside && x >= right - property_stepper_width &&
            (y < top + h / 2) == increase) {
            hit = action_id
            action = Nudge(id, if increase { 1 } else { -1 })
          }
        }
      }
    }
  }
  match kind {
    "activate" => (action, "", "")
    "pointerDown" => (Feedback, hit, hit)
    "pointerMove" => (Feedback, pressed, hit)
    "pointerUp" => (if hit != "" && pressed == hit { action } else { Feedback }, "", hit)
    _ => (Ignore, pressed, hit)
  }
}

///|
fn property_icon(
  commands : Array[Json],
  kind : String,
  x : Double,
  y : Double,
  color : String,
) -> Unit {
  if kind == "mosaic" {
    for row in 0..<2 {
      for col in 0..<2 {
        let tile = property_command(
          "rect",
          x + col.to_double() * 7,
          y + row.to_double() * 7,
          6,
          6,
        )
        tile["fill"] = Json(
          ["#333333", "#999999", "#cccccc", "#666666"][row * 2 + col],
        )
        commands.push(Json::object(tile))
      }
    }
  } else {
    let r = property_command("rect", x, y, 14, 14)
    r["radius"] = Json(
      if kind == "ellipse" || kind == "filledEllipse" {
        7
      } else {
        0
      },
    )
    if kind == "filledRectangle" || kind == "filledEllipse" {
      r["fill"] = Json(color)
    } else {
      r["stroke"] = Json(color)
      r["lineWidth"] = Json(1.5)
    }
    commands.push(Json::object(r))
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
