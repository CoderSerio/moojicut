///|
// The app/contracts layer supplies validated package and effect identities and
// intersects capability grants. This owner never reads a manifest, saves a file,
// configures a toolbar, or executes a plugin. Calls are serialized by the app.
#derive(Eq, Debug)
pub(all) struct PackageContent {
  package_id : String
  digest : String
  version : String
}

///|
pub extend PackageContent with Eq::{equal, not_equal}

///|
pub extend PackageContent with @debug.Debug::{to_repr}

///|
#derive(Eq, Debug)
pub(all) struct ContributionGrant {
  id : String
  effect : String
}

///|
pub extend ContributionGrant with Eq::{equal, not_equal}

///|
pub extend ContributionGrant with @debug.Debug::{to_repr}

///|
#derive(Eq, Debug)
pub(all) struct PackageSnapshot {
  content : PackageContent
  generation : Int32
  install_generation : Int32
  desired_enabled : Bool
}

///|
pub extend PackageSnapshot with Eq::{equal, not_equal}

///|
pub extend PackageSnapshot with @debug.Debug::{to_repr}

///|
priv struct GrantRecord {
  effect : String
  generation : Int32
}

///|
priv struct PackageRecord {
  content : PackageContent
  generation : Int32
  install_generation : Int32
  desired_enabled : Bool
  grants : Map[String, GrantRecord]
}

///|
#derive(Eq, Debug)
pub enum InstallPhase {
  Checking
  Ready
  Publishing
  Installed
  Failed
  Cancelled
}

///|
pub extend InstallPhase with Eq::{equal, not_equal}

///|
pub extend InstallPhase with @debug.Debug::{to_repr}

///|
priv struct InstallRecord {
  id : Int32
  package_id : String
  expected_generation : Int32
  content : PackageContent?
  preserve_install : Bool
  desired_enabled : Bool
  grants : Map[String, String]
  mut phase : InstallPhase
  mut cancel_requested : Bool
}

///|
pub struct InstallTicket {
  priv runtime : Runtime
  priv record : InstallRecord
}

///|
pub struct Runtime {
  priv packages : Map[String, PackageRecord]
  // Tombstones prevent absent -> installed -> absent ABA for old CAS tickets.
  priv generations : Map[String, Int32]
  priv installs : Map[Int32, InstallRecord]
  priv publications : Map[String, Int32]
  priv owners : Map[Int32, OwnerSnapshot]
  priv calls : Map[Int32, CallRecord]
  priv mut next_id : Int32
  priv mut bootstrapped : Bool
  priv mut closing : Bool
}

///|
pub fn Runtime::new() -> Runtime {
  {
    packages: Map([]),
    generations: Map([]),
    installs: Map([]),
    publications: Map([]),
    owners: Map([]),
    calls: Map([]),
    next_id: 1,
    bootstrapped: false,
    closing: false,
  }
}

///|
fn Runtime::allocate(self : Runtime) -> Int32? {
  if self.next_id >= 2147483647 {
    return None
  }
  let id = self.next_id
  self.next_id += 1
  Some(id)
}

///|
fn bounded_identity(value : String) -> Bool {
  value.length() > 0 && value.length() <= 160
}

///|
fn content_valid(content : PackageContent) -> Bool {
  if !bounded_identity(content.package_id) ||
    !bounded_identity(content.version) ||
    content.digest.length() != 64 {
    return false
  }
  for char in content.digest.iter() {
    let code = char.to_int()
    if !((code >= 48 && code <= 57) || (code >= 97 && code <= 102)) {
      return false
    }
  }
  true
}

///|
fn checked_grants(grants : Array[ContributionGrant]) -> Map[String, String]? {
  if grants.length() > 64 {
    return None
  }
  let copied : Map[String, String] = Map([])
  for grant in grants {
    if !bounded_identity(grant.id) ||
      !bounded_identity(grant.effect) ||
      copied.contains(grant.id) {
      return None
    }
    copied[grant.id] = grant.effect
  }
  Some(copied)
}

///|
pub fn Runtime::package_generation(
  self : Runtime,
  package_id : String,
) -> Int32 {
  self.generations.get(package_id).unwrap_or(0)
}

///|
pub fn Runtime::package_snapshot(
  self : Runtime,
  package_id : String,
) -> PackageSnapshot? {
  match self.packages.get(package_id) {
    Some(p) =>
      Some({
        content: p.content,
        generation: p.generation,
        install_generation: p.install_generation,
        desired_enabled: p.desired_enabled,
      })
    None => None
  }
}

///|
// Health means the isolated checker has really finished/drained, has returned
// the contract's health-only response, and requested no application effects.
pub fn Runtime::prepare_install(
  self : Runtime,
  content : PackageContent,
  expected_generation : Int32,
  desired_enabled : Bool,
  grants : Array[ContributionGrant],
) -> InstallTicket? {
  if self.closing ||
    !content_valid(content) ||
    self.installs.length() >= 64 ||
    (
      self.generations.length() >= 256 &&
      !self.generations.contains(content.package_id)
    ) ||
    self.package_generation(content.package_id) != expected_generation ||
    self.publications.contains(content.package_id) ||
    (
      !self.packages.contains(content.package_id) &&
      self.packages.length() >= 64
    ) {
    return None
  }
  let grants = match checked_grants(grants) {
    Some(g) => g
    None => return None
  }
  let id = match self.allocate() {
    Some(id) => id
    None => return None
  }
  let record : InstallRecord = {
    id,
    package_id: content.package_id,
    expected_generation,
    content: Some(content),
    preserve_install: false,
    desired_enabled,
    grants,
    phase: Checking,
    cancel_requested: false,
  }
  self.installs[id] = record
  Some({ runtime: self, record, })
}

///|
// Removal has no executable health work but uses the same CAS/publication
// reservation. Installed immutable bytes can be collected only when unleased.
pub fn Runtime::prepare_remove(
  self : Runtime,
  package_id : String,
  expected_generation : Int32,
) -> InstallTicket? {
  if self.closing ||
    self.installs.length() >= 64 ||
    !self.packages.contains(package_id) ||
    self.package_generation(package_id) != expected_generation ||
    self.publications.contains(package_id) {
    return None
  }
  let id = match self.allocate() {
    Some(id) => id
    None => return None
  }
  let record : InstallRecord = {
    id,
    package_id,
    expected_generation,
    content: None,
    preserve_install: false,
    desired_enabled: false,
    grants: Map([]),
    phase: Ready,
    cancel_requested: false,
  }
  self.installs[id] = record
  Some({ runtime: self, record, })
}

///|
pub fn InstallTicket::phase(self : InstallTicket) -> InstallPhase {
  self.record.phase
}

///|
pub fn InstallTicket::needs_cancel(self : InstallTicket) -> Bool {
  self.record.phase == Checking && self.record.cancel_requested
}

///|
fn InstallTicket::finish(self : InstallTicket, phase : InstallPhase) -> Unit {
  self.record.phase = phase
  self.runtime.installs.remove(self.record.id)
  if self.runtime.publications.get(self.record.package_id) ==
    Some(self.record.id) {
    self.runtime.publications.remove(self.record.package_id)
  }
}

///|
pub fn InstallTicket::health_complete(
  self : InstallTicket,
  healthy : Bool,
) -> Bool {
  if self.record.phase != Checking {
    return false
  }
  if self.record.cancel_requested || self.runtime.closing {
    self.finish(Cancelled)
  } else if !healthy ||
    self.runtime.package_generation(self.record.package_id) !=
    self.record.expected_generation {
    self.finish(Failed)
  } else {
    self.record.phase = Ready
  }
  true
}

///|
pub fn InstallTicket::ready(self : InstallTicket) -> Bool {
  if !(self.record.phase == Ready &&
    !self.runtime.closing &&
    !self.record.cancel_requested &&
    self.runtime.package_generation(self.record.package_id) ==
    self.record.expected_generation &&
    !self.runtime.publications.contains(self.record.package_id)) {
    return false
  }
  // Account for other reserved-but-not-yet-acknowledged publications before
  // authorizing irreversible IO. Concurrent installs cannot overfill the cap.
  if self.record.content is Some(_) {
    let mut package_count = self.runtime.packages.length()
    let mut generation_count = self.runtime.generations.length()
    for package_id, _ in self.runtime.publications {
      if !self.runtime.packages.contains(package_id) {
        package_count += 1
      }
      if !self.runtime.generations.contains(package_id) {
        generation_count += 1
      }
    }
    if (
        !self.runtime.packages.contains(self.record.package_id) &&
        package_count >= 64
      ) ||
      (
        !self.runtime.generations.contains(self.record.package_id) &&
        generation_count >= 256
      ) {
      return false
    }
  }
  true
}

///|
// Reserve only AFTER app-wide layout/capture preflight. The host then performs
// its durable CAS publish. Same-package configuration cannot move underneath
// that IO; failure must be acknowledged, not treated as a completed install.
pub fn InstallTicket::begin_publish(self : InstallTicket) -> Bool {
  if !self.ready() {
    return false
  }
  self.runtime.publications[self.record.package_id] = self.record.id
  self.record.phase = Publishing
  true
}

///|
pub fn InstallTicket::publish_complete(
  self : InstallTicket,
  saved : Bool,
) -> Bool {
  let r = self.record
  let runtime = self.runtime
  if r.phase != Publishing ||
    runtime.publications.get(r.package_id) != Some(r.id) {
    return false
  }
  if !saved {
    self.finish(if runtime.closing { Cancelled } else { Failed })
    return true
  }
  // The reserved id is a fresh generation; no allocation can fail after the
  // host has durably published. Close still adopts disk truth, but gates work.
  runtime.generations[r.package_id] = r.id
  match r.content {
    Some(content) => {
      let grants : Map[String, GrantRecord] = Map([])
      let old = runtime.packages.get(r.package_id)
      for id, effect in r.grants {
        let generation = match old {
          Some(p) if r.preserve_install &&
            p.desired_enabled == r.desired_enabled =>
            match p.grants.get(id) {
              Some(grant) if grant.effect == effect => grant.generation
              _ => r.id
            }
          _ => r.id
        }
        grants[id] = { effect, generation, }
      }
      let install_generation = match old {
        Some(p) if r.preserve_install => p.install_generation
        _ => r.id
      }
      runtime.packages[r.package_id] = {
        content,
        generation: r.id,
        install_generation,
        desired_enabled: r.desired_enabled,
        grants,
      }
    }
    None => runtime.packages.remove(r.package_id)
  }
  runtime.invalidate_calls()
  self.finish(Installed)
  true
}

///|
pub fn InstallTicket::cancel(self : InstallTicket) -> Unit {
  match self.record.phase {
    Checking => self.record.cancel_requested = true
    Ready => self.finish(Cancelled)
    Publishing => self.record.cancel_requested = true // wait for durable IO ACK
    _ => ()
  }
}

///|
// Same publication barrier for app-approved enable/grant changes. No layout is
// owned here. Unchanged grants keep their epoch, so disabling one contribution
// does not cancel an unrelated sibling invocation. No health run is needed.
pub fn Runtime::prepare_configuration(
  self : Runtime,
  package_id : String,
  expected_generation : Int32,
  desired_enabled : Bool,
  grants : Array[ContributionGrant],
) -> InstallTicket? {
  let p = match self.packages.get(package_id) {
    Some(p) => p
    None => return None
  }
  if self.closing ||
    self.installs.length() >= 64 ||
    self.publications.contains(package_id) ||
    p.generation != expected_generation {
    return None
  }
  let grants = match checked_grants(grants) {
    Some(g) => g
    None => return None
  }
  let id = match self.allocate() {
    Some(id) => id
    None => return None
  }
  let record : InstallRecord = {
    id,
    package_id,
    expected_generation,
    content: Some(p.content),
    preserve_install: true,
    desired_enabled,
    grants,
    phase: Ready,
    cancel_requested: false,
  }
  self.installs[id] = record
  Some({ runtime: self, record, })
}
