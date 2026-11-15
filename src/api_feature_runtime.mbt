// Native ABI entry points. Shared lifecycle policy lives in
// internal/feature_runtime; native hosts own resources and persistence.

///|
#export_name("feature_transition")
pub fn feature_transition(state : Int, event : Int) -> Int {
  @feature_runtime.feature_transition(state, event)
}

///|
#export_name("feature_can_invoke")
pub fn feature_can_invoke(state : Int) -> Int {
  @feature_runtime.feature_can_invoke(state)
}
