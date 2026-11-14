///|
test "feature shutdown gates new work until resources have been released" {
  let enabled = feature_transition(0, 0)
  assert_eq(feature_can_invoke(enabled), 1)
  // Cleanup completion cannot silently disable a module that is still enabled.
  assert_eq(feature_transition(enabled, 2), enabled)
  let stopping = feature_transition(enabled, 1)
  assert_eq(feature_can_invoke(stopping), 0)
  assert_eq(feature_transition(stopping, 0), stopping)
  assert_eq(feature_transition(stopping, 1), stopping)
  let disabled = feature_transition(stopping, 2)
  assert_eq(feature_can_invoke(disabled), 0)
  assert_eq(feature_transition(disabled, 2), disabled)
  assert_eq(feature_can_invoke(feature_transition(disabled, 0)), 1)
  assert_eq(feature_can_invoke(99), 0)
  assert_eq(feature_transition(99, 0), 0)
}
