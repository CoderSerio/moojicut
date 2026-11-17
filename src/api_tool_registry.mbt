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

///|
#export_name("tool_registry_resolve")
pub fn tool_registry_resolve(request_json : String) -> String {
  @tool_registry.tool_registry_resolve(request_json)
}

///|
#export_name("tool_registry_snapshot_open")
pub fn tool_registry_snapshot_open(response : String, capabilities : Int) -> Int { @tool_registry.tool_registry_snapshot_open(response, capabilities) }

///|
#export_name("tool_registry_snapshot_count")
pub fn tool_registry_snapshot_count(handle : Int, group : Int) -> Int { @tool_registry.tool_registry_snapshot_count(handle, group) }

///|
#export_name("tool_registry_snapshot_value")
pub fn tool_registry_snapshot_value(handle : Int, group : Int, index : Int, key : Int) -> Int { @tool_registry.tool_registry_snapshot_value(handle, group, index, key) }

///|
#export_name("tool_registry_snapshot_text")
pub fn tool_registry_snapshot_text(handle : Int, group : Int, index : Int, key : Int) -> String { @tool_registry.tool_registry_snapshot_text(handle, group, index, key) }

///|
#export_name("tool_registry_snapshot_layout")
pub fn tool_registry_snapshot_layout(handle : Int) -> String { @tool_registry.tool_registry_snapshot_layout(handle) }

///|
#export_name("tool_registry_snapshot_set_enabled")
pub fn tool_registry_snapshot_set_enabled(handle : Int, id : String, enabled : Int) -> Int { @tool_registry.tool_registry_snapshot_set_enabled(handle, id, enabled) }

///|
#export_name("tool_registry_snapshot_move")
pub fn tool_registry_snapshot_move(handle : Int, id : String, before : String) -> Int { @tool_registry.tool_registry_snapshot_move(handle, id, before) }

///|
#export_name("tool_registry_snapshot_close")
pub fn tool_registry_snapshot_close(handle : Int) -> Int { @tool_registry.tool_registry_snapshot_close(handle) }
