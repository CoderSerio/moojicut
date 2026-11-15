// The shared component owns layout, rendering descriptions and interactions.
// Hosts only render commands, forward events and execute explicit effects.

///|
#export_name("video_ui_open")
pub fn video_ui_open(snapshot : String) -> Int {
  @video_ui.open(snapshot)
}

///|
#export_name("video_ui_event")
pub fn video_ui_event(id : Int, event_json : String) -> String {
  @video_ui.event(id, event_json)
}

///|
#export_name("video_ui_frame")
pub fn video_ui_frame(id : Int, width : Double, height : Double) -> String {
  @video_ui.frame(id, width, height)
}

///|
#export_name("video_ui_close")
pub fn video_ui_close(id : Int) -> Unit {
  @video_ui.close(id)
}
