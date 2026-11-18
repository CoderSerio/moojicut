///|
#export_name("plugin_application_requirements")
pub fn plugin_application_requirements(index : String) -> String {
  @plugin_app.desktop_plugin_requirements(index)
}

///|
#export_name("plugin_application_open")
pub fn plugin_application_open(
  index : String,
  archives : String,
  layout : String,
) -> String {
  @plugin_app.desktop_plugin_open(index, archives, layout)
}

///|
#export_name("plugin_application_request")
pub fn plugin_application_request(handle : Int32, request : String) -> String {
  @plugin_app.desktop_plugin_request(handle, request)
}

///|
#export_name("plugin_application_close")
pub fn plugin_application_close(handle : Int32) -> Int32 {
  @plugin_app.desktop_plugin_close(handle)
}

///|
#export_name("plugin_application_decode_utf8")
pub fn plugin_application_decode_utf8(bytes : Bytes) -> String {
  @utf8.decode(bytes[:], ignore_bom=true) catch { _ => "" }
}

///|
#export_name("plugin_application_encode_utf8")
pub fn plugin_application_encode_utf8(text : String) -> Bytes {
  @utf8.encode(text)
}

///|
#export_name("plugin_application_reply_field")
pub fn plugin_application_reply_field(
  reply : String,
  key : String,
  index : Int,
  child : String,
  literal : Int,
) -> String {
  @plugin_app.desktop_plugin_reply_field(reply, key, index, child, literal)
}
