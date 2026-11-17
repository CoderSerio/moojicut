///|
priv struct RegistrySnapshot {
  result_json : String
  layout_json : String
  groups : Array[Array[Json]]
  capabilities : Int32
}

///|
let snapshots : Map[Int32, RegistrySnapshot] = Map([])

///|
let next_snapshot : Ref[Int32] = Ref(1)

///|
pub fn snapshot_open(
  builtins : Array[@plugin_protocol.ToolContribution],
  response_json : String,
  capabilities : Int32,
) -> Int32 {
  if capabilities < 0 ||
    snapshots.length() >= 64 ||
    next_snapshot.val >= 2147483647 {
    return 0
  }
  let source = @plugin_protocol.parse_object(response_json, 262144) catch {
    _ => return 0
  }
  if source.get("ok") != Some(Json(true)) {
    return 0
  }
  let layout = match source.get("layout") {
    Some(Object(fields)) => Json::object(fields)
    _ => return 0
  }
  let manifests = match source.get("manifests") {
    Some(Array(items)) => Json::array(items)
    _ => return 0
  }
  // Never trust a caller-provided command/kind/slot. Reconstruct the entire
  // descriptor set from app-owned contributions plus validated manifests.
  let checked = resolve_catalog(
    builtins,
    Json::object({ "layout": layout, "manifests": manifests }).stringify(),
  )
  let canonical = @plugin_protocol.parse_object(checked, 262144) catch {
    _ => return 0
  }
  if Json::object(canonical) != Json::object(source) {
    return 0
  }
  let fields = @protocol.object_field(canonical, "groups") catch {
    _ => return 0
  }
  let groups : Array[Array[Json]] = []
  for group in [Screenshot, Recording, VideoEditing] {
    match fields.get(group.key()) {
      Some(Array(items)) => groups.push(items)
      _ => return 0
    }
  }
  let handle = next_snapshot.val
  next_snapshot.val += 1
  snapshots[handle] = {
    result_json: checked,
    layout_json: layout.stringify(),
    groups,
    capabilities,
  }
  handle
}

///|
pub fn snapshot_count(handle : Int32, group : Int32) -> Int32 {
  match snapshots.get(handle) {
    Some(snapshot) if group >= 0 && group < snapshot.groups.length() =>
      snapshot.groups[group].length()
    _ => -1
  }
}

///|
fn snapshot_entry(
  handle : Int32,
  group : Int32,
  index : Int32,
) -> (RegistrySnapshot, Map[String, Json])? {
  let snapshot = match snapshots.get(handle) {
    Some(value) => value
    None => return None
  }
  if group < 0 ||
    group >= snapshot.groups.length() ||
    index < 0 ||
    index >= snapshot.groups[group].length() {
    return None
  }
  match snapshot.groups[group][index] {
    Object(fields) => Some((snapshot, fields))
    _ => None
  }
}

///|
fn snapshot_integer(fields : Map[String, Json], key : String) -> Int32 {
  match fields.get(key) {
    Some(Number(value, ..)) => value.to_int()
    _ => 0
  }
}

///|
fn snapshot_string(fields : Map[String, Json], key : String) -> String {
  match fields.get(key) {
    Some(String(value)) => value
    _ => ""
  }
}

///|
fn snapshot_available(
  snapshot : RegistrySnapshot,
  fields : Map[String, Json],
) -> Bool {
  let requires = snapshot_integer(fields, "capability")
  (snapshot.capabilities & requires) == requires
}

///|
pub fn snapshot_value(
  handle : Int32,
  group : Int32,
  index : Int32,
  key : Int32,
) -> Int32 {
  let (snapshot, fields) = match snapshot_entry(handle, group, index) {
    Some(value) => value
    None => return -1
  }
  match key {
    0 => if fields.get("enabled") == Some(Json(true)) { 1 } else { 0 }
    1 => if snapshot_available(snapshot, fields) { 1 } else { 0 }
    2 => if snapshot_string(fields, "slot") == "finish" { 1 } else { 0 }
    3 => snapshot_integer(fields, "kind")
    4 =>
      match snapshot_string(fields, "type") {
        "annotation" => 1
        "action" => 2
        "command" => 3
        _ => -1
      }
    5 =>
      match snapshot_string(fields, "interaction") {
        "invoke" => 0
        "annotation" => 1
        "dragRect" => 2
        _ => -1
      }
    6 => if fields.get("defaultEnabled") == Some(Json(true)) { 1 } else { 0 }
    7 => snapshot_integer(fields, "capability")
    _ => -1
  }
}

///|
pub fn snapshot_text(
  handle : Int32,
  group : Int32,
  index : Int32,
  key : Int32,
) -> String {
  let (snapshot, fields) = match snapshot_entry(handle, group, index) {
    Some(value) => value
    None => return ""
  }
  let field = match key {
    0 => "id"
    1 => "pluginId"
    2 => "title"
    3 => "icon"
    4 => "command"
    5 => "action"
    6 =>
      return match fields.get("payload") {
        Some(value) => value.stringify()
        None => ""
      }
    7 =>
      return if snapshot_available(snapshot, fields) {
        ""
      } else {
        "Required backend is unavailable: " +
        snapshot_string(fields, "requires")
      }
    8 => "toolId"
    9 => "target"
    10 => "requires"
    _ => return ""
  }
  snapshot_string(fields, field)
}

///|
pub fn snapshot_layout(handle : Int32) -> String {
  match snapshots.get(handle) {
    Some(snapshot) => snapshot.layout_json
    None => ""
  }
}

///|
fn snapshot_candidate(
  builtins : Array[@plugin_protocol.ToolContribution],
  handle : Int32,
  command : Json,
) -> Int32 {
  let snapshot = match snapshots.get(handle) {
    Some(value) => value
    None => return 0
  }
  let source = @plugin_protocol.parse_object(snapshot.result_json, 262144) catch {
    _ => return 0
  }
  let response = resolve_catalog(
    builtins,
    Json::object({
      "layout": source["layout"],
      "manifests": source["manifests"],
      "command": command,
    }).stringify(),
  )
  snapshot_open(builtins, response, snapshot.capabilities)
}

///|
pub fn snapshot_set_enabled(
  builtins : Array[@plugin_protocol.ToolContribution],
  handle : Int32,
  id : String,
  enabled : Int32,
) -> Int32 {
  if enabled != 0 && enabled != 1 {
    return 0
  }
  snapshot_candidate(
    builtins,
    handle,
    Json::object({
      "type": Json("enabled"),
      "id": Json(id),
      "enabled": Json(enabled == 1),
    }),
  )
}

///|
pub fn snapshot_move(
  builtins : Array[@plugin_protocol.ToolContribution],
  handle : Int32,
  id : String,
  before : String,
) -> Int32 {
  let snapshot = match snapshots.get(handle) {
    Some(value) => value
    None => return 0
  }
  for group in 0..<snapshot.groups.length() {
    for entry in snapshot.groups[group] {
      if entry is Object(fields) && snapshot_string(fields, "id") == id {
        return snapshot_candidate(
          builtins,
          handle,
          Json::object({
            "type": Json("move"),
            "group": Json(["screenshot", "recording", "videoEditing"][group]),
            "id": Json(id),
            "beforeId": if before == "" {
              Json::null()
            } else {
              Json(before)
            },
          }),
        )
      }
    }
  }
  0
}

///|
pub fn snapshot_close(handle : Int32) -> Int32 {
  match snapshots.get(handle) {
    Some(_) => {
      snapshots.remove(handle)
      1
    }
    None => 0
  }
}
