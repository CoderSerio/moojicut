// Numeric native ABI: pure sizing, opacity and visibility rules only. Hosts own
// windows, selection/focus events, image buffers and global key registration.

///|
#export_name("pin_scroll_scale")
pub fn pin_scroll_scale(value : Double, steps : Double) -> Double {
  @pin.scroll_scale(value, steps)
}

///|
#export_name("pin_hit_handle")
pub fn pin_hit_handle(
  width : Double,
  height : Double,
  x : Double,
  y : Double,
  margin : Double,
) -> Int32 {
  @pin.hit_handle(width, height, x, y, margin)
}

///|
#export_name("pin_resize_frame")
pub fn pin_resize_frame(
  platform : Int32,
  x : Double,
  y : Double,
  source_width : Double,
  source_height : Double,
  start_scale : Double,
  handle : Int32,
  dx : Double,
  dy : Double,
  work_x : Double,
  work_y : Double,
  work_width : Double,
  work_height : Double,
) -> FixedArray[Double] {
  @pin.resize_frame(
    platform, x, y, source_width, source_height, start_scale, handle, dx, dy, work_x,
    work_y, work_width, work_height,
  )
}

///|
#export_name("pin_scale")
pub fn pin_scale(
  platform : Int32,
  requested : Double,
  width : Double,
  height : Double,
  work_width : Double,
  work_height : Double,
) -> Double {
  @pin.scale(platform, requested, width, height, work_width, work_height)
}

///|
#export_name("pin_initial_scale")
pub fn pin_initial_scale(
  width : Double,
  height : Double,
  work_width : Double,
  work_height : Double,
) -> Double {
  @pin.initial_scale(width, height, work_width, work_height)
}

///|
#export_name("pin_zoom_step")
pub fn pin_zoom_step(value : Double, direction : Int32) -> Double {
  @pin.zoom_step(value, direction)
}

///|
#export_name("pin_opacity")
pub fn pin_opacity(
  platform : Int32,
  value : Double,
  direction : Int32,
) -> Double {
  @pin.opacity(platform, value, direction)
}

///|
#export_name("pin_visibility_action")
pub fn pin_visibility_action(
  platform : Int32,
  has_selected : Int32,
  selected_hidden : Int32,
  selected_passthrough : Int32,
  any_hidden : Int32,
  recovery_available : Int32,
) -> Int32 {
  @pin.visibility_action(
    platform, has_selected, selected_hidden, selected_passthrough, any_hidden, recovery_available,
  )
}

///|
#export_name("pin_hidden_after")
pub fn pin_hidden_after(
  platform : Int32,
  action : Int32,
  hidden : Int32,
  passthrough : Int32,
  target : Int32,
) -> Int32 {
  @pin.hidden_after(platform, action, hidden, passthrough, target)
}
