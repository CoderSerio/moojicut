///|
// V2 packages enter the same identity, preference, slot and snapshot pipeline
// as app-supplied built-ins. The catalog describes contributions; it neither
// owns a plugin invocation nor interprets its controlled response.
fn encode_package_tool(
  tool : @plugin_protocol.PluginContribution,
  enabled : Bool,
) -> Json {
  Json::object({
    "id": Json(tool.id()),
    "pluginId": Json(tool.plugin_id),
    "toolId": Json(tool.tool_id),
    "title": Json(tool.title),
    "target": Json("screenshot"),
    "type": Json("action"),
    "action": Json("invoke"),
    "icon": Json("plugin"),
    "slot": Json("tools"),
    "command": Json("plugin.run"),
    "interaction": Json(
      match tool.gesture {
        Invoke => "invoke"
        DragRect => "dragRect"
      },
    ),
    "enabled": Json(enabled),
    "defaultEnabled": Json(true),
    "capability": Json(16),
    "requires": Json("userPlugins"),
    "payload": Json::object({ "effect": Json(tool.effect.key()) }),
  })
}

///|
fn decode_package_catalog(
  builtins : Array[@plugin_protocol.ToolContribution],
  value : Json,
) -> Catalog raise InputError {
  let base = builtin_catalog(builtins)
  let manifests = match value {
    Array(items) if items.length() <= 64 => items
    _ =>
      raise InputError(
        "invalid_catalog", "manifests must be an array with at most 64 packages",
      )
  }
  let seen : Map[String, Bool] = Map([])
  let users : Array[AvailableTool] = []
  let canonical : Array[Json] = []
  for value in manifests {
    let manifest = @plugin_protocol.parse_plugin_package(value.stringify())
    if seen.contains(manifest.plugin_id) {
      raise InputError(
        "invalid_catalog", "Duplicate pluginId in installed catalog",
      )
    }
    seen[manifest.plugin_id] = true
    for tool in manifest.contributions() {
      if users.length() >= 64 {
        raise InputError(
          "invalid_catalog", "Installed catalog exceeds 64 user tools",
        )
      }
      if base.find(tool.id()) is Some(_) {
        raise InputError("invalid_catalog", "Contribution identity collision")
      }
      users.push(PackageTool(tool))
    }
    // The shared contract accepts exact fields only. Keep its validated input
    // so snapshot updates/reloads always reconstruct the same package version.
    canonical.push(value)
  }
  { builtins: base.builtins, users, manifests: canonical, }
}

///|
/// Resolve API-v2 installed package manifests with the common saved-layout and
/// configuration command protocol. V1 manifests are deliberately rejected.
/// The result's layout is the complete persistable candidate; reads never
/// publish preferences or acquire a plugin execution lease.
pub fn resolve_packages(
  builtins : Array[@plugin_protocol.ToolContribution],
  request_json : String,
) -> String {
  resolve_with_packages(builtins, request_json, true)
}

///|
/// Open a read-only v2 snapshot after reconstructing every descriptor from the
/// app's built-ins and strict package contract. Typed configuration candidates
/// inherit this v2 decoder and the original capability mask.
pub fn snapshot_open_packages(
  builtins : Array[@plugin_protocol.ToolContribution],
  response_json : String,
  capabilities : Int32,
) -> Int32 {
  snapshot_open_with_packages(builtins, response_json, capabilities, true)
}
