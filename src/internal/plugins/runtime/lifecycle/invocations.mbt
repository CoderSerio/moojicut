///|
#derive(Eq, Debug)
pub struct OwnerSnapshot {
  owner : Int32
  session_generation : Int32
  generation : Int32
  revision : Double
}

///|
pub extend OwnerSnapshot with Eq::{equal, not_equal}

///|
pub extend OwnerSnapshot with @debug.Debug::{to_repr}

///|
// Session identities are process-unique, including across Runtime instances.
// Only opening an owner consumes one; exhaustion rejects new owners instead of
// recycling an identity that a late asynchronous completion may still retain.
let next_owner_session : Ref[Int32] = Ref(1)

///|
#derive(Eq, Debug)
pub enum InvocationPhase {
  Running
  Prepared
  Completed
  Rejected
  Cancelling
  Cancelled
}

///|
pub extend InvocationPhase with Eq::{equal, not_equal}

///|
pub extend InvocationPhase with @debug.Debug::{to_repr}

///|
priv struct CallRecord {
  request_id : String
  content : PackageContent
  install_generation : Int32
  grant_generation : Int32
  contribution : String
  effect : String
  owner : OwnerSnapshot
  mut phase : InvocationPhase
  mut drained : Bool
}

///|
pub struct Invocation {
  priv runtime : Runtime
  priv record : CallRecord
}

///|
pub struct ResultTicket {
  priv invocation : Invocation
}

///|
fn revision_valid(revision : Double) -> Bool {
  revision >= 0 &&
  revision <= 9007199254740990 &&
  @double.floor(revision) == revision
}

///|
pub fn Runtime::open_owner(
  self : Runtime,
  owner : Int32,
  revision : Double,
) -> OwnerSnapshot? {
  if self.closing ||
    owner <= 0 ||
    !revision_valid(revision) ||
    self.owners.contains(owner) ||
    self.owners.length() >= 64 {
    return None
  }
  if next_owner_session.val >= 2147483647 {
    return None
  }
  let generation = match self.allocate() {
    Some(id) => id
    None => return None
  }
  let session_generation = next_owner_session.val
  next_owner_session.val += 1
  let snapshot : OwnerSnapshot = {
    owner,
    session_generation,
    generation,
    revision,
  }
  self.owners[owner] = snapshot
  Some(snapshot)
}

///|
pub fn Runtime::owner_current(self : Runtime, owner : OwnerSnapshot) -> Bool {
  !self.closing && self.owners.get(owner.owner) == Some(owner)
}

///|
// Every accepted update invalidates earlier operations, even if the revision
// stayed equal (for example a new gesture/session intent with no document edit).
pub fn Runtime::update_owner(
  self : Runtime,
  previous : OwnerSnapshot,
  revision : Double,
) -> OwnerSnapshot? {
  if !self.owner_current(previous) || !revision_valid(revision) {
    return None
  }
  let generation = match self.allocate() {
    Some(id) => id
    None => return None
  }
  let next : OwnerSnapshot = {
    owner: previous.owner,
    session_generation: previous.session_generation,
    generation,
    revision,
  }
  self.owners[previous.owner] = next
  self.invalidate_calls()
  Some(next)
}

///|
pub fn Runtime::close_owner(self : Runtime, owner : OwnerSnapshot) -> Bool {
  if self.owners.get(owner.owner) != Some(owner) {
    return false
  }
  self.owners.remove(owner.owner)
  self.invalidate_calls()
  self.prune_closed_calls()
  true
}

///|
fn Runtime::call_current(self : Runtime, call : CallRecord) -> Bool {
  if !self.owner_current(call.owner) {
    return false
  }
  let installed = match self.packages.get(call.content.package_id) {
    Some(p) => p
    None => return false
  }
  if !installed.desired_enabled ||
    installed.content != call.content ||
    installed.install_generation != call.install_generation {
    return false
  }
  match installed.grants.get(call.contribution) {
    Some(grant) =>
      grant.effect == call.effect && grant.generation == call.grant_generation
    None => false
  }
}

///|
fn cancel_call(call : CallRecord) -> Unit {
  if call.phase == Running || call.phase == Prepared {
    call.phase = if call.drained { Cancelled } else { Cancelling }
  }
}

///|
fn Runtime::invalidate_calls(self : Runtime) -> Unit {
  for _, call in self.calls {
    if !self.call_current(call) {
      cancel_call(call)
    }
  }
}

///|
fn call_settled(call : CallRecord) -> Bool {
  call.drained && call.phase != Running && call.phase != Prepared
}

///|
fn Runtime::prune_closed_calls(self : Runtime) -> Unit {
  let retired : Array[Int32] = []
  for id, call in self.calls {
    // Keep all request IDs for an open owner, including old revisions. A
    // bounded full ledger fails closed rather than silently forgetting dedup.
    let open = match self.owners.get(call.owner.owner) {
      Some(owner) => owner.session_generation == call.owner.session_generation
      None => false
    }
    if !open && call_settled(call) {
      retired.push(id)
    }
  }
  for id in retired {
    self.calls.remove(id)
  }
}

///|
pub fn Runtime::begin_invocation(
  self : Runtime,
  package_id : String,
  expected_generation : Int32,
  contribution : String,
  owner : OwnerSnapshot,
  request_id : String,
) -> Invocation? {
  if !self.owner_current(owner) ||
    !bounded_identity(request_id) ||
    self.calls.length() >= 1024 {
    return None
  }
  let installed = match self.packages.get(package_id) {
    Some(p) => p
    None => return None
  }
  if !installed.desired_enabled || installed.generation != expected_generation {
    return None
  }
  let grant = match installed.grants.get(contribution) {
    Some(g) => g
    None => return None
  }
  let mut live = 0
  for _, call in self.calls {
    if !call.drained {
      live += 1
    }
    if call.owner.session_generation == owner.session_generation &&
      call.request_id == request_id {
      return None
    }
  }
  if live >= 64 {
    return None
  }
  let id = match self.allocate() {
    Some(id) => id
    None => return None
  }
  let record : CallRecord = {
    request_id,
    content: installed.content,
    install_generation: installed.install_generation,
    grant_generation: grant.generation,
    contribution,
    effect: grant.effect,
    owner,
    phase: Running,
    drained: false,
  }
  self.calls[id] = record
  Some({ runtime: self, record, })
}

///|
pub fn Invocation::phase(self : Invocation) -> InvocationPhase {
  self.record.phase
}

///|
pub fn Invocation::content(self : Invocation) -> PackageContent {
  self.record.content
}

///|
pub fn Invocation::allowed_effect(self : Invocation) -> String {
  self.record.effect
}

///|
pub fn Invocation::needs_cancel(self : Invocation) -> Bool {
  !self.record.drained &&
  (self.record.phase == Cancelling || self.record.phase == Rejected)
}

///|
pub fn Invocation::cancel(self : Invocation) -> Unit {
  cancel_call(self.record)
}

///|
// Decode/worker failures terminate the application result, but do not invent
// process cleanup. The host must still report the real drained acknowledgement.
pub fn Invocation::reject(self : Invocation) -> Bool {
  if self.record.phase != Running && self.record.phase != Prepared {
    return false
  }
  self.record.phase = Rejected
  self.runtime.prune_closed_calls()
  true
}

///|
pub fn Invocation::worker_drained(self : Invocation) -> Bool {
  if self.record.drained {
    return false
  }
  self.record.drained = true
  if self.record.phase == Cancelling {
    self.record.phase = Cancelled
  }
  self.runtime.prune_closed_calls()
  true
}

///|
// The adapter exposes successful bytes only AFTER cleanup. Accepting that ACK
// first leaves the result grant alive; cleanup itself is not a result consume.
pub fn Invocation::prepare_result(
  self : Invocation,
  effect : String,
) -> ResultTicket? {
  if self.record.phase != Running || !self.record.drained {
    return None
  }
  if !self.runtime.call_current(self.record) {
    cancel_call(self.record)
    return None
  }
  if effect != self.record.effect {
    self.record.phase = Rejected
    return None
  }
  self.record.phase = Prepared
  Some({ invocation: self, })
}

///|
pub fn ResultTicket::ready(self : ResultTicket) -> Bool {
  let call = self.invocation.record
  call.phase == Prepared &&
  call.drained &&
  self.invocation.runtime.call_current(call)
}

///|
// App first checks BOTH this lease and its feature candidate, then commits in
// one serialized no-callback publication section. This call performs no effect.
pub fn ResultTicket::commit(self : ResultTicket) -> Bool {
  if !self.ready() {
    return false
  }
  self.invocation.record.phase = Completed
  true
}

///|
pub fn ResultTicket::abort(self : ResultTicket) -> Bool {
  self.invocation.reject()
}

///|
// Installed, health/publication candidates and unresolved invocation/results
// retain immutable content. Retired versions release only after real draining.
pub fn Runtime::content_in_use(
  self : Runtime,
  package_id : String,
  digest : String,
) -> Bool {
  if self.packages.get(package_id) is Some(p) && p.content.digest == digest {
    return true
  }
  for _, install in self.installs {
    if install.content is Some(content) &&
      content.package_id == package_id &&
      content.digest == digest {
      return true
    }
  }
  for _, call in self.calls {
    if call.content.package_id == package_id &&
      call.content.digest == digest &&
      !call_settled(call) {
      return true
    }
  }
  false
}

///|
pub fn Runtime::begin_close(self : Runtime) -> Unit {
  self.closing = true
  self.invalidate_calls()
  let tickets = self.installs.values().to_array()
  for record in tickets {
    InstallTicket::{ runtime: self, record, }.cancel()
  }
}

///|
pub fn Runtime::is_closing(self : Runtime) -> Bool {
  self.closing
}

///|
pub fn Runtime::quiescent(self : Runtime) -> Bool {
  if self.installs.length() != 0 {
    return false
  }
  for _, call in self.calls {
    if !call_settled(call) {
      return false
    }
  }
  true
}
