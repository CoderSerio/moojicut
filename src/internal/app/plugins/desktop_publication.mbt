///|
priv struct DesktopInstallation {
  install : PluginInstallation
  manifest : String
  plugin_id : String
  digest : String
  granted : Array[String]
}

///|
priv struct IndexPublication {
  ticket : Int32
  index : PluginIndex
  bytes : String
  change : IndexChange
}

///|
priv enum IndexChange {
  Install
  Configure(@runtime.InstallTicket)
  Remove(String, @runtime.InstallTicket)
  LayoutOnly
}

///|
fn DesktopPlugins::installation(
  self : DesktopPlugins,
  id : Int32,
) -> DesktopInstallation raise InputError {
  match self.installations.get(id) {
    Some(installation) => installation
    None => raise InputError("stale_ticket", "Installation is no longer active")
  }
}

///|
fn DesktopPlugins::prepare_install(
  self : DesktopPlugins,
  fields : Map[String, Json],
) -> Json raise InputError {
  let manifest = host_string(fields, "manifest")
  let parsed = @contract.parse_plugin_package(manifest)
  let digest = host_string(fields, "digest")
  let requested = if fields.get("importApproved") == Some(Json(true)) &&
    !fields.contains("granted") {
    parsed.contributions().map(contribution => contribution.id())
  } else {
    host_strings(fields, "granted", 16)
  }
  let manifests = self.manifests.copy()
  manifests[parsed.plugin_id] = manifest
  let preview = desktop_registry(manifests, self.index.layout())
  let granted : Array[String] = []
  let seen : Map[String, Bool] = Map([])
  for tool in requested {
    if parsed.contribution(tool) is None || seen.contains(tool) {
      raise InputError(
        "unknown_tool", "Approved tools must be distinct package contributions",
      )
    }
    seen[tool] = true
    if registry_tool_enabled(preview, tool) {
      granted.push(tool)
    }
  }
  let id = self.allocate()
  let install = prepare_plugin_installation(
    self.runtime,
    manifest,
    digest,
    self.runtime.package_generation(parsed.plugin_id),
    granted,
  )
  self.installations[id] = {
    install,
    manifest,
    plugin_id: parsed.plugin_id,
    digest,
    granted,
  }
  plugin_ok({
    "ticket": Json(id),
    "digest": Json(digest),
    "request": Json(install.health_request()),
  })
}

///|
fn DesktopPlugins::health_complete(
  self : DesktopPlugins,
  fields : Map[String, Json],
) -> Json raise InputError {
  let id = host_id(fields, "ticket")
  let pending = self.installation(id)
  if !pending.install.awaiting_health() {
    raise InputError("stale_ticket", "Health check has already completed")
  }
  match fields.get("output") {
    Some(Null) => {
      pending.install.health_failed()
      self.installations.remove(id)
      plugin_ok({ "ready": Json(false) })
    }
    Some(String(output)) => {
      errdefer self.installations.remove(id)
      let ready = pending.install.validate_health(output)
      if !ready {
        self.installations.remove(id)
      }
      plugin_ok({ "ready": Json(ready) })
    }
    _ => raise InputError("invalid_input", "output must be UTF-8 JSON or null")
  }
}

///|
fn desktop_registry(
  manifests : Map[String, String],
  layout : Json,
  command? : Json,
) -> Map[String, Json] raise InputError {
  let entries : Array[Json] = []
  let keys = manifests.keys().to_array()
  keys.sort()
  for key in keys {
    entries.push(Json::object(@contract.parse_object(manifests[key], 65536)))
  }
  let request = { "layout": layout, "manifests": Json::array(entries) }
  if command is Some(value) {
    request["command"] = value
  }
  let result = @tools.tool_registry_resolve_packages(
    Json::object(request).stringify(),
  )
  let fields = @contract.parse_object(result, 1048576)
  if fields.get("ok") != Some(Json(true)) {
    let error = @protocol.object_field(fields, "error")
    raise InputError(host_string(error, "code"), host_string(error, "message"))
  }
  fields
}

///|
fn registry_tool_enabled(registry : Map[String, Json], tool : String) -> Bool {
  guard registry.get("groups") is Some(Object(groups)) &&
    groups.get("screenshot") is Some(Array(entries)) else {
    return false
  }
  for item in entries {
    if item is Object(item) && item.get("id") == Some(Json(tool)) {
      return item.get("enabled") == Some(Json(true))
    }
  }
  false
}

///|
// Preflight all UI consumers before asking the native host to publish this
// durable pair. Only one whole-index writer can hold a reservation at a time.
fn DesktopPlugins::reserve_install(
  self : DesktopPlugins,
  fields : Map[String, Json],
) -> Json raise InputError {
  let id = host_id(fields, "ticket")
  if self.publication is Some(_) {
    raise InputError("busy", "Another plugin publication is pending")
  }
  let pending = self.installation(id)
  let manifests = self.manifests.copy()
  manifests[pending.plugin_id] = pending.manifest
  let mut registry = desktop_registry(manifests, self.index.layout())
  let parsed = @contract.parse_plugin_package(pending.manifest)
  for contribution in parsed.contributions() {
    let tool = contribution.id()
    if !pending.granted.contains(tool) && registry_tool_enabled(registry, tool) {
      registry = desktop_registry(
        manifests,
        registry["layout"],
        command=Json::object({
          "type": Json("enabled"),
          "id": Json(tool),
          "enabled": Json(false),
        }),
      )
    }
  }
  let index = self.index.with_package(
    pending.plugin_id,
    pending.digest,
    true,
    pending.granted,
    layout=registry["layout"],
  )
  if !pending.install.begin_publish() {
    raise InputError(
      "install_conflict", "The plugin publication is no longer current",
    )
  }
  self.record_publication(id, index, registry, Install)
}

///|
fn DesktopPlugins::record_publication(
  self : DesktopPlugins,
  id : Int32,
  index : PluginIndex,
  registry : Map[String, Json],
  change : IndexChange,
) -> Json {
  let bytes = index.encode()
  self.publication = Some({ ticket: id, index, bytes, change, })
  plugin_ok({
    "ticket": Json(id),
    "expected": match self.persisted {
      Some(text) => Json(text)
      None => Json::null()
    },
    "next": Json(bytes),
    "registry": Json::object(registry),
  })
}

///|
fn DesktopPlugins::reserve_tool_change(
  self : DesktopPlugins,
  fields : Map[String, Json],
) -> Json raise InputError {
  if self.publication is Some(_) {
    raise InputError("busy", "Another plugin publication is pending")
  }
  let command = @protocol.object_field(fields, "command")
  let registry = desktop_registry(
    self.manifests,
    self.index.layout(),
    command=Json::object(command),
  )
  let layout = registry["layout"]
  let id = self.allocate()
  let tool = host_string(command, "id")
  if command.get("type") == Some(Json("enabled")) &&
    self.installed.get(host_tool_package(tool)) is Some(installed) {
    let plugin_id = installed.manifest.plugin_id
    let active = self.runtime.package_snapshot(plugin_id).unwrap()
    let mut match_entry = None
    for item in self.index.packages() {
      if item.plugin_id == plugin_id {
        match_entry = Some(item)
        break
      }
    }
    let entry = match match_entry {
      Some(entry) => entry
      None =>
        raise InputError("stale_ticket", "Plugin has no durable index entry")
    }
    let desired = entry.granted().filter(existing => existing != tool)
    if command.get("enabled") == Some(Json(true)) {
      desired.push(tool)
    }
    let grants : Array[@runtime.ContributionGrant] = installed.manifest
      .contributions()
      .filter_map(contribution => {
        if desired.contains(contribution.id()) {
          Some({ id: contribution.id(), effect: contribution.effect.key(), })
        } else {
          None
        }
      })
    let index = self.index.with_package(
      plugin_id,
      entry.digest,
      entry.enabled,
      desired,
      layout~,
    )
    guard self.runtime.prepare_configuration(
        plugin_id,
        active.generation,
        entry.enabled,
        grants,
      )
      is Some(ticket) else {
      raise InputError(
        "install_conflict", "The tool configuration is no longer current",
      )
    }
    if !ticket.begin_publish() {
      ticket.cancel()
      raise InputError(
        "install_conflict", "The tool configuration is no longer current",
      )
    }
    self.record_publication(id, index, registry, Configure(ticket))
  } else {
    self.record_publication(
      id,
      self.index.with_layout(layout),
      registry,
      LayoutOnly,
    )
  }
}

///|
fn DesktopPlugins::reserve_uninstall(
  self : DesktopPlugins,
  fields : Map[String, Json],
) -> Json raise InputError {
  if self.publication is Some(_) {
    raise InputError("busy", "Another plugin publication is pending")
  }
  let plugin_id = host_string(fields, "pluginId")
  guard self.runtime.package_snapshot(plugin_id) is Some(active) else {
    raise InputError("unknown_plugin", "Plugin is not installed")
  }
  let manifests = self.manifests.copy()
  manifests.remove(plugin_id)
  let registry = desktop_registry(manifests, self.index.layout())
  let index = self.index.without_package(plugin_id, layout=registry["layout"])
  let id = self.allocate()
  guard self.runtime.prepare_remove(plugin_id, active.generation)
    is Some(ticket) else {
    raise InputError(
      "install_conflict", "The plugin removal is no longer current",
    )
  }
  if !ticket.begin_publish() {
    ticket.cancel()
    raise InputError(
      "install_conflict", "The plugin removal is no longer current",
    )
  }
  self.record_publication(id, index, registry, Remove(plugin_id, ticket))
}

///|
fn DesktopPlugins::publish_complete(
  self : DesktopPlugins,
  fields : Map[String, Json],
) -> Json raise InputError {
  let id = host_id(fields, "ticket")
  let publication = match self.publication {
    Some(publication) if publication.ticket == id => publication
    _ => raise InputError("stale_ticket", "No matching index publication")
  }
  let saved = match fields.get("saved") {
    Some(True) => true
    Some(False) => false
    _ => raise InputError("invalid_input", "saved must be boolean")
  }
  match publication.change {
    Install => {
      let pending = self.installation(id)
      let installed = pending.install.publish_complete(saved)
      self.installations.remove(id)
      if saved {
        guard installed is Some(installed) else {
          raise InputError(
            "install_conflict", "Published installation lost its reservation",
          )
        }
        self.manifests[pending.plugin_id] = pending.manifest
        self.installed[pending.plugin_id] = installed
      }
    }
    Configure(ticket) => {
      guard ticket.publish_complete(saved) else {
        raise InputError(
          "install_conflict", "Published configuration lost its reservation",
        )
      }
    }
    Remove(plugin_id, ticket) => {
      guard ticket.publish_complete(saved) else {
        raise InputError(
          "install_conflict", "Published removal lost its reservation",
        )
      }
      if saved {
        self.manifests.remove(plugin_id)
        self.installed.remove(plugin_id)
      }
    }
    LayoutOnly => ()
  }
  self.publication = None
  if saved {
    self.index = publication.index
    self.persisted = Some(publication.bytes)
  }
  plugin_ok({ "published": Json(saved), "revision": Json(self.index.revision) })
}
