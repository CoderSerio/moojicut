// Native ABI entry points. Shared style rules and session state live in
// internal/editor_style; keep the exported names and signatures stable.

///|
#export_name("editor_style_property_mask")
pub fn editor_style_property_mask(tool : Int) -> Int {
  @style.editor_style_property_mask(tool)
}

///|
#export_name("editor_style_min")
pub fn editor_style_min(property : Int) -> Double {
  @style.editor_style_min(property)
}

///|
#export_name("editor_style_max")
pub fn editor_style_max(property : Int) -> Double {
  @style.editor_style_max(property)
}

///|
#export_name("editor_style_step")
pub fn editor_style_step(property : Int) -> Double {
  @style.editor_style_step(property)
}

///|
#export_name("editor_style_default")
pub fn editor_style_default(property : Int) -> Double {
  @style.editor_style_default(property)
}

///|
#export_name("editor_style_create")
pub fn editor_style_create() -> Int {
  @style.editor_style_create()
}

///|
#export_name("editor_style_get")
pub fn editor_style_get(handle : Int, tool : Int, property : Int) -> Double {
  @style.editor_style_get(handle, tool, property)
}

///|
#export_name("editor_style_set")
pub fn editor_style_set(handle : Int, tool : Int, property : Int, value : Double) -> Int {
  @style.editor_style_set(handle, tool, property, value)
}

///|
#export_name("editor_style_dispose")
pub fn editor_style_dispose(handle : Int) -> Unit {
  @style.editor_style_dispose(handle)
}
