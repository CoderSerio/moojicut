///|
/// Read-only ownership fact. A gesture can be active before it has a visible
/// preview; querying must never move, finish or cancel that draft.
pub fn active(session : Int32) -> Bool {
  match sessions.get(session) {
    Some(state) => state.draft is Some(_)
    None => false
  }
}
