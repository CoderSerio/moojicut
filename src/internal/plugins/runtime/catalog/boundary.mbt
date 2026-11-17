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
      if count > 256 {
        raise InputError(
          "invalid_input", "Tool layout exceeds 256 saved entries",
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
        entries.push({ id: Known(tool), enabled: true, })
        seen[tool.key()] = true
      }
    }
    layout = layout.with_entries(group, entries)
  }
  if layout.screenshot.length() +
    layout.recording.length() +
    layout.video_editing.length() >
    256 {
    raise InputError(
      "invalid_input", "Tool layout exceeds 256 entries after adding available tools",
    )
  }
  // Leave space inside the shared request bound for an update command. Escaped
  // unknown IDs can be larger in JSON than their decoded character count.
  if encode_layout(layout).stringify().length() > 60000 {
    raise InputError("invalid_input", "Normalized tool layout is too large")
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
fn result(layout : Layout) -> Json {
  let groups : Map[String, Json] = Map([])
  for group in [Screenshot, Recording, VideoEditing] {
    let tools : Array[Json] = []
    for entry in layout.entries(group) {
      match entry.id {
        Known(BuiltinTool(tool)) => {
          let descriptor : Map[String, Json] = {
            "id": Json(tool.key()),
            "pluginId": Json(tool.plugin_id()),
            "target": Json(group.key()),
            "title": Json(tool.title()),
            "enabled": Json(entry.enabled),
          }
          match tool.behavior() {
            Annotation(kind) => {
              descriptor["type"] = Json("annotation")
              descriptor["kind"] = Json(kind)
            }
            PinAction => {
              descriptor["type"] = Json("action")
              descriptor["action"] = Json("pin")
            }
          }
          tools.push(Json::object(descriptor))
        }
        Known(PluginTool(tool)) =>
          tools.push(@plugin_protocol.encode_tool(tool, entry.enabled))
        Unknown(_) => ()
      }
    }
    groups[group.key()] = Json::array(tools)
  }
  Json::object({
    "ok": Json(true),
    "layout": encode_layout(layout),
    "groups": Json::object(groups),
  })
}

///|
/// Normalize a versioned saved layout, or return defaults for an empty string.
/// Unknown IDs remain saved but never appear in the executable catalog.
pub fn tool_registry_normalize(saved_json : String) -> String {
  @protocol.response(() => {
    result(
      if saved_json == "" {
        default_layout({ users: [], })
      } else {
        decode_layout(@protocol.request_object(saved_json), { users: [], })
      },
    )
  })
}

///|
/// Pure checked update: the caller persists the returned layout before applying
/// it to live controls. Errors return no replacement layout.
pub fn tool_registry_update(request_json : String) -> String {
  @protocol.response(() => {
    let request = @protocol.request_object(request_json)
    let catalog : Catalog = { users: [], }
    let layout = decode_layout(
      @protocol.object_field(request, "layout"),
      catalog,
    )
    let command = decode_command(
      @protocol.object_field(request, "command"),
      catalog,
    )
    result(layout.apply(command))
  })
}

///|
fn decode_catalog(value : Json) -> Catalog raise InputError {
  let manifests = match value {
    Array(items) if items.length() <= 64 => items
    _ =>
      raise InputError(
        "invalid_catalog", "manifests must be an array with at most 64 packages",
      )
  }
  let seen : Map[String, Bool] = Map([])
  let users : Array[@plugin_protocol.UserTool] = []
  for value in manifests {
    let manifest = @plugin_protocol.decode_manifest(value)
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
      users.push(tool)
    }
  }
  { users, }
}

///|
/// Resolve against the caller's current installed-package snapshot. Removed
/// tools become unknown saved entries, retaining their preferences for reinstall.
pub fn tool_registry_resolve(request_json : String) -> String {
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
      Some(value) => decode_catalog(value)
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
    result(layout)
  })
}
