// Native ABI entry points. Video documents, timeline planning and sessions
// live in internal/video; keep exported names and signatures stable.

///|
#export_name("video_open")
pub fn video_open(source_text : String, draft_text : String) -> String {
  @video.video_open(source_text, draft_text)
}

///|
#export_name("video_command")
pub fn video_command(id : Int, command_text : String) -> String {
  @video.video_command(id, command_text)
}

///|
#export_name("video_snapshot")
pub fn video_snapshot(id : Int) -> String {
  @video.video_snapshot(id)
}

///|
#export_name("video_seek")
pub fn video_seek(id : Int, milliseconds : Double) -> String {
  @video.video_seek(id, milliseconds)
}

///|
#export_name("video_source_time")
pub fn video_source_time(id : Int, milliseconds : Double) -> Double {
  @video.video_source_time(id, milliseconds)
}

///|
#export_name("video_timeline_x_for_time")
pub fn video_timeline_x_for_time(
  time_ms : Double, duration_ms : Double, track_x : Double, track_width : Double,
) -> Double {
  @video.timeline_x_for_time(time_ms, duration_ms, track_x, track_width)
}

///|
#export_name("video_timeline_time_for_x")
pub fn video_timeline_time_for_x(
  x : Double, duration_ms : Double, track_x : Double, track_width : Double,
) -> Double {
  @video.timeline_time_for_x(x, duration_ms, track_x, track_width)
}

///|
#export_name("video_timeline_trim_boundary")
pub fn video_timeline_trim_boundary(
  edge : Int, candidate_ms : Double, start_ms : Double, end_ms : Double,
  duration_ms : Double, min_span_ms : Double,
) -> Double {
  @video.timeline_trim_boundary(edge, candidate_ms, start_ms, end_ms, duration_ms, min_span_ms)
}

///|
#export_name("video_timeline_tick_step")
pub fn video_timeline_tick_step(
  duration_ms : Double, track_width : Double, min_label_spacing : Double,
) -> Double {
  @video.timeline_tick_step(duration_ms, track_width, min_label_spacing)
}

///|
#export_name("video_dispose")
pub fn video_dispose(id : Int) -> Unit {
  @video.video_dispose(id)
}

///|
#export_name("native_video_resume")
pub fn native_video_resume(
  duration_ms : Int, width : Int, height : Int, has_audio : Int, draft : String,
) -> Int {
  @video.native_video_resume(duration_ms, width, height, has_audio, draft)
}

///|
#export_name("native_video_open")
pub fn native_video_open(duration_ms : Int, width : Int, height : Int, has_audio : Int) -> Int {
  @video.native_video_open(duration_ms, width, height, has_audio)
}

///|
#export_name("native_video_trim")
pub fn native_video_trim(handle : Int, start_ms : Int, end_ms : Int) -> Int {
  @video.native_video_trim(handle, start_ms, end_ms)
}

///|
#export_name("native_video_cut")
pub fn native_video_cut(handle : Int, start_ms : Int, end_ms : Int) -> Int {
  @video.native_video_cut(handle, start_ms, end_ms)
}

///|
#export_name("native_video_clear_cuts")
pub fn native_video_clear_cuts(handle : Int) -> Int {
  @video.native_video_clear_cuts(handle)
}

///|
#export_name("native_video_crop")
pub fn native_video_crop(handle : Int, x : Int, y : Int, width : Int, height : Int) -> Int {
  @video.native_video_crop(handle, x, y, width, height)
}

///|
#export_name("native_video_reset_crop")
pub fn native_video_reset_crop(handle : Int) -> Int {
  @video.native_video_reset_crop(handle)
}

///|
#export_name("native_video_mute")
pub fn native_video_mute(handle : Int, muted : Int) -> Int {
  @video.native_video_mute(handle, muted)
}

///|
#export_name("native_video_undo")
pub fn native_video_undo(handle : Int) -> Int {
  @video.native_video_undo(handle)
}

///|
#export_name("native_video_redo")
pub fn native_video_redo(handle : Int) -> Int {
  @video.native_video_redo(handle)
}

///|
#export_name("native_video_reset")
pub fn native_video_reset(handle : Int) -> Int {
  @video.native_video_reset(handle)
}

///|
#export_name("native_video_duration")
pub fn native_video_duration(handle : Int) -> Int {
  @video.native_video_duration(handle)
}

///|
#export_name("native_video_segment_count")
pub fn native_video_segment_count(handle : Int) -> Int {
  @video.native_video_segment_count(handle)
}

///|
#export_name("native_video_segment_value")
pub fn native_video_segment_value(handle : Int, index : Int, field : Int) -> Int {
  @video.native_video_segment_value(handle, index, field)
}

///|
#export_name("native_video_crop_value")
pub fn native_video_crop_value(handle : Int, field : Int) -> Int {
  @video.native_video_crop_value(handle, field)
}

///|
#export_name("native_video_edit_value")
pub fn native_video_edit_value(handle : Int, field : Int) -> Int {
  @video.native_video_edit_value(handle, field)
}

///|
#export_name("native_video_snapshot")
pub fn native_video_snapshot(handle : Int) -> String {
  @video.native_video_snapshot(handle)
}

///|
#export_name("native_video_close")
pub fn native_video_close(handle : Int) -> Unit {
  @video.native_video_close(handle)
}

///|
#export_name("native_video_error")
pub fn native_video_error(handle : Int) -> String {
  @video.native_video_error(handle)
}

///|
#export_name("edit_plan")
pub fn edit_plan(request : String) -> String {
  @video.edit_plan(request)
}

///|
#export_name("export_profile")
pub fn export_profile(request : String) -> String {
  @video.export_profile(request)
}

///|
#export_name("recording_transition")
pub fn recording_transition(state : String, event : String) -> String {
  @recording.recording_transition(state, event)
}

///|
#export_name("recording_plan")
pub fn recording_plan(request : String) -> String {
  @recording.recording_plan(request)
}

///|
#export_name("native_recording_plan")
pub fn native_recording_plan(
  platform : Int32,
  width : Int32,
  height : Int32,
  system_audio : Int32,
) -> FixedArray[Int32] {
  @recording.native_recording_plan(platform, width, height, system_audio)
}

///|
#export_name("recording_status")
pub fn recording_status(state : String) -> String {
  @recording.recording_status(state)
}
