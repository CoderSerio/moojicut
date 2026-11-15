///|
#export_name("plugin_manifest_validate")
pub fn plugin_manifest_validate(manifest_json : String) -> String {
  @plugin_protocol.plugin_manifest_validate(manifest_json)
}

///|
#export_name("plugin_request_prepare")
pub fn plugin_request_prepare(request_json : String) -> String {
  @plugin_protocol.plugin_request_prepare(request_json)
}

///|
#export_name("plugin_output_validate")
pub fn plugin_output_validate(request_json : String) -> String {
  @plugin_protocol.plugin_output_validate(request_json)
}
