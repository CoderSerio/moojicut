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
