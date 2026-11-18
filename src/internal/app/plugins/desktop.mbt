///|
using @protocol {type InputError}

///|
priv struct DesktopPlugins {
  runtime : @runtime.Runtime
  manifests : Map[String, String]
  installed : Map[String, InstalledPlugin]
  installations : Map[Int32, DesktopInstallation]
  owners : Map[Int32, @runtime.OwnerSnapshot]
  calls : Map[Int32, CapturePluginCall]
  mut index : PluginIndex
  mut persisted : String?
  mut publication : IndexPublication?
  mut next_ticket : Int32
}

///|
let desktop_plugins : Map[Int32, DesktopPlugins] = Map([])

///|
let next_plugin_desktop : Ref[Int32] = Ref(1)

///|
fn plugin_ok(fields : Map[String, Json]) -> Json {
  fields["ok"] = Json(true)
  Json::object(fields)
}

///|
fn host_string(
  fields : Map[String, Json],
  key : String,
) -> String raise InputError {
  match fields.get(key) {
    Some(String(value)) => value
    _ => raise InputError("invalid_input", "\{key} must be a string")
  }
}

///|
fn host_strings(
  fields : Map[String, Json],
  key : String,
  limit : Int32,
) -> Array[String] raise InputError {
  let items = match fields.get(key) {
    Some(Array(items)) if items.length() <= limit => items
    _ => raise InputError("invalid_input", "\{key} must be a bounded array")
  }
  let values : Array[String] = []
  for item in items {
    match item {
      String(value) => values.push(value)
      _ => raise InputError("invalid_input", "\{key} must contain strings")
    }
  }
  values
}

///|
fn host_id(fields : Map[String, Json], key : String) -> Int32 raise InputError {
  @protocol.integer_field(fields, key, 1, 2147483646).to_int()
}

///|
fn DesktopPlugins::allocate(self : DesktopPlugins) -> Int32 raise InputError {
  if self.next_ticket >= 2147483647 || self.runtime.is_closing() {
    raise InputError("busy", "Plugin application is closing or out of tickets")
  }
  let id = self.next_ticket
  self.next_ticket += 1
  id
}

///|
// The host supplies original UTF-8 index bytes and the manifests read from
// independently rehashed ZIPs. Only the validated whole snapshot is restored.
pub fn desktop_plugin_open(
  index_json : String,
  archives_json : String,
  seed_layout_json : String,
) -> String {
  @protocol.response(() => {
    if desktop_plugins.length() >= 8 || next_plugin_desktop.val >= 2147483647 {
      raise InputError("busy", "Too many plugin applications")
    }
    let runtime = @runtime.Runtime::new()
    let index = if index_json == "" {
      PluginIndex::empty(
        Json::object(@contract.parse_object(seed_layout_json, 1048576)),
      )
    } else {
      parse_plugin_index(index_json)
    }
    let input = @contract.parse_object(archives_json, 10485760)
    let items = match input.get("archives") {
      Some(Array(items)) if items.length() <= 64 => items
      _ => raise InputError("invalid_input", "Expected the verified archives")
    }
    let manifests : Map[String, String] = Map([])
    let verified : Array[VerifiedPluginArchive] = []
    for item in items {
      let item = match item {
        Object(item) => item
        _ => raise InputError("invalid_input", "Invalid verified archive")
      }
      let manifest_json = host_string(item, "manifest")
      let manifest = @contract.parse_plugin_package(manifest_json)
      manifests[manifest.plugin_id] = manifest_json
      verified.push({ manifest_json, digest: host_string(item, "digest"), })
    }
    let registry = desktop_registry(manifests, index.layout())
    for entry in index.packages() {
      // Desktop settings persist contribution switches in the toolbar layout.
      // No desktop publication currently produces a disabled package record.
      if !entry.enabled {
        raise InputError("invalid_index", "A disabled package is not an active desktop record")
      }
      let manifest = @contract.parse_plugin_package(
        manifests.get(entry.plugin_id).unwrap_or(""),
      )
      let granted = entry.granted()
      for tool in manifest.contributions() {
        if registry_tool_enabled(registry, tool.id()) !=
          granted.contains(tool.id()) {
          raise InputError(
            "invalid_index", "Plugin permissions and toolbar layout disagree",
          )
        }
      }
    }
    let installed : Map[String, InstalledPlugin] = Map([])
    for item in restore_plugin_index(runtime, index, verified) {
      installed[item.manifest.plugin_id] = item
    }
    let handle = next_plugin_desktop.val
    next_plugin_desktop.val += 1
    desktop_plugins[handle] = {
      runtime,
      manifests,
      installed,
      installations: Map([]),
      owners: Map([]),
      calls: Map([]),
      index,
      persisted: if index_json == "" {
        None
      } else {
        Some(index_json)
      },
      publication: None,
      next_ticket: 1,
    }
    plugin_ok({ "application": Json(handle) })
  })
}

///|
fn DesktopPlugins::status(self : DesktopPlugins) -> Json {
  if !self.runtime.is_closing() {
    for capture in self.owners.keys().to_array() {
      let owner = self.owners[capture]
      let revision = @capture.image_session_revision(capture)
      if revision < 0 {
        ignore(self.runtime.close_owner(owner))
        self.owners.remove(capture)
      } else if revision != owner.revision {
        if self.runtime.update_owner(owner, revision) is Some(updated) {
          self.owners[capture] = updated
        }
      }
    }
  }
  let cancel : Array[Json] = []
  for id, pending in self.installations {
    if pending.install.needs_cancel() {
      cancel.push(Json(id))
    }
  }
  for id, call in self.calls {
    if call.needs_cancel() {
      cancel.push(Json(id))
    }
  }
  plugin_ok({
    "cancel": Json::array(cancel),
    "quiescent": Json(self.runtime.quiescent() && self.publication is None),
    "revision": Json(self.index.revision),
  })
}

///|
pub fn desktop_plugin_request(handle : Int32, message : String) -> String {
  @protocol.response(() => {
    guard desktop_plugins.get(handle) is Some(self) else {
      raise InputError("stale_application", "Plugin application is closed")
    }
    // A terminal worker output is bounded to 256 KiB before wrapping. A JSON
    // String can expand each input byte into a six-byte Unicode escape.
    let fields = @contract.parse_object(message, 6 * 262144 + 4096)
    match host_string(fields, "op") {
      "prepareInstall" => self.prepare_install(fields)
      "healthComplete" => self.health_complete(fields)
      "reserveInstall" => self.reserve_install(fields)
      "reserveToolChange" => self.reserve_tool_change(fields)
      "reserveUninstall" => self.reserve_uninstall(fields)
      "publishComplete" => self.publish_complete(fields)
      "cancelInstall" => {
        let id = host_id(fields, "ticket")
        let pending = self.installation(id)
        pending.install.cancel()
        if !pending.install.awaiting_health() &&
          !(self.publication is Some(publication) && publication.ticket == id) {
          self.installations.remove(id)
        }
        self.status()
      }
      "startCall" => self.start_call(fields)
      "finishCall" => self.finish_call(fields)
      "closeCapture" => {
        let capture = host_id(fields, "capture")
        if self.owners.get(capture) is Some(owner) {
          ignore(self.runtime.close_owner(owner))
          self.owners.remove(capture)
        }
        self.status()
      }
      "beginClose" => {
        self.runtime.begin_close()
        self.status()
      }
      "registry" =>
        Json::object(desktop_registry(self.manifests, self.index.layout()))
      "status" => self.status()
      _ =>
        raise InputError(
          "invalid_input", "Unknown plugin application operation",
        )
    }
  })
}

///|
pub fn desktop_plugin_close(handle : Int32) -> Int32 {
  guard desktop_plugins.get(handle) is Some(self) else { return 0 }
  self.runtime.begin_close()
  if !self.runtime.quiescent() || self.publication is Some(_) {
    return 0
  }
  desktop_plugins.remove(handle)
  1
}
