///|
#export_name("video_editor_media_failed")
pub fn video_editor_media_failed(handle : Int, generation : Int, message : String) -> Int {
  if @video_editor.media_failed(handle, generation, message) { 1 } else { 0 }
}

///|
#export_name("video_editor_open_unsaved")
pub fn video_editor_open_unsaved(source_path : String, metadata : String, draft : String) -> Int {
  @video_editor.open_unsaved(source_path, metadata, draft)
}

///|
#export_name("video_editor_open")
pub fn video_editor_open(source_path : String, metadata : String, draft : String) -> Int {
  @video_editor.open(source_path, metadata, draft)
}

///|
#export_name("video_editor_event")
pub fn video_editor_event(handle : Int, input : String) -> Int {
  if @video_editor.event(handle, input) { 1 } else { 0 }
}

///|
#export_name("video_editor_command")
pub fn video_editor_command(handle : Int, command : String) -> Int {
  if @video_editor.command(handle, command) { 1 } else { 0 }
}

///|
#export_name("video_editor_frame")
pub fn video_editor_frame(handle : Int, width : Double, height : Double) -> String {
  @video_editor.frame(handle, width, height)
}

///|
#export_name("video_editor_state")
pub fn video_editor_state(handle : Int) -> String {
  @video_editor.state(handle)
}

///|
#export_name("video_editor_value")
pub fn video_editor_value(handle : Int, key : Int) -> Int {
  @video_editor.value(handle, key)
}

///|
#export_name("video_editor_number")
pub fn video_editor_number(handle : Int, key : Int) -> Double {
  @video_editor.number(handle, key)
}

///|
#export_name("video_editor_text")
pub fn video_editor_text(handle : Int, key : Int) -> String {
  @video_editor.text(handle, key)
}

///|
#export_name("video_editor_take_effect")
pub fn video_editor_take_effect(handle : Int) -> Int {
  @video_editor.take_effect(handle)
}

///|
#export_name("video_editor_effect_kind")
pub fn video_editor_effect_kind(handle : Int, effect : Int) -> Int {
  @video_editor.effect_kind(handle, effect)
}

///|
#export_name("video_editor_effect_plan")
pub fn video_editor_effect_plan(handle : Int, effect : Int) -> Int {
  @video_editor.effect_plan(handle, effect)
}

///|
#export_name("video_editor_effect_generation")
pub fn video_editor_effect_generation(handle : Int, effect : Int) -> Int {
  @video_editor.effect_generation(handle, effect)
}

///|
#export_name("video_editor_effect_revision")
pub fn video_editor_effect_revision(handle : Int, effect : Int) -> Double {
  @video_editor.effect_revision(handle, effect)
}

///|
#export_name("video_editor_effect_number")
pub fn video_editor_effect_number(handle : Int, effect : Int) -> Double {
  @video_editor.effect_number(handle, effect)
}

///|
#export_name("video_editor_effect_text")
pub fn video_editor_effect_text(handle : Int, effect : Int) -> String {
  @video_editor.effect_text(handle, effect)
}

///|
#export_name("video_editor_ack")
pub fn video_editor_ack(handle : Int, effect : Int, status : Int, message : String) -> Int {
  if @video_editor.ack(handle, effect, status, message) { 1 } else { 0 }
}

///|
#export_name("video_editor_playback")
pub fn video_editor_playback(handle : Int, generation : Int, milliseconds : Double, playing : Int) -> Int {
  if @video_editor.playback(handle, generation, milliseconds, playing != 0) { 1 } else { 0 }
}

///|
#export_name("video_editor_export_progress")
pub fn video_editor_export_progress(handle : Int, effect : Int, fraction : Double) -> Int {
  if @video_editor.export_progress(handle, effect, fraction) { 1 } else { 0 }
}

///|
#export_name("video_editor_waveform")
pub fn video_editor_waveform(handle : Int, event : String) -> Int {
  if @video_editor.waveform(handle, event) { 1 } else { 0 }
}

///|
#export_name("video_editor_retry")
pub fn video_editor_retry(handle : Int) -> Int {
  if @video_editor.retry(handle) { 1 } else { 0 }
}

///|
#export_name("video_editor_request_close")
pub fn video_editor_request_close(handle : Int, cancel_export : Int) -> Int {
  if @video_editor.request_close(handle, cancel_export != 0) { 1 } else { 0 }
}

///|
#export_name("video_editor_release")
pub fn video_editor_release(handle : Int) -> Int {
  if @video_editor.release(handle) { 1 } else { 0 }
}
