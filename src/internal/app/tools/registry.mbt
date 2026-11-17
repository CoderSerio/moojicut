///|
fn contributions() -> Array[@plugin_protocol.ToolContribution] {
  let tools = @annotations.contributions()
  tools.push(@pin.contribution())
  tools.push(@ocr.contribution())
  tools.push(@translation.contribution())
  tools.push(@scroll.contribution())
  tools.push(@annotations.numbered_rectangle_contribution())
  tools
}

///|
pub fn tool_registry_normalize(saved : String) -> String {
  @catalog.normalize(contributions(), saved)
}

///|
pub fn tool_registry_update(request : String) -> String {
  @catalog.update_catalog(contributions(), request)
}

///|
pub fn tool_registry_resolve(request : String) -> String {
  @catalog.resolve_catalog(contributions(), request)
}

///|
pub fn tool_registry_snapshot_open(
  response : String,
  capabilities : Int32,
) -> Int32 {
  @catalog.snapshot_open(contributions(), response, capabilities)
}

///|
pub fn tool_registry_snapshot_count(handle : Int32, group : Int32) -> Int32 {
  @catalog.snapshot_count(handle, group)
}

///|
pub fn tool_registry_snapshot_value(
  handle : Int32,
  group : Int32,
  index : Int32,
  key : Int32,
) -> Int32 {
  @catalog.snapshot_value(handle, group, index, key)
}

///|
pub fn tool_registry_snapshot_text(
  handle : Int32,
  group : Int32,
  index : Int32,
  key : Int32,
) -> String {
  @catalog.snapshot_text(handle, group, index, key)
}

///|
pub fn tool_registry_snapshot_layout(handle : Int32) -> String {
  @catalog.snapshot_layout(handle)
}

///|
pub fn tool_registry_snapshot_set_enabled(
  handle : Int32,
  id : String,
  enabled : Int32,
) -> Int32 {
  @catalog.snapshot_set_enabled(contributions(), handle, id, enabled)
}

///|
pub fn tool_registry_snapshot_move(
  handle : Int32,
  id : String,
  before : String,
) -> Int32 {
  @catalog.snapshot_move(contributions(), handle, id, before)
}

///|
pub fn tool_registry_snapshot_close(handle : Int32) -> Int32 {
  @catalog.snapshot_close(handle)
}
