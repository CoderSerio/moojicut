// Scalar native ABI: pure sizing, opacity and visibility rules only. Hosts own
// windows, selection/focus events, image buffers and global key registration.

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
