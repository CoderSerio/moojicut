///|
#export_name("capture_ui_open")
pub fn capture_ui_open(width : Double, height : Double) -> Int32 {
  @capture_ui.open(width, height)
}

///|
#export_name("capture_ui_event")
pub fn capture_ui_event(request : String) -> String {
  @capture_ui.event(request)
}

///|
#export_name("capture_ui_close")
pub fn capture_ui_close(id : Int32) -> Unit {
  @capture_ui.close(id)
}

///|
#export_name("capture_ui_toolbar_frame")
pub fn capture_ui_toolbar_frame(
  sw : Double,
  sh : Double,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  row : Double,
  properties : Double,
) -> FixedArray[Double] {
  @capture_ui.toolbar_frame(sw, sh, x, y, w, h, row, properties)
}
