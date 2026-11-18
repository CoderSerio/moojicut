// Native ABI entry points. Shared style rules and session state live in
// internal/features/capture; keep the exported names and signatures stable.

///|
#export_name("editor_style_group_gap")
pub fn editor_style_group_gap() -> Int {
  @capture_ui.editor_style_group_gap()
}

///|
#export_name("editor_style_swatch_size")
pub fn editor_style_swatch_size() -> Int {
  @capture_ui.editor_style_swatch_size()
}

///|
#export_name("editor_style_visible_mask")
pub fn editor_style_visible_mask(tool : Int, shape : Int) -> Int {
  @capture.editor_style_visible_mask(tool, shape)
}

///|
#export_name("editor_style_shape_count")
pub fn editor_style_shape_count(tool : Int) -> Int {
  @annotation_tools.editor_style_shape_count(tool)
}

///|
#export_name("editor_style_property_mask")
pub fn editor_style_property_mask(tool : Int) -> Int {
  @annotation_tools.editor_style_property_mask(tool)
}

///|
#export_name("editor_style_min")
pub fn editor_style_min(property : Int) -> Double {
  @image.editor_style_min(property)
}

///|
#export_name("editor_style_max")
pub fn editor_style_max(property : Int) -> Double {
  @image.editor_style_max(property)
}

///|
#export_name("editor_style_step")
pub fn editor_style_step(property : Int) -> Double {
  @capture.editor_style_step(property)
}

///|
#export_name("editor_style_default")
pub fn editor_style_default(property : Int) -> Double {
  @annotation_tools.editor_style_default(property)
}

///|
#export_name("editor_style_create")
pub fn editor_style_create() -> Int {
  @capture.editor_style_create()
}

///|
#export_name("editor_style_get")
pub fn editor_style_get(handle : Int, tool : Int, property : Int) -> Double {
  @capture.editor_style_get(handle, tool, property)
}

///|
#export_name("editor_style_set")
pub fn editor_style_set(handle : Int, tool : Int, property : Int, value : Double) -> Int {
  @capture.editor_style_set(handle, tool, property, value)
}

///|
#export_name("editor_style_dispose")
pub fn editor_style_dispose(handle : Int) -> Unit {
  @capture.editor_style_dispose(handle)
}
