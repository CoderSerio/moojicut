///|
// Style domains and per-tool defaults belong to the shared editor core. Native
// controls keep focus/drag drafts, then read or update these typed records.
priv struct EditorStyleProperty {
  minimum : Double
  maximum : Double
  step : Double
  initial : Double
}

///|
fn editor_style_property(property : Int) -> EditorStyleProperty? {
  match property {
    0 => Some({ minimum: 0, maximum: 16777215, step: 1, initial: (0xf26769).to_double() })
    1 => Some({ minimum: 0, maximum: 1, step: 0.01, initial: 1 })
    2 => Some({ minimum: 1, maximum: 96, step: 1, initial: 4 })
    3 => Some({ minimum: 8, maximum: 128, step: 1, initial: 32 })
    _ => None
  }
}

///|
// A step describes keyboard/spinner increments, not valid-value quantization.
// Documents already allow fractional stroke/font values; keep them compatible.
fn editor_style_value_valid(property : Int, value : Double) -> Bool {
  let domain = match editor_style_property(property) {
    Some(domain) => domain
    None => return false
  }
  value >= domain.minimum && value <= domain.maximum &&
  (property != 0 || @double.floor(value) == value)
}

///|
#export_name("editor_style_property_mask")
pub fn editor_style_property_mask(tool : Int) -> Int {
  match tool {
    1 | 2 => 7 // color, opacity, stroke
    3 => 11 // color, opacity, font
    4 => 3 // color, opacity
    _ => 0
  }
}

///|
#export_name("editor_style_min")
pub fn editor_style_min(property : Int) -> Double {
  match editor_style_property(property) { Some(domain) => domain.minimum; None => 0 }
}

///|
#export_name("editor_style_max")
pub fn editor_style_max(property : Int) -> Double {
  match editor_style_property(property) { Some(domain) => domain.maximum; None => 0 }
}

///|
#export_name("editor_style_step")
pub fn editor_style_step(property : Int) -> Double {
  match editor_style_property(property) { Some(domain) => domain.step; None => 0 }
}

///|
#export_name("editor_style_default")
pub fn editor_style_default(property : Int) -> Double {
  match editor_style_property(property) { Some(domain) => domain.initial; None => 0 }
}

///|
priv struct EditorStyleValues {
  mut color : Int
  mut opacity : Double
  mut stroke : Double
  mut font : Double
}

///|
fn editor_style_initial(tool : Int) -> EditorStyleValues {
  {
    color: if tool == 4 { 0x111111 } else { editor_style_default(0).to_int() },
    opacity: editor_style_default(1),
    stroke: editor_style_default(2),
    font: editor_style_default(3),
  }
}

///|
priv struct EditorStyleSession {
  tools : Array[EditorStyleValues]
}

///|
let editor_style_sessions : Map[Int, EditorStyleSession] = Map([])

///|
let editor_style_next_id : Ref[Int] = Ref(1)

///|
#export_name("editor_style_create")
pub fn editor_style_create() -> Int {
  // Never reuse disposed handles or wrap into another editor's identity.
  if editor_style_next_id.val >= 2147483647 { return 0 }
  let handle = editor_style_next_id.val
  editor_style_next_id.val = handle + 1
  let tools : Array[EditorStyleValues] = []
  for tool in 0..<5 { tools.push(editor_style_initial(tool)) }
  editor_style_sessions[handle] = { tools, }
  handle
}

///|
fn editor_style_values(handle : Int, tool : Int) -> EditorStyleValues? {
  if tool < 0 || tool > 4 { return None }
  match editor_style_sessions.get(handle) {
    Some(session) => Some(session.tools[tool])
    None => None
  }
}

///|
#export_name("editor_style_get")
pub fn editor_style_get(handle : Int, tool : Int, property : Int) -> Double {
  let values = match editor_style_values(handle, tool) { Some(values) => values; None => return 0 }
  match property {
    0 => values.color.to_double()
    1 => values.opacity
    2 => values.stroke
    3 => values.font
    _ => 0
  }
}

///|
#export_name("editor_style_set")
pub fn editor_style_set(handle : Int, tool : Int, property : Int, value : Double) -> Int {
  if !editor_style_value_valid(property, value) { return 0 }
  if (editor_style_property_mask(tool) & (1 << property)) == 0 { return 0 }
  let values = match editor_style_values(handle, tool) { Some(values) => values; None => return 0 }
  match property {
    0 => values.color = value.to_int()
    1 => values.opacity = value
    2 => values.stroke = value
    3 => values.font = value
    _ => return 0
  }
  1
}

///|
#export_name("editor_style_dispose")
pub fn editor_style_dispose(handle : Int) -> Unit { editor_style_sessions.remove(handle) }
