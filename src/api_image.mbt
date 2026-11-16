// Stable MoonBit and C ABI entry points for image documents, native sessions,
// and source-pixel cropping. Implementations and state live in internal/image.

///|
#export_name("image_create")
pub fn image_create(request : String) -> String {
  @image.image_create(request)
}

///|
#export_name("image_apply")
pub fn image_apply(request : String) -> String {
  @image.image_apply(request)
}

///|
#export_name("image_finalize")
pub fn image_finalize(request : String) -> String {
  @image.image_finalize(request)
}

///|
#export_name("image_session_create")
pub fn image_session_create(width : Int, height : Int) -> Int {
  @image.image_session_create(width, height)
}

///|
#export_name("image_session_create_viewport")
pub fn image_session_create_viewport(
  width : Int, height : Int, x : Int, y : Int, viewport_width : Int, viewport_height : Int,
) -> Int {
  @image.image_session_create_viewport(width, height, x, y, viewport_width, viewport_height)
}

///|
#export_name("image_session_add")
pub fn image_session_add(
  id : Int, kind : Int, x : Int, y : Int, width : Int, height : Int,
  color : Int, stroke : Int,
) -> Int {
  @image.image_session_add(id, kind, x, y, width, height, color, stroke)
}

///|
#export_name("image_session_add_styled")
pub fn image_session_add_styled(
  id : Int, kind : Int, x : Int, y : Int, width : Int, height : Int,
  color : Int, stroke : Int, font_size : Int,
) -> Int {
  @image.image_session_add_styled(id, kind, x, y, width, height, color, stroke, font_size)
}

///|
#export_name("image_session_add_rgba")
pub fn image_session_add_rgba(
  id : Int, kind : Int, x : Int, y : Int, width : Int, height : Int,
  color : Int, stroke : Int, font_size : Int, opacity : Double,
) -> Int {
  @image.image_session_add_rgba(id, kind, x, y, width, height, color, stroke, font_size, opacity)
}

///|
#export_name("image_session_update")
pub fn image_session_update(
  id : Int, index : Int, x : Int, y : Int, width : Int, height : Int,
  color : Int, stroke : Int, font_size : Int,
) -> Int {
  @image.image_session_update(id, index, x, y, width, height, color, stroke, font_size)
}

///|
#export_name("image_session_update_rgba")
pub fn image_session_update_rgba(
  id : Int, index : Int, x : Int, y : Int, width : Int, height : Int,
  color : Int, stroke : Int, font_size : Int, opacity : Double,
) -> Int {
  @image.image_session_update_rgba(id, index, x, y, width, height, color, stroke, font_size, opacity)
}

///|
#export_name("image_session_remove")
pub fn image_session_remove(id : Int, index : Int) -> Int {
  @image.image_session_remove(id, index)
}

///|
#export_name("image_session_crop")
pub fn image_session_crop(id : Int, x : Int, y : Int, width : Int, height : Int) -> Int {
  @image.image_session_crop(id, x, y, width, height)
}

///|
#export_name("image_session_viewport_value")
pub fn image_session_viewport_value(id : Int, field : Int) -> Double {
  @image.image_session_viewport_value(id, field)
}

///|
#export_name("image_session_set_text")
pub fn image_session_set_text(id : Int, text : String) -> Int {
  @image.image_session_set_text(id, text)
}

///|
#export_name("image_session_undo")
pub fn image_session_undo(id : Int) -> Int {
  @image.image_session_undo(id)
}

///|
#export_name("image_session_redo")
pub fn image_session_redo(id : Int) -> Int {
  @image.image_session_redo(id)
}

///|
#export_name("image_session_count")
pub fn image_session_count(id : Int) -> Int {
  @image.image_session_count(id)
}

///|
#export_name("image_session_value")
pub fn image_session_value(id : Int, index : Int, field : Int) -> Double {
  @image.image_session_value(id, index, field)
}

///|
#export_name("image_session_text")
pub fn image_session_text(id : Int, index : Int) -> String {
  @image.image_session_text(id, index)
}

///|
#export_name("image_session_dispose")
pub fn image_session_dispose(id : Int) -> Unit {
  @image.image_session_dispose(id)
}

///|
#export_name("crop_rect")
pub fn crop_rect(request : String) -> String {
  @image.crop_rect(request)
}

///|
#export_name("image_selection")
pub fn image_selection(request : String) -> String {
  @image.image_selection(request)
}

///|
#export_name("image_session_hit")
pub fn image_session_hit(
  id : Int,
  x : Double,
  y : Double,
  tolerance : Double,
  text_only : Int,
) -> Int {
  @image.image_session_hit(id, x, y, tolerance, text_only)
}

///|
#export_name("image_arrowhead_value")
pub fn image_arrowhead_value(
  x : Double,
  y : Double,
  x2 : Double,
  y2 : Double,
  stroke : Double,
  field : Int,
) -> Double {
  @image.image_arrowhead_value(x, y, x2, y2, stroke, field)
}

///|
#export_name("image_session_shape_begin")
pub fn image_session_shape_begin(id : Int, kind : Int, x : Double, y : Double, color : Int, stroke : Double, opacity : Double, shape : Int, block : Double) -> Int {
  @image.image_session_shape_begin(id, kind, x, y, color, stroke, opacity, shape, block)
}

///|
#export_name("image_session_shape_event")
pub fn image_session_shape_event(id : Int, phase : Int, x : Double, y : Double) -> Int {
  @image.image_session_shape_event(id, phase, x, y)
}

///|
#export_name("image_session_preview_value")
pub fn image_session_preview_value(id : Int, field : Int) -> Double {
  @image.image_session_preview_value(id, field)
}

///|
#export_name("image_session_set_variant")
pub fn image_session_set_variant(id : Int, index : Int, field : Int, value : Double) -> Int {
  @image.image_session_set_variant(id, index, field, value)
}
