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
pub fn editor_style_dispose(handle : Int) -> Unit { editor_style_sessions.remove(handle) }
