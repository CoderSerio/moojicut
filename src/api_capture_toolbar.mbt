///|
#export_name("capture_toolbar_open")
pub fn capture_toolbar_open(
  image : Int32,
  style : Int32,
  snapshot : Int32,
) -> Int32 {
  @tool_registry.capture_toolbar_open(image, style, snapshot)
}

///|
#export_name("capture_toolbar_context")
pub fn capture_toolbar_context(handle : Int32, facts : String) -> Int32 {
  @capture.toolbar_context(handle, facts)
}

///|
#export_name("capture_toolbar_frame")
pub fn capture_toolbar_frame(
  handle : Int32,
  width : Double,
  dark : Int32,
) -> String {
  @capture.toolbar_frame(handle, width, dark)
}

///|
#export_name("capture_toolbar_event")
pub fn capture_toolbar_event(
  handle : Int32,
  generation : Int32,
  event : String,
) -> Int32 {
  @capture.toolbar_event(handle, generation, event)
}

///|
#export_name("capture_toolbar_activate")
pub fn capture_toolbar_activate(
  handle : Int32,
  generation : Int32,
  id : String,
) -> Int32 {
  @capture.toolbar_activate(handle, generation, id)
}

///|
#export_name("capture_toolbar_value")
pub fn capture_toolbar_value(handle : Int32, key : Int32) -> Double {
  @capture.toolbar_value(handle, key)
}

///|
#export_name("capture_toolbar_text")
pub fn capture_toolbar_text(handle : Int32, key : Int32) -> String {
  @capture.toolbar_text(handle, key)
}

///|
#export_name("capture_toolbar_tool_enabled")
pub fn capture_toolbar_tool_enabled(handle : Int32, kind : Int32) -> Int32 {
  @capture.toolbar_tool_enabled(handle, kind)
}

///|
#export_name("capture_toolbar_ack")
pub fn capture_toolbar_ack(
  handle : Int32,
  ticket : Int32,
  success : Int32,
  error : String,
) -> Int32 {
  @capture.toolbar_ack(handle, ticket, success, error)
}

///|
#export_name("capture_toolbar_config_prepare")
pub fn capture_toolbar_config_prepare(
  handle : Int32,
  snapshot : Int32,
) -> Int32 {
  @tool_registry.capture_toolbar_config_prepare(handle, snapshot)
}

///|
#export_name("capture_toolbar_config_ready")
pub fn capture_toolbar_config_ready(handle : Int32, ticket : Int32) -> Int32 {
  @capture.toolbar_config_ready(handle, ticket)
}

///|
#export_name("capture_toolbar_config_commit_many")
pub fn capture_toolbar_config_commit_many(request : String) -> Int32 {
  @capture.toolbar_config_commit_many(request)
}

///|
#export_name("capture_toolbar_config_close")
pub fn capture_toolbar_config_close(ticket : Int32) -> Int32 {
  @capture.toolbar_config_close(ticket)
}

///|
#export_name("capture_toolbar_close")
pub fn capture_toolbar_close(handle : Int32) -> Int32 {
  @capture.toolbar_close(handle)
}
