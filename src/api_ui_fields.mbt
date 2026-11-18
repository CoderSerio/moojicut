///|
#export_name("ui_frame_field_count")
pub fn ui_frame_field_count(handle : Int32) -> Int32 {
  @ui_frame.field_count(handle)
}

///|
#export_name("ui_frame_field_value")
pub fn ui_frame_field_value(
  handle : Int32,
  index : Int32,
  key : Int32,
) -> Int32 {
  @ui_frame.field_value(handle, index, key)
}

///|
#export_name("ui_frame_field_number")
pub fn ui_frame_field_number(
  handle : Int32,
  index : Int32,
  key : Int32,
) -> Double {
  @ui_frame.field_number(handle, index, key)
}

///|
#export_name("ui_frame_field_text")
pub fn ui_frame_field_text(
  handle : Int32,
  index : Int32,
  key : Int32,
) -> String {
  @ui_frame.field_text(handle, index, key)
}

///|
#export_name("ui_text_event")
pub fn ui_text_event(
  kind : Int32,
  id : String,
  token : Int32,
  version : Int32,
  start : Int32,
  end : Int32,
  text : String,
  selection_kind : Int32,
  anchor : Int32,
  focus : Int32,
) -> String {
  @ui_frame.text_event(
    kind, id, token, version, start, end, text, selection_kind, anchor, focus,
  )
}
