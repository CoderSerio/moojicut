///|
// The index stores approval and active content identity, not executable paths.
// Immutable ZIP bytes and filesystem CAS remain the host's responsibility.
pub struct PluginIndexEntry {
  plugin_id : String
  digest : String
  enabled : Bool
  priv grants : Array[String]
}

///|
pub fn PluginIndexEntry::granted(self : PluginIndexEntry) -> Array[String] {
  self.grants.copy()
}

///|
pub struct PluginIndex {
  revision : Int32
  priv entries : Array[PluginIndexEntry]
  // Storing encoded layout avoids exposing mutable Json maps/arrays. Its
  // semantics belong to the existing catalog; this layer only requires object.
  priv encoded_layout : String
}

///|
pub(all) struct VerifiedPluginArchive {
  manifest_json : String
  digest : String
}

///|
fn index_exact(
  fields : Map[String, Json],
  names : Array[String],
) -> Unit raise @protocol.InputError {
  for name, _ in fields {
    if !names.contains(name) {
      raise @protocol.InputError(
        "invalid_plugin_index",
        "Unknown index field: \{name}",
      )
    }
  }
  for name in names {
    if !fields.contains(name) {
      raise @protocol.InputError(
        "invalid_plugin_index",
        "Missing index field: \{name}",
      )
    }
  }
}

///|
fn index_string(
  fields : Map[String, Json],
  key : String,
) -> String raise @protocol.InputError {
  match fields.get(key) {
    Some(String(value)) => value
    _ =>
      raise @protocol.InputError(
        "invalid_plugin_index",
        "\{key} must be a string",
      )
  }
}

///|
fn index_ascii(value : String, maximum : Int32) -> Bool {
  if value.length() == 0 || value.length() > maximum {
    return false
  }
  for i = 0; i < value.length(); i = i + 1 {
    if value[i].to_int() > 127 {
      return false
    }
  }
  true
}

///|
fn index_entry(
  plugin_id : String,
  digest : String,
  enabled : Bool,
  granted : Array[String],
) -> PluginIndexEntry raise @protocol.InputError {
  let code = "invalid_plugin_index"
  if !index_ascii(plugin_id, 96) || !@contract.plugin_id_valid(plugin_id) {
    raise @protocol.InputError(code, "Expected a reverse-domain plugin ID")
  }
  if digest.length() != 64 {
    raise @protocol.InputError(
      code, "Expected a lowercase SHA-256 package digest",
    )
  }
  for i = 0; i < digest.length(); i = i + 1 {
    let unit = digest[i].to_int()
    if !((unit >= 48 && unit <= 57) || (unit >= 97 && unit <= 102)) {
      raise @protocol.InputError(
        code, "Expected a lowercase SHA-256 package digest",
      )
    }
  }
  if granted.length() > 16 {
    raise @protocol.InputError(
      code, "A package has at most 16 approved contributions",
    )
  }
  let seen : Map[String, Bool] = Map([])
  let prefix = "user." + plugin_id + "/"
  for id in granted {
    if !index_ascii(id, 150) || !id.has_prefix(prefix) || seen.contains(id) {
      raise @protocol.InputError(
        code, "Expected unique contribution IDs belonging to the package",
      )
    }
    let tool_key = id[prefix.length():].to_owned()
    if tool_key.length() > 48 || !@contract.local_key_valid(tool_key) {
      raise @protocol.InputError(code, "Expected a valid contribution tool ID")
    }
    seen[id] = true
  }
  { plugin_id, digest, enabled, grants: granted.copy(), }
}

///|
fn index_layout(value : Json) -> String raise @protocol.InputError {
  if !(value is Object(_)) {
    raise @protocol.InputError(
      "invalid_plugin_index", "Layout must be a decoded object",
    )
  }
  let encoded = value.stringify()
  // Reuse the strict parser's UTF-8, duplicate-key and depth limits. Parsing
  // again also rejects malformed native UTF-16 rather than retaining it.
  ignore(@contract.parse_object(encoded, 1048576))
  encoded
}

///|
fn index_integer(
  fields : Map[String, Json],
  key : String,
) -> Int32 raise @protocol.InputError {
  let spelling = match fields.get(key) {
    Some(Number(_, repr=Some(spelling))) => spelling
    _ =>
      raise @protocol.InputError(
        "invalid_plugin_index",
        "\{key} must be a nonnegative decimal integer",
      )
  }
  if spelling.length() == 0 || spelling.length() > 10 {
    raise @protocol.InputError(
      "invalid_plugin_index",
      "\{key} exceeds the index integer range",
    )
  }
  let mut value = 0
  for unit in spelling {
    let digit = unit.to_int() - 48
    if digit < 0 || digit > 9 || value > (2147483647 - digit) / 10 {
      raise @protocol.InputError(
        "invalid_plugin_index",
        "\{key} must be an integer from 0 through 2147483647",
      )
    }
    value = value * 10 + digit
  }
  value
}

///|
pub fn parse_plugin_index(
  text : String,
) -> PluginIndex raise @protocol.InputError {
  ignore(@contract.parse_object(text, 1048576))
  // Preserve the decimal spelling before conversion: a tiny fractional part
  // must not round to an apparently valid CAS revision in a Double.
  let parsed = @json.parse(
    text,
    max_nesting_depth=16,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    _ =>
      raise @protocol.InputError(
        "invalid_plugin_index", "Invalid plugin index JSON",
      )
  }
  let fields = match parsed {
    Object(fields) => fields
    _ =>
      raise @protocol.InputError(
        "invalid_plugin_index", "Plugin index must be an object",
      )
  }
  index_exact(fields, ["schemaVersion", "revision", "packages", "layout"])
  if index_integer(fields, "schemaVersion") != 2 {
    raise @protocol.InputError(
      "unsupported_index_version", "Expected plugin index schema 2",
    )
  }
  let revision = index_integer(fields, "revision")
  let values = match fields.get("packages") {
    Some(Array(values)) if values.length() <= 64 => values
    _ =>
      raise @protocol.InputError(
        "invalid_plugin_index", "Expected at most 64 installed packages",
      )
  }
  let entries : Array[PluginIndexEntry] = []
  let seen : Map[String, Bool] = Map([])
  for value in values {
    let fields = match value {
      Object(fields) => fields
      _ =>
        raise @protocol.InputError(
          "invalid_plugin_index", "Each package record must be an object",
        )
    }
    index_exact(fields, ["pluginId", "digest", "enabled", "granted"])
    let enabled = match fields.get("enabled") {
      Some(True) => true
      Some(False) => false
      _ =>
        raise @protocol.InputError(
          "invalid_plugin_index", "enabled must be a boolean",
        )
    }
    let granted : Array[String] = []
    match fields.get("granted") {
      Some(Array(values)) =>
        for value in values {
          match value {
            String(id) => granted.push(id)
            _ =>
              raise @protocol.InputError(
                "invalid_plugin_index", "granted must contain contribution IDs",
              )
          }
        }
      _ =>
        raise @protocol.InputError(
          "invalid_plugin_index", "granted must be an array",
        )
    }
    let entry = index_entry(
      index_string(fields, "pluginId"),
      index_string(fields, "digest"),
      enabled,
      granted,
    )
    if seen.contains(entry.plugin_id) {
      raise @protocol.InputError(
        "invalid_plugin_index", "Duplicate installed package ID",
      )
    }
    seen[entry.plugin_id] = true
    entries.push(entry)
  }
  { revision, entries, encoded_layout: index_layout(fields["layout"]), }
}

///|
pub fn PluginIndex::empty(
  layout : Json,
) -> PluginIndex raise @protocol.InputError {
  let index : PluginIndex = {
    revision: 0,
    entries: [],
    encoded_layout: index_layout(layout),
  }
  index.checked()
}

///|
pub fn PluginIndex::packages(self : PluginIndex) -> Array[PluginIndexEntry] {
  self.entries.copy()
}

///|
pub fn PluginIndex::layout(self : PluginIndex) -> Json {
  @json.parse(self.encoded_layout) catch {
    _ => abort("validated layout became invalid")
  }
}

///|
pub fn PluginIndex::encode(self : PluginIndex) -> String {
  let packages = self.entries.map(entry => {
    Json::object({
      "pluginId": Json(entry.plugin_id),
      "digest": Json(entry.digest),
      "enabled": Json(entry.enabled),
      "granted": Json::array(entry.grants.map(id => Json(id))),
    })
  })
  Json::object({
    "schemaVersion": Json(2),
    "revision": Json(self.revision),
    "packages": Json::array(packages),
    "layout": self.layout(),
  }).stringify()
}

///|
fn PluginIndex::checked(
  self : PluginIndex,
) -> PluginIndex raise @protocol.InputError {
  // Encoded wrappers/escapes also count toward the persisted byte budget.
  ignore(@contract.parse_object(self.encode(), 1048576))
  self
}

///|
fn PluginIndex::next_revision(
  self : PluginIndex,
) -> Int32 raise @protocol.InputError {
  if self.revision == 2147483647 {
    raise @protocol.InputError(
      "index_revision_exhausted", "The plugin index revision cannot be incremented",
    )
  }
  self.revision + 1
}

///|
pub fn PluginIndex::with_package(
  self : PluginIndex,
  plugin_id : String,
  digest : String,
  enabled : Bool,
  granted : Array[String],
  layout? : Json,
) -> PluginIndex raise @protocol.InputError {
  let entry = index_entry(plugin_id, digest, enabled, granted)
  let entries : Array[PluginIndexEntry] = []
  let mut replaced = false
  for current in self.entries {
    if current.plugin_id == plugin_id {
      entries.push(entry)
      replaced = true
    } else {
      entries.push(current)
    }
  }
  if !replaced {
    if entries.length() >= 64 {
      raise @protocol.InputError(
        "invalid_plugin_index", "The installed package limit is 64",
      )
    }
    entries.push(entry)
  }
  let next : PluginIndex = {
    revision: self.next_revision(),
    entries,
    encoded_layout: match layout {
      Some(value) => index_layout(value)
      None => self.encoded_layout
    },
  }
  next.checked()
}

///|
pub fn PluginIndex::without_package(
  self : PluginIndex,
  plugin_id : String,
  layout? : Json,
) -> PluginIndex raise @protocol.InputError {
  let entries = self.entries.filter(entry => entry.plugin_id != plugin_id)
  if entries.length() == self.entries.length() {
    raise @protocol.InputError(
      "unknown_package", "The package is absent from the index",
    )
  }
  let next : PluginIndex = {
    revision: self.next_revision(),
    entries,
    encoded_layout: match layout {
      Some(value) => index_layout(value)
      None => self.encoded_layout
    },
  }
  next.checked()
}

///|
pub fn PluginIndex::with_layout(
  self : PluginIndex,
  layout : Json,
) -> PluginIndex raise @protocol.InputError {
  let next : PluginIndex = {
    revision: self.next_revision(),
    entries: self.entries,
    encoded_layout: index_layout(layout),
  }
  next.checked()
}

///|
// The host supplies independently verified ZIP manifests and digests. Require
// an exact set: extra or missing files cannot silently change the approved
// index. All checking precedes the runtime's atomic fresh-instance bootstrap.
pub fn restore_plugin_index(
  runtime : @runtime.Runtime,
  index : PluginIndex,
  verified : Array[VerifiedPluginArchive],
) -> Array[InstalledPlugin] raise @protocol.InputError {
  let code = "invalid_plugin_restore"
  if verified.length() != index.entries.length() {
    raise @protocol.InputError(
      code, "Verified packages must exactly match the index",
    )
  }
  let manifests : Map[String, @contract.PluginPackage] = Map([])
  let digests : Map[String, String] = Map([])
  for archive in verified {
    let manifest = @contract.parse_plugin_package(archive.manifest_json)
    if manifests.contains(manifest.plugin_id) {
      raise @protocol.InputError(code, "Duplicate verified package ID")
    }
    manifests[manifest.plugin_id] = manifest
    digests[manifest.plugin_id] = archive.digest
  }
  let restored : Array[@runtime.RestoredPackage] = []
  for entry in index.entries {
    let manifest = match manifests.get(entry.plugin_id) {
      Some(manifest) => manifest
      None =>
        raise @protocol.InputError(
          code, "A package in the index has not been verified",
        )
    }
    if digests.get(entry.plugin_id) != Some(entry.digest) {
      raise @protocol.InputError(
        code, "Verified package digest differs from the active index",
      )
    }
    let grants : Array[@runtime.ContributionGrant] = []
    for id in entry.grants {
      let contribution = match manifest.contribution(id) {
        Some(contribution) => contribution
        None =>
          raise @protocol.InputError(
            code, "An approved contribution is absent from the verified package",
          )
      }
      grants.push({ id, effect: contribution.effect.key(), })
    }
    restored.push({
      content: {
        package_id: entry.plugin_id,
        digest: entry.digest,
        version: manifest.version,
      },
      desired_enabled: entry.enabled,
      grants,
    })
  }
  if !runtime.restore_packages(restored) {
    raise @protocol.InputError(
      "restore_conflict", "Package restore requires a fresh runtime",
    )
  }
  index.entries.map(entry => {
    runtime,
    manifest: manifests[entry.plugin_id],
    installed: runtime.package_snapshot(entry.plugin_id).unwrap(),
  })
}
