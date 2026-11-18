///|
priv struct EditorStyleValues {
  mut color : Int
  mut opacity : Double
  mut stroke : Double
  mut font : Double
  mut shape : Double
  mut block : Double
}

///|
fn editor_style_initial(tool : Int) -> EditorStyleValues {
  {
    color: if tool == 4 { 0x111111 } else { @annotation_tools.editor_style_default(0).to_int() },
    opacity: @annotation_tools.editor_style_default(1),
    stroke: @annotation_tools.editor_style_default(2),
    font: @annotation_tools.editor_style_default(3),
    shape: @annotation_tools.editor_style_default(4),
    block: @annotation_tools.editor_style_default(5),
  }
}

///|
priv struct EditorStyleSession {
  tools : Array[EditorStyleValues]
  mut revision : Int
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
  editor_style_sessions[handle] = { tools, revision: 0 }
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
    4 => values.shape
    5 => values.block
    _ => 0
  }
}

///|
pub fn editor_style_set(handle : Int, tool : Int, property : Int, value : Double) -> Int {
  if !@image.editor_style_value_valid(property, value) { return 0 }
  if (@annotation_tools.editor_style_property_mask(tool) & (1 << property)) == 0 { return 0 }
  if property == 4 && value >= @annotation_tools.editor_style_shape_count(tool).to_double() { return 0 }
  let values = match editor_style_values(handle, tool) { Some(values) => values; None => return 0 }
  let session = editor_style_sessions[handle]
  if editor_style_get(handle, tool, property) == value { return 1 }
  if session.revision >= 2147483647 { return 0 }
  match property {
    0 => values.color = value.to_int()
    1 => values.opacity = value
    2 => values.stroke = value
    3 => values.font = value
    4 => values.shape = value
    5 => values.block = value
    _ => return 0
  }
  session.revision += 1
  1
}

///|
pub fn editor_style_dispose(handle : Int) -> Unit { editor_style_sessions.remove(handle) }
