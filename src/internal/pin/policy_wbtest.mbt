///|
fn near(actual : Double, expected : Double) -> Unit raise {
  assert_true(
    actual >= expected - 0.000000001 && actual <= expected + 0.000000001,
  )
}

///|
test "pin sizing preserves platform work-area margins and tiny-screen fit" {
  near(scale(1, 8, 1000, 500, 1000, 600), 0.95)
  near(scale(2, 8, 1000, 500, 1000, 600), 1)
  near(scale(3, 8, 1000, 500, 1000, 600), 1)
  for platform in [1, 2, 3] {
    near(scale(platform, 100, 10, 10, 10000, 10000), 8)
    near(scale(platform, -1, 100, 100, 10000, 10000), 0.1)
  }
  // Very large images must still fit even when that requires less than 10%.
  near(scale(1, 1, 10000, 5000, 500, 1000), 0.0475)
  near(scale(2, 1, 10000, 5000, 500, 1000), 0.05)
  near(scale(3, 1, 10000, 5000, 500, 1000), 0.05)
  near(initial_scale(2000, 1000, 1000, 600), 0.375)
  near(initial_scale(200, 100, 1000, 600), 1)
  near(zoom_step(1, 1), 1.1)
  near(zoom_step(1.1, -1), 1)
}

///|
test "opacity retains byte alpha on Windows and unit alpha elsewhere" {
  for platform in [1, 3] {
    near(opacity(platform, 0.5, 1), 0.6)
    near(opacity(platform, 0.5, -1), 0.4)
    near(opacity(platform, 0.1, -1), 0.1)
    near(opacity(platform, 1, 1), 1)
    near(opacity(platform, 0.137, 0), 0.137)
  }
  near(opacity(2, 137, 1), 163)
  near(opacity(2, 137, -1), 111)
  near(opacity(2, 26, -1), 26)
  near(opacity(2, 255, 1), 255)
  near(opacity(2, 137, 0), 137)
}

///|
test "nonfinite and invalid pin geometry cannot reach window APIs" {
  let nan = 0.0 / 0.0
  let infinity = 1.0 / 0.0
  for invalid in [nan, infinity, -infinity] {
    near(scale(1, invalid, 100, 100, 1000, 1000), 0)
    near(scale(2, 1, invalid, 100, 1000, 1000), 0)
    near(scale(3, 1, 100, 100, 1000, invalid), 0)
    near(initial_scale(100, invalid, 1000, 1000), 0)
    near(zoom_step(invalid, 1), 0)
    near(opacity(1, invalid, 0), 1)
    near(opacity(2, invalid, 0), 255)
  }
  near(scale(1, 1, 0, 100, 1000, 1000), 0)
  near(scale(2, 1, 100, -10, 1000, 1000), 0)
  near(scale(3, 1, 100, 100, 0, 1000), 0)
  near(scale(9, 1, 100, 100, 1000, 1000), 0)
}

///|
test "visibility gives selected pin priority and preserves recovery differences" {
  for platform in [1, 2, 3] {
    // Another hidden pin must not override the explicitly selected target.
    assert_eq(visibility_action(platform, 1, 0, 0, 1, 1), 2)
    assert_eq(visibility_action(platform, 1, 1, 0, 1, 1), 1)
    assert_eq(visibility_action(platform, 0, 0, 0, 1, 1), 3)
    assert_eq(visibility_action(platform, 0, 0, 0, 0, 1), 4)
    assert_eq(visibility_action(platform, 1, 0, 1, 1, 1), 0)
    assert_eq(hidden_after(platform, 2, 0, 0, 0), 0)
    assert_eq(hidden_after(platform, 2, 0, 0, 1), 1)
    assert_eq(hidden_after(platform, 1, 1, 0, 1), 0)
    assert_eq(hidden_after(platform, 1, 1, 1, 1), 1)
    assert_eq(hidden_after(platform, 5, 1, 0, 0), 1)
  }
  // macOS can restore after a key-registration failure, but cannot hide more.
  assert_eq(visibility_action(1, 0, 0, 0, 1, 0), 3)
  assert_eq(visibility_action(1, 1, 1, 0, 1, 0), 1)
  assert_eq(visibility_action(1, 0, 0, 0, 0, 0), 5)
  // Windows requires the key for either direction; Linux keeps local recovery.
  assert_eq(visibility_action(2, 1, 1, 0, 1, 0), 5)
  assert_eq(visibility_action(3, 0, 0, 0, 0, 0), 4)
  assert_eq(visibility_action(3, 0, 0, 0, 1, 0), 3)
}

///|
test "bulk and explicit recovery keep each platform passthrough semantics" {
  assert_eq(hidden_after(1, 3, 1, 1, 0), 1)
  assert_eq(hidden_after(2, 3, 1, 1, 0), 0)
  assert_eq(hidden_after(3, 3, 1, 1, 0), 1)
  assert_eq(hidden_after(1, 6, 1, 1, 0), 1)
  assert_eq(hidden_after(2, 6, 1, 1, 0), 1)
  assert_eq(hidden_after(3, 6, 1, 1, 0), 0)
  for platform in [1, 2, 3] {
    assert_eq(hidden_after(platform, 6, 1, 0, 0), 0)
    assert_eq(hidden_after(platform, 99, 1, 0, 0), 1)
  }
  assert_eq(visibility_action(99, 1, 0, 0, 0, 1), 0)
  assert_eq(hidden_after(99, 4, 0, 0, 0), 0)
}
