///|
#export_name("image_session_document")
pub fn image_session_document(session : Int32) -> String {
  @capture.image_session_document(session)
}

///|
#export_name("image_session_revision")
pub fn image_session_revision(session : Int32) -> Double {
  @capture.image_session_revision(session)
}

///|
#export_name("image_session_annotation_id")
pub fn image_session_annotation_id(session : Int32, index : Int32) -> String {
  @capture.image_session_annotation_id(session, index)
}

///|
#export_name("image_session_command")
pub fn image_session_command(
  session : Int32,
  expected_revision : Double,
  command : String,
) -> Int32 {
  @capture.image_session_command(session, expected_revision, command)
}

///|
#export_name("capture_text_begin")
pub fn capture_text_begin(
  session : Int32,
  style : Int32,
  mode : Int32,
  annotation_id : String,
  expected_revision : Double,
  x : Double,
  y : Double,
  width : Double,
  height : Double,
) -> Int32 {
  @capture.text_begin(
    session, style, mode, annotation_id, expected_revision, x, y, width, height,
  )
}

///|
#export_name("image_session_geometry")
pub fn image_session_geometry(
  session : Int32,
  expected_revision : Double,
  annotation_id : String,
  x : Double,
  y : Double,
  width : Double,
  height : Double,
  font_size : Double,
) -> Int32 {
  @capture.image_session_geometry(
    session, expected_revision, annotation_id, x, y, width, height, font_size,
  )
}

///|
#export_name("capture_properties_begin")
pub fn capture_properties_begin(
  session : Int32,
  style : Int32,
  tool : Int32,
  annotation_id : String,
  expected_revision : Double,
  contribution_command : String,
) -> Int32 {
  @capture.properties_begin(
    session, style, tool, annotation_id, expected_revision, contribution_command,
  )
}

///|
#export_name("capture_text_event_json")
pub fn capture_text_event_json(
  session : Int32,
  edit : Int32,
  expected_version : Int32,
  event : String,
) -> Int32 {
  @capture.text_event_json(session, edit, expected_version, event)
}

///|
#export_name("capture_text_snapshot")
pub fn capture_text_snapshot(session : Int32, edit : Int32) -> String {
  @capture.text_snapshot(session, edit)
}

///|
#export_name("capture_text_value")
pub fn capture_text_value(session : Int32, edit : Int32, key : Int32) -> Double {
  @capture.text_value(session, edit, key)
}

///|
#export_name("capture_text_text")
pub fn capture_text_text(session : Int32, edit : Int32, key : Int32) -> String {
  @capture.text_text(session, edit, key)
}

///|
#export_name("capture_text_frame")
pub fn capture_text_frame(
  session : Int32,
  edit : Int32,
  surface : Int32,
  width : Double,
  height : Double,
  scale : Double,
  dark : Int32,
) -> String {
  @capture.text_frame(session, edit, surface, width, height, scale, dark)
}

///|
#export_name("capture_text_ui_event")
pub fn capture_text_ui_event(
  session : Int32,
  edit : Int32,
  version : Int32,
  event : String,
  width : Double,
  height : Double,
) -> Int32 {
  @capture.text_ui_event(session, edit, version, event, width, height)
}

///|
#export_name("capture_text_prepare")
pub fn capture_text_prepare(
  session : Int32,
  edit : Int32,
  version : Int32,
  purpose : Int32,
  measured_height : Double,
) -> Int32 {
  @capture.text_prepare(session, edit, version, purpose, measured_height)
}

///|
#export_name("capture_text_measured_height")
pub fn capture_text_measured_height(
  session : Int32,
  edit : Int32,
  version : Int32,
  measured_height : Double,
) -> Double {
  @capture.text_measured_height(session, edit, version, measured_height)
}

///|
#export_name("capture_text_cancel")
pub fn capture_text_cancel(
  session : Int32,
  edit : Int32,
  version : Int32,
) -> Int32 {
  @capture.text_cancel(session, edit, version)
}

///|
#export_name("capture_candidate_document")
pub fn capture_candidate_document(candidate : Int32) -> String {
  @capture.candidate_document(candidate)
}

///|
#export_name("capture_candidate_ready")
pub fn capture_candidate_ready(session : Int32, candidate : Int32) -> Int32 {
  @capture.candidate_ready(session, candidate)
}

///|
#export_name("capture_candidate_commit")
pub fn capture_candidate_commit(session : Int32, candidate : Int32) -> Int32 {
  @capture.candidate_commit(session, candidate)
}

///|
#export_name("capture_candidate_close")
pub fn capture_candidate_close(candidate : Int32) -> Int32 {
  @capture.candidate_close(candidate)
}

///|
#export_name("capture_candidate_commit_many")
pub fn capture_candidate_commit_many(request : String) -> Int32 {
  @capture.candidate_commit_many(request)
}

///|
#export_name("image_session_prepare_command")
pub fn image_session_prepare_command(
  session : Int32,
  style : Int32,
  expected_revision : Double,
  command : String,
  defaults : String,
) -> Int32 {
  @capture.image_session_prepare_command(
    session, style, expected_revision, command, defaults,
  )
}
