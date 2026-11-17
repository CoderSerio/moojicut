///|
using @json {type Json}

///|
using @protocol {type InputError}

///|
fn string_field(
  fields : Map[String, Json],
  key : String,
) -> String raise InputError {
  match fields.get(key) {
    Some(String(value)) if value.length() > 0 && value.length() <= 160 => value
    _ =>
      raise InputError(
        "invalid_input",
        "\{key} must be a string with 1–160 characters",
      )
  }
}

///|
fn bool_field(
  fields : Map[String, Json],
  key : String,
) -> Bool raise InputError {
  match fields.get(key) {
    Some(True) => true
    Some(False) => false
    _ => raise InputError("invalid_input", "\{key} must be a boolean")
  }
}

///|
fn decode_layout(
  fields : Map[String, Json],
  catalog : Catalog,
) -> Layout raise InputError {
  match fields.get("version") {
    Some(Number(value, ..)) if value == 1 => ()
    _ =>
      raise InputError("unsupported_version", "Expected tool layout version 1")
  }
  let groups = @protocol.object_field(fields, "groups")
  let seen : Map[String, Bool] = Map([])
  // Built-ins can grow without spending the saved user/unknown-entry budget.
  // Use the same bound before and after defaults so emitted layouts reload.
  let entry_limit = 256 + catalog.builtins.length()
  let mut count = 0
  let mut layout : Layout = {
    screenshot: [],
    recording: [],
    video_editing: [],
  }
  for group in [Screenshot, Recording, VideoEditing] {
    let items = match groups.get(group.key()) {
      None => []
      Some(Array(items)) => items
      _ => raise InputError("invalid_input", "Each tool group must be an array")
    }
    let entries : Array[Entry] = []
    for item in items {
      count += 1
      if count > entry_limit {
        raise InputError(
          "invalid_input",
          "Tool layout exceeds \{entry_limit} saved entries",
        )
      }
      let fields = match item {
        Object(fields) => fields
        _ =>
          raise InputError("invalid_input", "Each saved tool must be an object")
      }
      let key = string_field(fields, "id")
      let enabled = bool_field(fields, "enabled")
      let id = match catalog.find(key) {
        Some(tool) => {
          if !tool.belongs_to(group) {
            raise InputError(
              "invalid_group", "Tool is saved in the wrong group",
            )
          }
          Known(tool)
        }
        None => Unknown(key)
      }
      // First occurrence wins across all groups, including hidden unknown IDs.
      if !seen.contains(key) {
        entries.push({ id, enabled, })
        seen[key] = true
      }
    }
    for tool in catalog.all(group) {
      if !seen.contains(tool.key()) {
        entries.push({ id: Known(tool), enabled: tool.default_enabled(), })
        seen[tool.key()] = true
      }
    }
    layout = layout.with_entries(group, entries)
  }
  if layout.screenshot.length() +
    layout.recording.length() +
    layout.video_editing.length() >
    entry_limit {
    raise InputError(
      "invalid_input",
      "Tool layout exceeds \{entry_limit} entries after adding available tools",
    )
  }
  layout
}

///|
fn known_tool(
  key : String,
  catalog : Catalog,
) -> AvailableTool raise InputError {
  match catalog.find(key) {
    Some(tool) => tool
    None =>
      raise InputError(
        "unknown_tool", "Unknown tools cannot be changed or invoked",
      )
  }
}

///|
fn decode_command(
  fields : Map[String, Json],
  catalog : Catalog,
) -> Command raise InputError {
  let tool = known_tool(string_field(fields, "id"), catalog)
  match string_field(fields, "type") {
    "enabled" => SetEnabled(tool, bool_field(fields, "enabled"))
    "move" => {
      let group = match ToolGroup::from_key(string_field(fields, "group")) {
        Some(group) => group
        None => raise InputError("invalid_group", "Unknown tool group")
      }
      if !tool.belongs_to(group) {
        raise InputError("invalid_group", "Tools cannot move between groups")
      }
      let before = match fields.get("beforeId") {
        Some(Null) => None
        Some(String(key)) => {
          let before = known_tool(key, catalog)
          if !before.belongs_to(group) {
            raise InputError(
              "invalid_group", "Move destination must be in the same group",
            )
          }
          if before.slot() != tool.slot() {
            raise InputError(
              "invalid_slot", "Move destination must be in the same toolbar slot",
            )
          }
          Some(before)
        }
        _ =>
          raise InputError(
            "invalid_input", "beforeId must be a tool ID or null",
          )
      }
      Move(group, tool, before)
    }
    _ => raise InputError("invalid_command", "Expected enabled or move command")
  }
}

///|
fn encode_layout(layout : Layout) -> Json {
  let groups : Map[String, Json] = Map([])
  for group in [Screenshot, Recording, VideoEditing] {
    groups[group.key()] = Json::array(
      layout
      .entries(group)
      .map(entry => {
        Json::object({
          "id": Json(entry.id.key()),
          "enabled": Json(entry.enabled),
        })
      }),
    )
  }
  Json::object({ "version": Json(1), "groups": Json::object(groups) })
}

///|
fn encode_contribution(
  tool : @plugin_protocol.ToolContribution,
  enabled : Bool,
) -> Json {
  let descriptor : Map[String, Json] = {
    "id": Json(tool.id),
    "pluginId": Json(tool.plugin_id),
    "target": Json(tool.target),
    "title": Json(tool.title),
    "icon": Json(tool.icon),
    "slot": Json(tool.slot),
    "type": Json(tool.behavior),
    "command": Json(tool.command),
    "interaction": Json(tool.interaction),
    "enabled": Json(enabled),
    "defaultEnabled": Json(tool.default_enabled),
    "capability": Json(tool.capability),
    "requires": Json(tool.requires),
    "payload": tool.payload,
  }
  if tool.behavior == "annotation" {
    descriptor["kind"] = Json(tool.annotation_kind)
  }
  if tool.behavior == "action" {
    descriptor["action"] = Json(tool.command)
  }
  Json::object(descriptor)
}

///|
fn encode_user(tool : @plugin_protocol.UserTool, enabled : Bool) -> Json {
  let fields = match @plugin_protocol.encode_tool(tool, enabled) {
    Object(fields) => fields
    _ => abort("tool descriptor")
  }
  fields["icon"] = Json("plugin")
  fields["slot"] = Json("tools")
  fields["command"] = Json("plugin.run")
  fields["interaction"] = Json("invoke")
  fields["defaultEnabled"] = Json(true)
  fields["capability"] = Json(16)
  fields["requires"] = Json("userPlugins")
  fields["payload"] = Json::object({})
  Json::object(fields)
}

///|
fn result(layout : Layout, catalog : Catalog) -> Json raise InputError {
  let saved = encode_layout(layout)
  // Check the candidate after every update as well as normalization. Even
  // true -> false grows JSON by one character and must remain reloadable.
  // Leave room inside the shared request bound for the next update command.
  if saved.stringify().length() > 60000 {
    raise InputError("invalid_input", "Normalized tool layout is too large")
  }
  let groups : Map[String, Json] = Map([])
  for group in [Screenshot, Recording, VideoEditing] {
    let tools : Array[Json] = []
    for entry in layout.entries(group) {
      match entry.id {
        Known(BuiltinTool(tool)) =>
          tools.push(encode_contribution(tool, entry.enabled))
        Known(PluginTool(tool)) => tools.push(encode_user(tool, entry.enabled))
        Unknown(_) => ()
      }
    }
    groups[group.key()] = Json::array(tools)
  }
  Json::object({
    "ok": Json(true),
    "layout": saved,
    "groups": Json::object(groups),
    "manifests": Json::array(catalog.manifests),
  })
}

///|
fn builtin_catalog(
  builtins : Array[@plugin_protocol.ToolContribution],
) -> Catalog raise InputError {
  if builtins.length() > 128 {
    raise InputError("invalid_catalog", "Too many built-in contributions")
  }
  let seen : Map[String, Bool] = Map([])
  for tool in builtins {
    if tool.id.length() == 0 ||
      tool.id.length() > 160 ||
      seen.contains(tool.id) ||
      ToolGroup::from_key(tool.target) is None ||
      !["tools", "finish"].contains(tool.slot) ||
      !["annotation", "action", "command"].contains(tool.behavior) ||
      !["invoke", "annotation", "dragRect"].contains(tool.interaction) ||
      tool.command.length() == 0 ||
      tool.capability < 0 ||
      (tool.behavior == "annotation" && tool.annotation_kind <= 0) {
      raise InputError(
        "invalid_catalog", "Invalid or duplicate built-in contribution",
      )
    }
    seen[tool.id] = true
  }
  { builtins: builtins.copy(), users: [], manifests: [], }
}

///|
/// Normalize a versioned saved layout, or return defaults for an empty string.
/// Unknown IDs remain saved but never appear in the executable catalog.
pub fn normalize(
  builtins : Array[@plugin_protocol.ToolContribution],
  saved_json : String,
) -> String {
  @protocol.response(() => {
    let catalog = builtin_catalog(builtins)
    result(
      if saved_json == "" {
        default_layout(catalog)
      } else {
        decode_layout(@protocol.request_object(saved_json), catalog)
      },
      catalog,
    )
  })
}

///|
/// Pure checked update: the caller persists the returned layout before applying
/// it to live controls. Errors return no replacement layout.
pub fn update_catalog(
  builtins : Array[@plugin_protocol.ToolContribution],
  request_json : String,
) -> String {
  @protocol.response(() => {
    let request = @protocol.request_object(request_json)
    let catalog = builtin_catalog(builtins)
    let layout = decode_layout(
      @protocol.object_field(request, "layout"),
      catalog,
    )
    let command = decode_command(
      @protocol.object_field(request, "command"),
      catalog,
    )
    result(layout.apply(command), catalog)
  })
}

///|
fn decode_catalog(
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
  let users : Array[@plugin_protocol.UserTool] = []
  let canonical : Array[Json] = []
  for value in manifests {
    let manifest = @plugin_protocol.decode_manifest(value)
    canonical.push(@plugin_protocol.encode_manifest(manifest))
    if seen.contains(manifest.plugin_id()) {
      raise InputError(
        "invalid_catalog", "Duplicate pluginId in installed catalog",
      )
    }
    seen[manifest.plugin_id()] = true
    for tool in manifest.tools() {
      if users.length() >= 64 {
        raise InputError(
          "invalid_catalog", "Installed catalog exceeds 64 user tools",
        )
      }
      if base.find(tool.global_id()) is Some(_) {
        raise InputError("invalid_catalog", "Contribution identity collision")
      }
      users.push(tool)
    }
  }
  { builtins: base.builtins, users, manifests: canonical, }
}

///|
/// Resolve against the caller's current installed-package snapshot. Removed
/// tools become unknown saved entries, retaining their preferences for reinstall.
pub fn resolve_catalog(
  builtins : Array[@plugin_protocol.ToolContribution],
  request_json : String,
) -> String {
  @protocol.response(() => {
    let request = @plugin_protocol.parse_object(request_json, 262144)
    for key, _ in request {
      if !["layout", "manifests", "command"].contains(key) {
        raise InputError(
          "invalid_input",
          "Unsupported registry request field: \{key}",
        )
      }
    }
    let catalog = match request.get("manifests") {
      Some(value) => decode_catalog(builtins, value)
      None => raise InputError("invalid_catalog", "manifests is required")
    }
    let layout = match request.get("layout") {
      Some(Null) => default_layout(catalog)
      Some(Object(fields)) => decode_layout(fields, catalog)
      _ => raise InputError("invalid_input", "layout must be an object or null")
    }
    let layout = match request.get("command") {
      None => layout
      Some(Object(fields)) => layout.apply(decode_command(fields, catalog))
      _ => raise InputError("invalid_input", "command must be an object")
    }
    result(layout, catalog)
  })
}
