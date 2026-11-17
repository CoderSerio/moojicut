///|
#export_name("recording_flow_open")
pub fn recording_flow_open() -> Int32 {
  @recording.recording_flow_open()
}

///|
#export_name("recording_flow_event")
pub fn recording_flow_event(
  handle : Int32,
  event : Int32,
  now : Double,
) -> Int32 {
  @recording.recording_flow_event(handle, event, now)
}

///|
#export_name("recording_flow_value")
pub fn recording_flow_value(handle : Int32, key : Int32) -> Int32 {
  @recording.recording_flow_value(handle, key)
}

///|
#export_name("recording_flow_close")
pub fn recording_flow_close(handle : Int32) -> Int32 {
  @recording.recording_flow_close(handle)
}

///|
#export_name("recording_ui_frame")
pub fn recording_ui_frame(
  handle : Int32,
  width : Double,
  height : Double,
) -> FixedArray[Double] {
  @recording_ui.recording_ui_frame(handle, width, height)
}

///|
#export_name("recording_ui_hit")
pub fn recording_ui_hit(
  handle : Int32,
  x : Double,
  y : Double,
  width : Double,
  height : Double,
) -> Int32 {
  @recording_ui.recording_ui_hit(handle, x, y, width, height)
}

///|
#export_name("recording_ui_text")
pub fn recording_ui_text(handle : Int32) -> String {
  @recording_ui.recording_ui_text(handle)
}
