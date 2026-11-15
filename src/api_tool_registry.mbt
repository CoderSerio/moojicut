// Native JSON boundary for the typed built-in catalog and saved tool layout.

///|
#export_name("tool_registry_normalize")
pub fn tool_registry_normalize(saved_json : String) -> String {
  @tool_registry.tool_registry_normalize(saved_json)
}

///|
#export_name("tool_registry_update")
pub fn tool_registry_update(request_json : String) -> String {
  @tool_registry.tool_registry_update(request_json)
}
