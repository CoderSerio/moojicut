///|
#export_name("ui_frame_open")
pub fn ui_frame_open(json : String) -> Int32 {
  @ui_frame.open(json)
}

///|
#export_name("ui_frame_close")
pub fn ui_frame_close(handle : Int32) -> Int32 {
  @ui_frame.close(handle)
}

///|
#export_name("ui_frame_value")
pub fn ui_frame_value(handle : Int32, field : Int32) -> Int32 {
  @ui_frame.value(handle, field)
}

///|
#export_name("ui_frame_video_rect")
pub fn ui_frame_video_rect(handle : Int32, field : Int32) -> Double {
  @ui_frame.video_rect(handle, field)
}

///|
#export_name("ui_frame_command_count")
pub fn ui_frame_command_count(handle : Int32, layer : Int32) -> Int32 {
  @ui_frame.command_count(handle, layer)
}

///|
#export_name("ui_frame_command_value")
pub fn ui_frame_command_value(
  handle : Int32,
  layer : Int32,
  index : Int32,
  field : Int32,
) -> Int32 {
  @ui_frame.command_value(handle, layer, index, field)
}

///|
#export_name("ui_frame_command_number")
pub fn ui_frame_command_number(
  handle : Int32,
  layer : Int32,
  index : Int32,
  field : Int32,
) -> Double {
  @ui_frame.command_number(handle, layer, index, field)
}

///|
#export_name("ui_frame_command_text")
pub fn ui_frame_command_text(
  handle : Int32,
  layer : Int32,
  index : Int32,
) -> String {
  @ui_frame.command_text(handle, layer, index)
}

///|
#export_name("ui_frame_semantic_count")
pub fn ui_frame_semantic_count(handle : Int32) -> Int32 {
  @ui_frame.semantic_count(handle)
}

///|
#export_name("ui_frame_semantic_value")
pub fn ui_frame_semantic_value(
  handle : Int32,
  index : Int32,
  field : Int32,
) -> Int32 {
  @ui_frame.semantic_value(handle, index, field)
}

///|
#export_name("ui_frame_semantic_number")
pub fn ui_frame_semantic_number(
  handle : Int32,
  index : Int32,
  field : Int32,
) -> Double {
  @ui_frame.semantic_number(handle, index, field)
}

///|
#export_name("ui_frame_semantic_text")
pub fn ui_frame_semantic_text(
  handle : Int32,
  index : Int32,
  field : Int32,
) -> String {
  @ui_frame.semantic_text(handle, index, field)
}

///|
#export_name("ui_input_event")
pub fn ui_input_event(
  kind : Int32,
  x : Double,
  y : Double,
  dx : Double,
  dy : Double,
  flags : Int32,
  text : String,
) -> String {
  @ui_frame.input_event(kind, x, y, dx, dy, flags, text)
}
