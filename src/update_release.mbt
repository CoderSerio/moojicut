///|
priv struct UpdateVersion {
  label : String
  parts : Array[Int]
  preview : Bool
}

///|
fn update_decimal(text : String) -> Int? {
  if text.length() == 0 || text.length() > 8 || (text.length() > 1 && text.has_prefix("0")) { return None }
  let mut value = 0
  for unit in text.code_units() {
    let digit = unit.to_int() - 48
    if digit < 0 || digit > 9 { return None }
    value = value * 10 + digit
  }
  Some(value)
}

///|
// Project release labels are X.Y.Z[-alpha.N|-beta.N|-rc.N]. The comparator
// compares numeric components, so alpha.10 sorts after alpha.9.
fn update_version(text : String) -> UpdateVersion? {
  if text.length() > 80 { return None }
  let label = if text.has_prefix("v") { text[1:].to_owned() } else { text }
  let segments = label.split("-").map(s => s.to_owned()).to_array()
  if segments.length() < 1 || segments.length() > 2 { return None }
  let core = segments[0].split(".").map(s => s.to_owned()).to_array()
  if core.length() != 3 { return None }
  let parts : Array[Int] = []
  for part in core {
    match update_decimal(part) { Some(n) => parts.push(n); None => return None }
  }
  let preview = segments.length() == 2
  if preview {
    let suffix = segments[1].split(".").map(s => s.to_owned()).to_array()
    if suffix.length() != 2 { return None }
    let stage = match suffix[0] { "alpha" => 0; "beta" => 1; "rc" => 2; _ => return None }
    let serial = match update_decimal(suffix[1]) { Some(n) if n > 0 => n; _ => return None }
    parts.push(stage)
    parts.push(serial)
  } else {
    parts.push(3)
    parts.push(0)
  }
  Some({ label, parts, preview })
}

///|
fn update_compare(left : UpdateVersion, right : UpdateVersion) -> Int {
  for i in 0..<5 {
    if left.parts[i] < right.parts[i] { return -1 }
    if left.parts[i] > right.parts[i] { return 1 }
  }
  0
}

///|
#export_name("update_version_compare")
pub fn update_version_compare(left : String, right : String) -> Int {
  match (update_version(left), update_version(right)) {
    (Some(a), Some(b)) => update_compare(a, b)
    _ => 2
  }
}

///|
priv struct UpdateRelease {
  status : Int
  fields : Array[String]
  size : Int
}

///|
fn update_string(fields : Map[String, Json], key : String) -> String {
  match fields.get(key) { Some(String(value)) => value; _ => "" }
}

///|
fn update_release_schema(item : Json) -> Bool {
  guard item is Object(release) else { return false }
  let draft = match release.get("draft") { Some(True | False) => true; _ => false }
  let preview = match release.get("prerelease") { Some(True | False) => true; _ => false }
  draft && preview &&
  (release.get("tag_name") is Some(String(_))) &&
  (release.get("html_url") is Some(String(_))) &&
  (release.get("published_at") is Some(String(_) | Null)) &&
  (release.get("assets") is Some(Array(_)))
}

///|
fn update_asset_size(fields : Map[String, Json], maximum : Double) -> Int {
  match fields.get("size") {
    Some(Number(value, ..)) if value > 0 && value <= maximum && @double.floor(value) == value => value.to_int()
    _ => 0
  }
}

///|
fn update_asset(assets : Array[Json], name : String, url : String) -> Map[String, Json]? {
  let mut found = None
  for item in assets {
    if item is Object(asset) && update_string(asset, "name") == name {
      // Duplicate names are ambiguous; never pick a different payload by array order.
      if found is Some(_) { return None }
      if update_string(asset, "state") != "uploaded" || update_string(asset, "browser_download_url") != url {
        return None
      }
      found = Some(asset)
    }
  }
  found
}

///|
fn update_digest(asset : Map[String, Json]) -> String {
  let digest = update_string(asset, "digest")
  if digest.length() != 71 || !digest.has_prefix("sha256:") { return "" }
  let hex = digest[7:].to_owned()
  for unit in hex.code_units() {
    let c = unit.to_int()
    if !((c >= 48 && c <= 57) || (c >= 97 && c <= 102)) { return "" }
  }
  hex
}

///|
fn update_select(current : UpdateVersion, platform : Int, releases : Array[Json]) -> UpdateRelease {
  let mut best : UpdateVersion? = None
  let mut selected : Map[String, Json]? = None
  for item in releases {
    guard item is Object(release) else { continue }
    if !(release.get("draft") is Some(False)) { continue }
    let prerelease = match release.get("prerelease") {
      Some(True) => true
      Some(False) => false
      _ => continue
    }
    let version = match update_version(update_string(release, "tag_name")) {
      Some(version) => version
      None => continue
    }
    if update_string(release, "tag_name") != "v" + version.label { continue }
    if !current.preview && (prerelease || version.preview) { continue }
    let page = "https://github.com/CoderSerio/moojicut/releases/tag/v" + version.label
    if update_string(release, "html_url") != page || update_string(release, "published_at") == "" { continue }
    if best is Some(previous) && update_compare(version, previous) <= 0 { continue }
    best = Some(version)
    selected = Some(release)
  }
  let empty : UpdateRelease = { status: 0, fields: ["", "", "", "", "", ""], size: 0 }
  let (version, release) = match (best, selected) {
    (Some(v), Some(r)) => (v, r)
    _ => return empty
  }
  let newer = update_compare(version, current) > 0
  let fields = [version.label, "", "", "", "", update_string(release, "html_url")]
  let incomplete : UpdateRelease = { status: if newer { 2 } else { 0 }, fields, size: 0 }
  let assets = match release.get("assets") { Some(Array(a)) if a.length() <= 100 => a; _ => return incomplete }
  let suffix = match platform {
    0 => "macos-arm64.zip"
    1 => "windows-x64.zip"
    _ => "linux-x64.tar.gz"
  }
  let name = "moojicut-" + version.label + "-" + suffix
  let prefix = "https://github.com/CoderSerio/moojicut/releases/download/v" + version.label + "/"
  let asset = match update_asset(assets, name, prefix + name) { Some(a) => a; None => return incomplete }
  let size = update_asset_size(asset, 1073741824)
  let digest = update_digest(asset)
  if size == 0 || digest == "" { return incomplete }
  fields[1] = prefix + name
  fields[2] = name
  fields[3] = digest
  if platform == 0 {
    if update_asset(assets, "macos.xml", prefix + "macos.xml") is Some(feed) && update_asset_size(feed, 4194304) > 0 {
      fields[4] = prefix + "macos.xml"
    }
  }
  { status: if newer { 1 } else { 0 }, fields, size }
}

///|
let update_releases : Map[Int, UpdateRelease] = Map([])

///|
let update_next_handle : Ref[Int] = Ref(1)

///|
#export_name("update_release_create")
pub fn update_release_create(current : String, platform : Int, body : String) -> Int {
  if platform < 0 || platform > 2 || body.length() > 4194304 || update_releases.length() >= 16 || update_next_handle.val >= 2147483647 {
    return 0
  }
  let installed = match update_version(current) { Some(v) => v; None => return 0 }
  let parsed = @json.parse(body, max_nesting_depth=32, reject_duplicate_keys=true) catch { _ => return 0 }
  let releases = match parsed { Array(a) if a.length() <= 100 => a; _ => return 0 }
  // An invalid reply is not evidence that the installed version is current.
  // Valid drafts and unsupported release labels are still filtered normally.
  for release in releases { if !update_release_schema(release) { return 0 } }
  let result = update_select(installed, platform, releases)
  let handle = update_next_handle.val
  update_next_handle.val = handle + 1
  update_releases[handle] = result
  handle
}

///|
#export_name("update_release_status")
pub fn update_release_status(handle : Int) -> Int {
  match update_releases.get(handle) { Some(release) => release.status; None => -1 }
}

///|
#export_name("update_release_text")
pub fn update_release_text(handle : Int, field : Int) -> String {
  match update_releases.get(handle) {
    Some(release) if field >= 0 && field < 6 => release.fields[field]
    _ => ""
  }
}

///|
#export_name("update_release_size")
pub fn update_release_size(handle : Int) -> Int {
  match update_releases.get(handle) { Some(release) => release.size; None => 0 }
}

///|
#export_name("update_release_dispose")
pub fn update_release_dispose(handle : Int) -> Unit { update_releases.remove(handle) }
