///|
// Typed native adapters share the existing video reducer and its history.
// Handles reserve zero for failure; the underlying reducer starts at zero.
let native_video_errors : Map[Int, String] = Map([])

///|
fn native_video_remember_error(handle : Int, text : String) -> Unit {
  let parsed = @json.parse(text) catch { _ => Json::null() }
  let message = match parsed {
    Object({ "error": Object({ "message": String(value), .. }), .. }) => value
    _ => "无法完成视频编辑"
  }
  native_video_errors[handle] = message
}

///|
fn native_video_result(text : String) -> Map[String, Json]? {
  let parsed = @json.parse(text) catch { _ => return None }
  match parsed {
    Object({ "ok": True, .. } as fields) => Some(fields)
    _ => None
  }
}

///|
fn native_video_state(handle : Int) -> Map[String, Json]? {
  if handle <= 0 { return None }
  native_video_result(video_snapshot(handle - 1))
}

///|
fn native_video_object(fields : Map[String, Json], key : String) -> Map[String, Json]? {
  match fields.get(key) { Some(Object(value)) => Some(value); _ => None }
}

///|
fn native_video_integer(fields : Map[String, Json], key : String) -> Int {
  match fields.get(key) {
    Some(Number(value, ..)) => if value >= 0 && value <= 604800000 { value.to_int() } else { -1 }
    _ => -1
  }
}

///|
#export_name("native_video_resume")
pub fn native_video_resume(
  duration_ms : Int, width : Int, height : Int, has_audio : Int, draft : String,
) -> Int {
  if has_audio != 0 && has_audio != 1 {
    native_video_errors[0] = "has_audio 必须为 0 或 1"
    return 0
  }
  let source = Json::object({
    "durationMs": Json(duration_ms), "width": Json(width), "height": Json(height),
    "hasAudio": Json(has_audio == 1),
  })
  let response = video_open(source.stringify(), draft)
  let result = match native_video_result(response) {
    Some(result) => result
    None => { native_video_remember_error(0, response); return 0 }
  }
  let session = match result.get("session") {
    Some(Number(value, ..)) => if value >= 0 && value < 2147483647 { value.to_int() } else { return 0 }
    _ => return 0
  }
  native_video_errors.remove(0)
  session + 1
}

///|
#export_name("native_video_open")
pub fn native_video_open(duration_ms : Int, width : Int, height : Int, has_audio : Int) -> Int {
  native_video_resume(duration_ms, width, height, has_audio, "")
}

///|
fn native_video_command(handle : Int, command : Json) -> Int {
  if handle <= 0 { native_video_errors[0] = "视频编辑会话已关闭"; return 0 }
  let response = video_command(handle - 1, command.stringify())
  match native_video_result(response) {
    Some(_) => { native_video_errors.remove(handle); 1 }
    None => { native_video_remember_error(handle, response); 0 }
  }
}

///|
#export_name("native_video_trim")
pub fn native_video_trim(handle : Int, start_ms : Int, end_ms : Int) -> Int {
  native_video_command(handle, Json::object({
    "type": Json("trim"), "trim": Json::object({ "startMs": Json(start_ms), "endMs": Json(end_ms) }),
  }))
}

///|
#export_name("native_video_cut")
pub fn native_video_cut(handle : Int, start_ms : Int, end_ms : Int) -> Int {
  native_video_command(handle, Json::object({
    "type": Json("cut"), "cut": Json::object({ "startMs": Json(start_ms), "endMs": Json(end_ms) }),
  }))
}

///|
#export_name("native_video_clear_cuts")
pub fn native_video_clear_cuts(handle : Int) -> Int {
  native_video_command(handle, Json::object({ "type": Json("clearCuts") }))
}

///|
#export_name("native_video_crop")
pub fn native_video_crop(handle : Int, x : Int, y : Int, width : Int, height : Int) -> Int {
  native_video_command(handle, Json::object({
    "type": Json("crop"), "crop": Json::object({
      "x": Json(x), "y": Json(y), "width": Json(width), "height": Json(height),
    }),
  }))
}

///|
#export_name("native_video_reset_crop")
pub fn native_video_reset_crop(handle : Int) -> Int {
  native_video_command(handle, Json::object({ "type": Json("crop"), "crop": Json::null() }))
}

///|
#export_name("native_video_mute")
pub fn native_video_mute(handle : Int, muted : Int) -> Int {
  if muted != 0 && muted != 1 {
    native_video_errors[if handle > 0 { handle } else { 0 }] = "muted 必须为 0 或 1"
    return 0
  }
  native_video_command(handle, Json::object({ "type": Json("mute"), "muted": Json(muted == 1) }))
}

///|
#export_name("native_video_undo")
pub fn native_video_undo(handle : Int) -> Int {
  native_video_command(handle, Json::object({ "type": Json("undo") }))
}

///|
#export_name("native_video_redo")
pub fn native_video_redo(handle : Int) -> Int {
  native_video_command(handle, Json::object({ "type": Json("redo") }))
}

///|
#export_name("native_video_reset")
pub fn native_video_reset(handle : Int) -> Int {
  native_video_command(handle, Json::object({ "type": Json("reset") }))
}

///|
#export_name("native_video_duration")
pub fn native_video_duration(handle : Int) -> Int {
  let state = match native_video_state(handle) { Some(state) => state; None => return 0 }
  let plan = match native_video_object(state, "plan") { Some(plan) => plan; None => return 0 }
  let duration = native_video_integer(plan, "outputDurationMs")
  if duration < 0 { 0 } else { duration }
}

///|
fn native_video_segments(handle : Int) -> Array[Json] {
  let state = match native_video_state(handle) { Some(state) => state; None => return [] }
  let plan = match native_video_object(state, "plan") { Some(plan) => plan; None => return [] }
  match plan.get("segments") { Some(Array(items)) => items; _ => [] }
}

///|
#export_name("native_video_segment_count")
pub fn native_video_segment_count(handle : Int) -> Int { native_video_segments(handle).length() }

///|
#export_name("native_video_segment_value")
pub fn native_video_segment_value(handle : Int, index : Int, field : Int) -> Int {
  let key = match field {
    0 => "sourceStartMs"; 1 => "sourceEndMs"; 2 => "outputStartMs"; 3 => "outputEndMs"; _ => return -1
  }
  let segments = native_video_segments(handle)
  if index < 0 || index >= segments.length() { return -1 }
  match segments[index] { Object(segment) => native_video_integer(segment, key); _ => -1 }
}

///|
#export_name("native_video_crop_value")
pub fn native_video_crop_value(handle : Int, field : Int) -> Int {
  let key = match field { 0 => "x"; 1 => "y"; 2 => "width"; 3 => "height"; _ => return -1 }
  let state = match native_video_state(handle) { Some(state) => state; None => return -1 }
  let plan = match native_video_object(state, "plan") { Some(plan) => plan; None => return -1 }
  match native_video_object(plan, "crop") {
    Some(crop) => native_video_integer(crop, key)
    None => {
      if field <= 1 { return 0 }
      let document = match native_video_object(state, "document") { Some(value) => value; None => return -1 }
      let source = match native_video_object(document, "source") { Some(value) => value; None => return -1 }
      native_video_integer(source, key)
    }
  }
}

///|
// Editor fields are read from the reducer document, never inferred from kept
// segments: a deletion at a trim boundary changes the plan but not the trim.
#export_name("native_video_edit_value")
pub fn native_video_edit_value(handle : Int, field : Int) -> Int {
  let state = match native_video_state(handle) { Some(state) => state; None => return -1 }
  if field == 3 || field == 4 {
    return match state.get(if field == 3 { "canUndo" } else { "canRedo" }) {
      Some(True) => 1; Some(False) => 0; _ => -1
    }
  }
  let document = match native_video_object(state, "document") { Some(value) => value; None => return -1 }
  if field == 0 || field == 1 {
    let trim = match native_video_object(document, "trim") { Some(value) => value; None => return -1 }
    return native_video_integer(trim, if field == 0 { "startMs" } else { "endMs" })
  }
  if field == 2 {
    return match document.get("muted") { Some(True) => 1; Some(False) => 0; _ => -1 }
  }
  if field == 5 {
    let legacy = match document.get("cut") { Some(Object(_)) => 1; _ => 0 }
    return match document.get("cuts") { Some(Array(items)) => items.length() + legacy; _ => legacy }
  }
  -1
}

///|
#export_name("native_video_snapshot")
pub fn native_video_snapshot(handle : Int) -> String {
  let state = match native_video_state(handle) { Some(state) => state; None => return "" }
  match native_video_object(state, "document") {
    Some(document) => Json::object(document).stringify()
    None => ""
  }
}

///|
#export_name("native_video_close")
pub fn native_video_close(handle : Int) -> Unit {
  if handle > 0 { video_dispose(handle - 1) }
  native_video_errors.remove(handle)
}

///|
#export_name("native_video_error")
pub fn native_video_error(handle : Int) -> String {
  native_video_errors.get(if handle > 0 { handle } else { 0 }).unwrap_or("")
}
