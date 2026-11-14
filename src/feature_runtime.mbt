///|
// Native hosts own resources and persistence. The shared policy gates new work
// while the host drains resources; directory organization alone is not unload.
#export_name("feature_transition")
pub fn feature_transition(state : Int, event : Int) -> Int {
  match (state, event) {
    (0, 0) => 1
    (1, 1) => 2
    (2, 2) => 0
    (0 | 1 | 2, _) => state
    _ => 0
  }
}

///|
#export_name("feature_can_invoke")
pub fn feature_can_invoke(state : Int) -> Int {
  if state == 1 { 1 } else { 0 }
}
