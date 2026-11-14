// Stable scalar C entry points. Returned FixedArray[Double] values are owned
// by the caller, which reads their coordinates and releases them with moonbit_decref.

///|
#export_name("selection_region")
pub fn selection_region(ax : Double, ay : Double, bx : Double, by : Double) -> FixedArray[Double] {
  @selection.region(ax, ay, bx, by)
}

///|
#export_name("selection_handle_point")
pub fn selection_handle_point(
  x : Double, y : Double, width : Double, height : Double,
  handle : Int, midpoint_mode : Int,
) -> FixedArray[Double] {
  @selection.handle_point(x, y, width, height, handle, midpoint_mode)
}

///|
#export_name("selection_hit_handle")
pub fn selection_hit_handle(
  x : Double, y : Double, width : Double, height : Double,
  px : Double, py : Double, radius : Double,
  midpoint_mode : Int,
) -> Int {
  @selection.hit_handle(x, y, width, height, px, py, radius, midpoint_mode)
}

///|
#export_name("selection_contains")
pub fn selection_contains(
  x : Double, y : Double, width : Double, height : Double,
  px : Double, py : Double,
) -> Int {
  @selection.contains(x, y, width, height, px, py)
}

///|
#export_name("selection_border_contains")
pub fn selection_border_contains(
  x : Double, y : Double, width : Double, height : Double,
  px : Double, py : Double, radius : Double,
) -> Int {
  @selection.border_contains(x, y, width, height, px, py, radius)
}

///|
#export_name("selection_transform")
pub fn selection_transform(
  x : Double, y : Double, width : Double, height : Double,
  ax : Double, ay : Double, px : Double, py : Double,
  handle : Int,
  bounds_x : Double, bounds_y : Double, bounds_width : Double, bounds_height : Double,
  minimum : Double, directed : Int,
) -> FixedArray[Double] {
  @selection.transform(x, y, width, height, ax, ay, px, py, handle,
    bounds_x, bounds_y, bounds_width, bounds_height, minimum, directed=directed != 0)
}
