///|
pub struct PluginInstallation {
  priv runtime : @runtime.Runtime
  priv manifest : @contract.PluginPackage
  priv content : @runtime.PackageContent
  priv ticket : @runtime.InstallTicket
}

///|
pub struct InstalledPlugin {
  priv runtime : @runtime.Runtime
  priv manifest : @contract.PluginPackage
  priv installed : @runtime.PackageSnapshot
}

///|
// The host provides the digest of the verified, staged package bytes. Granted
// contribution IDs come from user approval and the app's capability snapshot.
pub fn prepare_plugin_installation(
  runtime : @runtime.Runtime,
  manifest_json : String,
  digest : String,
  generation : Int32,
  granted : Array[String],
) -> PluginInstallation raise @protocol.InputError {
  let manifest = @contract.parse_plugin_package(manifest_json)
  let content : @runtime.PackageContent = {
    package_id: manifest.plugin_id,
    digest,
    version: manifest.version,
  }
  let grants : Array[@runtime.ContributionGrant] = []
  for id in granted {
    let tool = match manifest.contribution(id) {
      Some(tool) => tool
      None =>
        raise @protocol.InputError(
          "unknown_tool", "An approved tool is absent from the package",
        )
    }
    grants.push({ id, effect: tool.effect.key(), })
  }
  let ticket = match
    runtime.prepare_install(content, generation, true, grants) {
    Some(ticket) => ticket
    None =>
      raise @protocol.InputError(
        "install_conflict", "Package installation is no longer current",
      )
  }
  { runtime, manifest, content, ticket, }
}

///|
pub fn PluginInstallation::health_request(_self : PluginInstallation) -> String {
  @contract.plugin_health_request()
}

///|
// Call with the terminal health result, after the worker has drained.
pub fn PluginInstallation::validate_health(
  self : PluginInstallation,
  response : String,
) -> Bool raise @protocol.InputError {
  errdefer ignore(self.ticket.health_complete(false))
  self.manifest.validate_health(response)
  self.ticket.health_complete(true) && self.ticket.phase() is Ready
}

///|
pub fn PluginInstallation::cancel(self : PluginInstallation) -> Unit {
  self.ticket.cancel()
}

///|
pub fn PluginInstallation::needs_cancel(self : PluginInstallation) -> Bool {
  self.ticket.needs_cancel()
}

///|
pub fn PluginInstallation::awaiting_health(self : PluginInstallation) -> Bool {
  self.ticket.phase() is Checking
}

///|
pub fn PluginInstallation::health_failed(self : PluginInstallation) -> Unit {
  ignore(self.ticket.health_complete(false))
}

///|
// The app preflights all open toolbars before reserving its durable publication.
pub fn PluginInstallation::begin_publish(self : PluginInstallation) -> Bool {
  self.ticket.begin_publish()
}

///|
pub fn PluginInstallation::publish_complete(
  self : PluginInstallation,
  saved : Bool,
) -> InstalledPlugin? {
  if !self.ticket.publish_complete(saved) || !saved {
    return None
  }
  match self.runtime.package_snapshot(self.content.package_id) {
    Some(installed) if installed.content == self.content =>
      Some({ runtime: self.runtime, manifest: self.manifest, installed, })
    _ => None
  }
}
